// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.30;

import {ILendingMarket} from "../interfaces/ILendingMarket.sol";
import {MarketParams} from "../interfaces/ILendingMarketBase.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {IUniswapV3Pool} from "../interfaces/IUniswapV3Pool.sol";
import {IUsd0PP} from "../interfaces/IUsd0PP.sol";
import {ORACLE_PRICE_SCALE} from "../libraries/ConstantsLib.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {V3SwapSimulator} from "../libraries/V3SwapSimulator.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title UZRUnwindQuoter
/// @notice View-only lens for quoting UZRLeverage flows against live pool state.
///         Use it off-chain to compute `minUsd0Out` and to pick the remainder exit
///         (pool sale vs floor-price unlock) before calling `unleverageFlash`.
/// @dev Mirrors the math in UZRLeverage. Quotes read the market's stored borrow state
///      without accruing interest, so quote a small margin below the returned value when
///      setting `minUsd0Out`.
contract UZRUnwindQuoter {
    using MathLib for uint256;

    address constant _UZR_LENDING_MARKET = 0xa428723eE8ffD87088C36121d72100B43F11fb6A;
    address constant _BUSD0 = 0x35D8949372D46B7a3D5A56006AE77B215fc69bC0;
    address constant _USD0 = 0x73A15FeD60Bf67631dC6cd7Bc5B6e8da8190aCF5;
    address constant _ORACLE = 0x30Da78355FcEA04D1fa34AF3c318BE203C6F2145;
    address constant _IRM = 0xdfCF197B0B65066183b04B88d50ACDC0C4b01385;
    address constant _WHITELIST = 0xFE7C47895eDb12a990b311Df33B90Cfea1D44c24;
    /// @notice bUSD0/USD0 Uniswap V3 pool (token0 = bUSD0, token1 = USD0)
    address constant _UNI_V3_POOL = 0xABfCA96716cf2911bBB50A4CDBcBAffA2ef8EcDa;

    ILendingMarket public immutable lendingMarket = ILendingMarket(_UZR_LENDING_MARKET);
    IOracle public immutable oracle = IOracle(_ORACLE);

    struct UnwindQuote {
        uint256 debtRepaid; // USD0 debt the unwind repays
        uint256 collateralWithdrawn; // bUSD0 released from the market
        uint256 rtUsed; // rt-USD0 consumed by the par reconstruct leg
        uint256 remainder; // bUSD0 left after the par leg
        uint256 poolLegOut; // USD0 from selling the remainder on the pool
        uint256 floorLegOut; // USD0 from unlocking the remainder at floor price (0 if unset)
        bool preferFloor; // true when the floor leg beats the pool leg
        uint256 expectedUsd0Out; // total USD0 sent to the user, using the better leg
    }

    function _marketParams() internal pure returns (MarketParams memory) {
        return MarketParams({
            loanToken: _USD0,
            collateralToken: _BUSD0,
            oracle: _ORACLE,
            irm: _IRM,
            ltv: 88e16,
            lltv: 0.9999e18,
            whitelist: _WHITELIST
        });
    }

    /// @notice Quotes `UZRLeverage.unleverageFlash` for `user_`.
    /// @param user_ The position owner (the leverage contract's `user`).
    /// @param repayAssets USD0 debt to repay; >= debt (or type(uint256).max) quotes a full close.
    /// @param rtAmount Max rt-USD0 the user will supply for the par leg.
    function quoteUnleverage(address user_, uint256 repayAssets, uint256 rtAmount)
        external
        view
        returns (UnwindQuote memory quote)
    {
        MarketParams memory marketParams = _marketParams();
        (,, uint256 borrowAssets,, uint256 collateral) = lendingMarket.getUserPosition(marketParams, user_);

        bool fullClose = repayAssets >= borrowAssets;
        quote.debtRepaid = fullClose ? borrowAssets : repayAssets;

        if (fullClose) {
            quote.collateralWithdrawn = collateral;
        } else {
            uint256 borrowAfter = borrowAssets - repayAssets;
            uint256 requiredCollateral = borrowAfter.wDivUp(marketParams.ltv - 1e16).mulDivUp(
                ORACLE_PRICE_SCALE, oracle.price()
            );
            quote.collateralWithdrawn = collateral > requiredCollateral ? collateral - requiredCollateral : 0;
        }

        quote.rtUsed = rtAmount < quote.collateralWithdrawn ? rtAmount : quote.collateralWithdrawn;
        quote.remainder = quote.collateralWithdrawn - quote.rtUsed;

        if (quote.remainder > 0) {
            quote.poolLegOut = _simulateBusd0Sale(quote.remainder);
            uint256 floorPrice = IUsd0PP(_BUSD0).getFloorPrice();
            quote.floorLegOut = quote.remainder.wMulDown(floorPrice);
        }
        quote.preferFloor = quote.floorLegOut > quote.poolLegOut;

        uint256 remainderOut = quote.preferFloor ? quote.floorLegOut : quote.poolLegOut;
        // Contract USD0 flow: +flash - repaid + rtUsed (par) + remainderOut - flash (pull)
        uint256 gross = quote.rtUsed + remainderOut;
        quote.expectedUsd0Out = gross > quote.debtRepaid ? gross - quote.debtRepaid : 0;
    }

    /// @notice Quotes the bUSD0 received for swapping `usd0In` on the pool (the
    ///         `leveragePosition` swap leg). Use it to sanity-check the pool-buy route
    ///         against the 1:1 mint route of `leverageFlashMint`.
    function quoteLeverageSwap(uint256 usd0In) external view returns (uint256 busd0Out) {
        (V3SwapSimulator.PoolSnapshot memory snapshot, V3SwapSimulator.TickData[] memory ticks) = _loadPoolData();

        V3SwapSimulator.SimulationResult memory result = V3SwapSimulator.simulateSwap(
            snapshot,
            ticks,
            V3SwapSimulator.SimulationParams({
                amountSpecified: -int256(usd0In), // negative = exact input
                zeroForOne: false, // USD0 (token1) -> bUSD0 (token0)
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            })
        );
        busd0Out = result.amount0Delta > 0 ? uint256(result.amount0Delta) : 0;
    }

    /// @dev Simulates selling `busd0In` into the pool for USD0.
    function _simulateBusd0Sale(uint256 busd0In) internal view returns (uint256 usd0Out) {
        (V3SwapSimulator.PoolSnapshot memory snapshot, V3SwapSimulator.TickData[] memory ticks) = _loadPoolData();

        V3SwapSimulator.SimulationResult memory result = V3SwapSimulator.simulateSwap(
            snapshot,
            ticks,
            V3SwapSimulator.SimulationParams({
                amountSpecified: -int256(busd0In), // negative = exact input
                zeroForOne: true, // bUSD0 (token0) -> USD0 (token1)
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );
        usd0Out = result.amount1Delta > 0 ? uint256(result.amount1Delta) : 0;
    }

    /// @notice Load pool data for simulation using tickBitmap traversal
    /// @dev Mimics the V3 swap's nextInitializedTickWithinOneWord pattern
    ///      to discover initialized ticks via bitmap words, calling pool.ticks()
    ///      only for ticks that are actually initialized.
    function _loadPoolData()
        internal
        view
        returns (V3SwapSimulator.PoolSnapshot memory snapshot, V3SwapSimulator.TickData[] memory ticks)
    {
        IUniswapV3Pool pool = IUniswapV3Pool(_UNI_V3_POOL);
        (uint160 sqrtPriceX96, int24 tick,,,,,) = pool.slot0();
        uint128 liquidity = pool.liquidity();
        uint24 fee = pool.fee();
        int24 tickSpacing = pool.tickSpacing();

        snapshot = V3SwapSimulator.PoolSnapshot({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            liquidity: liquidity,
            feePips: fee,
            tickSpacing: tickSpacing
        });

        // Compress tick range to bitmap positions (mirrors TickBitmap.position)
        int24 rangeSize = 1000 * tickSpacing;
        int24 tickLower = (tick - rangeSize) / tickSpacing * tickSpacing;
        int24 tickUpper = (tick + rangeSize) / tickSpacing * tickSpacing;
        int24 compLower = tickLower / tickSpacing;
        int24 compUpper = tickUpper / tickSpacing;
        if (tickLower < 0 && tickLower % tickSpacing != 0) compLower--;
        if (tickUpper < 0 && tickUpper % tickSpacing != 0) compUpper--;

        // First pass: walk the bitmap left-to-right to count initialized ticks.
        // Mimics the swap's !zeroForOne path through nextInitializedTickWithinOneWord:
        //   position(compressed) -> read word -> mask to bits >= bitPos -> find LSB
        uint256 count = 0;
        {
            int24 cursor = compLower;
            while (cursor <= compUpper) {
                (int16 wordPos, uint8 bitPos) = _tickPosition(cursor);
                uint256 masked = pool.tickBitmap(wordPos) & ~((uint256(1) << bitPos) - 1);

                while (masked != 0) {
                    uint8 nextBit = _leastSignificantBit(masked);
                    int24 comp = int24(int16(wordPos)) * 256 + int24(uint24(nextBit));
                    if (comp > compUpper) break;
                    count++;
                    masked &= masked - 1;
                }
                // Advance to the first position of the next word
                cursor = (int24(int16(wordPos)) + 1) * 256;
            }
        }

        // Second pass: same walk, this time collecting liquidityNet from pool.ticks()
        ticks = new V3SwapSimulator.TickData[](count);
        {
            uint256 idx = 0;
            int24 cursor = compLower;
            while (cursor <= compUpper) {
                (int16 wordPos, uint8 bitPos) = _tickPosition(cursor);
                uint256 masked = pool.tickBitmap(wordPos) & ~((uint256(1) << bitPos) - 1);

                while (masked != 0) {
                    uint8 nextBit = _leastSignificantBit(masked);
                    int24 comp = int24(int16(wordPos)) * 256 + int24(uint24(nextBit));
                    if (comp > compUpper) break;

                    int24 t = comp * tickSpacing;
                    (, int128 liquidityNet,,,,,,) = pool.ticks(t);
                    ticks[idx++] = V3SwapSimulator.TickData({tick: t, liquidityNet: liquidityNet});
                    masked &= masked - 1;
                }
                cursor = (int24(int16(wordPos)) + 1) * 256;
            }
        }
    }

    /// @notice Compute bitmap word and bit position for a compressed tick
    /// @dev Mirrors TickBitmap.position: wordPos = compressed >> 8, bitPos = compressed % 256
    function _tickPosition(int24 compressed) private pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(compressed >> 8);
        bitPos = uint8(uint24(int24(compressed) - int24(wordPos) * 256));
    }

    /// @notice Find the index of the least significant set bit
    /// @dev Mirrors BitMath.leastSignificantBit from Uniswap V3
    function _leastSignificantBit(uint256 x) private pure returns (uint8 r) {
        r = 255;
        if (x & type(uint128).max > 0) {
            r -= 128;
        } else {
            x >>= 128;
        }
        if (x & type(uint64).max > 0) {
            r -= 64;
        } else {
            x >>= 64;
        }
        if (x & type(uint32).max > 0) {
            r -= 32;
        } else {
            x >>= 32;
        }
        if (x & type(uint16).max > 0) {
            r -= 16;
        } else {
            x >>= 16;
        }
        if (x & type(uint8).max > 0) {
            r -= 8;
        } else {
            x >>= 8;
        }
        if (x & 0xf > 0) {
            r -= 4;
        } else {
            x >>= 4;
        }
        if (x & 0x3 > 0) {
            r -= 2;
        } else {
            x >>= 2;
        }
        if (x & 0x1 > 0) {
            r -= 1;
        }
    }
}
