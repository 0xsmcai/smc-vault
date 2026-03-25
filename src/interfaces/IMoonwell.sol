// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IMoonwell — Canonical Moonwell cToken interface (Compound V2 fork)
/// @notice Minimal interface for Moonwell mToken interactions on Base
/// @dev Moonwell inherits Compound V2's cToken API. Error codes: 0 = success, non-zero = failure.
interface IMoonwell {
    /// @notice Supply underlying tokens to the Moonwell market
    /// @param mintAmount The amount of underlying to supply
    /// @return 0 on success, non-zero error code on failure
    function mint(uint256 mintAmount) external returns (uint256);

    /// @notice Redeem a specific number of mTokens for underlying
    /// @param redeemTokens The number of mTokens to redeem
    /// @return 0 on success, non-zero error code on failure
    function redeem(uint256 redeemTokens) external returns (uint256);

    /// @notice Redeem a specific amount of underlying tokens
    /// @param redeemAmount The amount of underlying to receive
    /// @return 0 on success, non-zero error code on failure
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);

    /// @notice Get the stored exchange rate (no state mutation)
    /// @return The exchange rate scaled by 1e18
    function exchangeRateStored() external view returns (uint256);

    /// @notice Get the mToken balance of an account
    /// @param owner The account address
    /// @return The mToken balance
    function balanceOf(address owner) external view returns (uint256);

    /// @notice Check if minting (supplying) is paused by the guardian
    /// @return True if minting is paused
    function mintGuardianPaused() external view returns (bool);

    /// @notice Get the underlying token balance that the account has supplied
    /// @param owner The account address
    /// @return The underlying balance (mTokens * exchangeRate)
    function balanceOfUnderlying(address owner) external returns (uint256);
}
