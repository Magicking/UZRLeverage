// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityMath} from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";

/// @title V3SwapSimulator
/// @notice Library that simulates full Uniswap V3 pool swaps with tick crossings using V4's math libraries
/// @dev Optimized for multiple calls by using memory-cached tick data
library V3SwapSimulator {
    /// @notice Cached tick data for optimized repeated simulations
    struct TickData {
        int24 tick; // The tick index
        int128 liquidityNet; // Net liquidity change when crossing
    }

    /// @notice Pool state snapshot for simulation
    struct PoolSnapshot {
        uint160 sqrtPriceX96; // Current sqrt price
        int24 tick; // Current tick
        uint128 liquidity; // Current liquidity
        uint24 feePips; // Pool fee (hundredths of a bip)
        int24 tickSpacing; // Tick spacing
    }

    /// @notice Parameters for swap simulation
    struct SimulationParams {
        int256 amountSpecified; // Negative = exact input, Positive = exact output
        bool zeroForOne; // Swap direction
        uint160 sqrtPriceLimitX96; // Price limit (0 = no limit, use min/max)
    }

    /// @notice Result of swap simulation
    struct SimulationResult {
        int256 amount0Delta; // Token0 delta (negative = in, positive = out)
        int256 amount1Delta; // Token1 delta (negative = in, positive = out)
        uint160 sqrtPriceX96After; // Price after swap
        int24 tickAfter; // Tick after swap
        uint128 liquidityAfter; // Liquidity after swap
        uint256 feeAmount; // Total fees collected
    }

    /// @notice Simulate a V3 swap with memory-cached tick data
    /// @param snapshot Pool state snapshot (read once, reuse for multiple sims)
    /// @param ticks Array of initialized ticks with liquidity data (sorted by tick ascending)
    /// @param params Swap parameters
    /// @return result Simulation result
    function simulateSwap(PoolSnapshot memory snapshot, TickData[] memory ticks, SimulationParams memory params)
        internal
        pure
        returns (SimulationResult memory result)
    {
        require(params.amountSpecified != 0, "AS");

        // Set price limit based on direction if not specified
        uint160 sqrtPriceLimitX96 = params.sqrtPriceLimitX96;
        if (sqrtPriceLimitX96 == 0) {
            sqrtPriceLimitX96 = params.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }

        // Validate price limit
        if (params.zeroForOne) {
            require(sqrtPriceLimitX96 < snapshot.sqrtPriceX96, "SPL");
            require(sqrtPriceLimitX96 > TickMath.MIN_SQRT_PRICE, "SPL");
        } else {
            require(sqrtPriceLimitX96 > snapshot.sqrtPriceX96, "SPL");
            require(sqrtPriceLimitX96 < TickMath.MAX_SQRT_PRICE, "SPL");
        }

        // Initialize state
        uint160 sqrtPriceX96 = snapshot.sqrtPriceX96;
        int24 tick = snapshot.tick;
        uint128 liquidity = snapshot.liquidity;
        int256 amountSpecifiedRemaining = params.amountSpecified;
        int256 amountCalculated = 0;
        uint256 totalFeeAmount = 0;

        bool exactInput = params.amountSpecified < 0;

        // Main swap loop
        while (amountSpecifiedRemaining != 0 && sqrtPriceX96 != sqrtPriceLimitX96) {
            // Find the next initialized tick
            (int24 tickNext, int128 liquidityNet, bool initialized) = findNextTick(ticks, tick, params.zeroForOne);

            // Ensure tickNext doesn't exceed boundaries
            if (tickNext < TickMath.MIN_TICK) {
                tickNext = TickMath.MIN_TICK;
            } else if (tickNext > TickMath.MAX_TICK) {
                tickNext = TickMath.MAX_TICK;
            }

            // Get sqrt price at next tick
            uint160 sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(tickNext);

            // Compute the target price, capped by the price limit
            uint160 sqrtPriceTargetX96 = SwapMath.getSqrtPriceTarget(params.zeroForOne, sqrtPriceNextX96, sqrtPriceLimitX96);

            // Compute the swap step
            (uint160 sqrtPriceX96Next, uint256 amountIn, uint256 amountOut, uint256 feeAmount) =
                SwapMath.computeSwapStep(sqrtPriceX96, sqrtPriceTargetX96, liquidity, amountSpecifiedRemaining, snapshot.feePips);

            // Update amounts
            if (exactInput) {
                // amountSpecifiedRemaining is negative for exact input
                unchecked {
                    amountSpecifiedRemaining += int256(amountIn + feeAmount);
                }
                amountCalculated += int256(amountOut);
            } else {
                // amountSpecifiedRemaining is positive for exact output
                unchecked {
                    amountSpecifiedRemaining -= int256(amountOut);
                }
                amountCalculated -= int256(amountIn + feeAmount);
            }

            totalFeeAmount += feeAmount;

            // Update sqrt price
            sqrtPriceX96 = sqrtPriceX96Next;

            // If we reached the next tick price, cross the tick
            if (sqrtPriceX96 == sqrtPriceNextX96) {
                // Cross the tick if it's initialized
                if (initialized) {
                    // When crossing a tick going left (zeroForOne), we negate the liquidityNet
                    // because liquidityNet is positive when entering a position from left to right
                    int128 liquidityDelta = params.zeroForOne ? -liquidityNet : liquidityNet;
                    liquidity = LiquidityMath.addDelta(liquidity, liquidityDelta);
                }

                // Update tick: when going left (zeroForOne), we're entering the tick below
                // when going right (!zeroForOne), we're entering the tick above
                unchecked {
                    tick = params.zeroForOne ? tickNext - 1 : tickNext;
                }
            } else if (sqrtPriceX96 != snapshot.sqrtPriceX96) {
                // Recompute tick if price changed but didn't reach next tick
                tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
            }
        }

        // Compute final deltas
        // V4 convention: zeroForOne != exactInput means currency1 is the specified token
        if (params.zeroForOne != exactInput) {
            // currency1 is specified (oneForZero exactInput or zeroForOne exactOutput)
            result.amount0Delta = amountCalculated;
            result.amount1Delta = params.amountSpecified - amountSpecifiedRemaining;
        } else {
            // currency0 is specified (zeroForOne exactInput or oneForZero exactOutput)
            result.amount0Delta = params.amountSpecified - amountSpecifiedRemaining;
            result.amount1Delta = amountCalculated;
        }

        result.sqrtPriceX96After = sqrtPriceX96;
        result.tickAfter = tick;
        result.liquidityAfter = liquidity;
        result.feeAmount = totalFeeAmount;
    }

    /// @notice Helper to find next initialized tick in memory array
    /// @dev Uses binary search for efficiency on sorted arrays
    /// @param ticks Sorted array of initialized ticks (ascending order)
    /// @param currentTick Current tick position
    /// @param zeroForOne Direction of swap (true = price decreasing, false = price increasing)
    /// @return nextTick The next tick to potentially cross
    /// @return liquidityNet The liquidity delta at that tick
    /// @return found Whether an initialized tick was found
    function findNextTick(TickData[] memory ticks, int24 currentTick, bool zeroForOne)
        internal
        pure
        returns (int24 nextTick, int128 liquidityNet, bool found)
    {
        uint256 len = ticks.length;
        if (len == 0) {
            // No initialized ticks, return boundary
            return (zeroForOne ? TickMath.MIN_TICK : TickMath.MAX_TICK, 0, false);
        }

        if (zeroForOne) {
            // Going left: find the largest tick <= currentTick
            // Binary search for the rightmost tick <= currentTick
            if (ticks[0].tick > currentTick) {
                // All ticks are greater than current
                return (TickMath.MIN_TICK, 0, false);
            }

            uint256 low = 0;
            uint256 high = len;

            while (low < high) {
                uint256 mid = (low + high) / 2;
                if (ticks[mid].tick <= currentTick) {
                    low = mid + 1;
                } else {
                    high = mid;
                }
            }

            // low is now the index of the first tick > currentTick
            // so low - 1 is the index of the largest tick <= currentTick
            if (low > 0) {
                return (ticks[low - 1].tick, ticks[low - 1].liquidityNet, true);
            }
            return (TickMath.MIN_TICK, 0, false);
        } else {
            // Going right: find the smallest tick > currentTick
            if (ticks[len - 1].tick <= currentTick) {
                // All ticks are <= current
                return (TickMath.MAX_TICK, 0, false);
            }

            uint256 low = 0;
            uint256 high = len;

            while (low < high) {
                uint256 mid = (low + high) / 2;
                if (ticks[mid].tick <= currentTick) {
                    low = mid + 1;
                } else {
                    high = mid;
                }
            }

            // low is now the index of the first tick > currentTick
            if (low < len) {
                return (ticks[low].tick, ticks[low].liquidityNet, true);
            }
            return (TickMath.MAX_TICK, 0, false);
        }
    }
}
