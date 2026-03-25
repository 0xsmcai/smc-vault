// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @title MockMoonwell — Mock cToken for unit testing
/// @dev Simulates Moonwell mWETH behavior: mint/redeem with exchange rate
contract MockMoonwell {
    IERC20 public underlying;

    mapping(address => uint256) public balanceOf;
    uint256 public exchangeRateStored = 1e18; // 1:1 initially
    bool public mintGuardianPaused;
    bool public forceRedeemFail;
    bool public forceMintFail;
    uint256 public totalMTokens;

    constructor(address _underlying) {
        underlying = IERC20(_underlying);
    }

    function mint(uint256 mintAmount) external returns (uint256) {
        if (mintGuardianPaused) return 1; // Error code
        if (forceMintFail) return 2; // Non-zero error code (different from guardian pause)
        underlying.transferFrom(msg.sender, address(this), mintAmount);
        uint256 mTokens = (mintAmount * 1e18) / exchangeRateStored;
        balanceOf[msg.sender] += mTokens;
        totalMTokens += mTokens;
        return 0; // Success
    }

    function redeem(uint256 redeemTokens) external returns (uint256) {
        if (forceRedeemFail) return 1;
        uint256 underlyingAmount = (redeemTokens * exchangeRateStored) / 1e18;
        balanceOf[msg.sender] -= redeemTokens;
        totalMTokens -= redeemTokens;
        underlying.transfer(msg.sender, underlyingAmount);
        return 0;
    }

    function redeemUnderlying(uint256 redeemAmount) external returns (uint256) {
        if (forceRedeemFail) return 1;
        uint256 mTokens = (redeemAmount * 1e18) / exchangeRateStored;
        if (mTokens > balanceOf[msg.sender]) return 1; // Insufficient
        balanceOf[msg.sender] -= mTokens;
        totalMTokens -= mTokens;
        underlying.transfer(msg.sender, redeemAmount);
        return 0;
    }

    function balanceOfUnderlying(address owner) external view returns (uint256) {
        return (balanceOf[owner] * exchangeRateStored) / 1e18;
    }

    // ===== Test helpers =====

    function setExchangeRate(uint256 rate) external {
        exchangeRateStored = rate;
    }

    function setMintGuardianPaused(bool paused) external {
        mintGuardianPaused = paused;
    }

    function setForceRedeemFail(bool fail) external {
        forceRedeemFail = fail;
    }

    function setForceMintFail(bool fail) external {
        forceMintFail = fail;
    }
}
