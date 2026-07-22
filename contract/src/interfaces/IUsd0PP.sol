// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.30;

/// @title IUsd0PP
/// @notice Minimal interface for the bUSD0 (Usd0PP) bond token.
/// @dev bUSD0 is the Usd0PP contract itself. The bond identity is
///      1 USD0 = 1 bUSD0 + 1 rt-USD0: `mint` splits USD0 into both tokens,
///      `reconstruct` burns both to release the USD0 collateral at par.
interface IUsd0PP {
    /// @notice Mints bUSD0 + rt-USD0 against USD0 collateral (1:1:1).
    /// @dev Pulls `amountUsd0` USD0 from the caller. Reverts after bond maturity.
    /// @param amountUsd0 The amount of USD0 to lock.
    /// @param bAssetRecipient Receiver of the minted bUSD0.
    /// @param rAssetRecipient Receiver of the minted rt-USD0.
    function mint(uint256 amountUsd0, address bAssetRecipient, address rAssetRecipient) external;

    /// @notice Burns bUSD0 + rt-USD0 from the caller and releases USD0 at par.
    /// @dev bUSD0 is self-burned; rt-USD0 is burned via a role-gated burnFrom
    ///      (no allowance needed). Works before maturity; reverts when paused.
    /// @param amountUsd0pp The amount of bUSD0 (and rt-USD0) to burn.
    /// @param assetRecipient Receiver of the released USD0.
    function reconstruct(uint256 amountUsd0pp, address assetRecipient) external;

    /// @notice Burns bUSD0 from the caller at the current floor price (<= 1e18).
    /// @dev The delta between par and floor goes to the protocol treasury.
    /// @param usd0ppAmount The amount of bUSD0 to unlock.
    function unlockUsd0ppFloorPrice(uint256 usd0ppAmount) external;

    /// @notice Current floor price with 18 decimals (0 if unset).
    function getFloorPrice() external view returns (uint256);

    /// @notice Bond maturity timestamp (mint reverts at/after this time).
    function getEndTime() external view returns (uint256);

    /// @notice Whether the contract is paused (reconstruct/mint unavailable).
    function paused() external view returns (bool);
}
