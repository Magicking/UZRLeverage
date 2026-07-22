// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.30;

/// @title IUniswapV3Pool
/// @notice Minimal Uniswap V3 pool interface for direct swaps and state reads.
interface IUniswapV3Pool {
    /// @notice Swap token0 for token1, or token1 for token0.
    /// @param recipient The address to receive the output of the swap.
    /// @param zeroForOne The direction of the swap, true for token0 to token1.
    /// @param amountSpecified The amount of the swap: positive = exact input, negative = exact output.
    /// @param sqrtPriceLimitX96 The Q64.96 sqrt price limit the swap may not exceed.
    /// @param data Any data to be passed through to the callback.
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function liquidity() external view returns (uint128);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function token0() external view returns (address);
    function token1() external view returns (address);

    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );

    function tickBitmap(int16 wordPosition) external view returns (uint256);
}
