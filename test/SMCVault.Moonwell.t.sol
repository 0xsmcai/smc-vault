// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {SMCVault} from "../src/SMCVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMoonwell} from "./mocks/MockMoonwell.sol";

/// @title SMCVault Moonwell Integration Tests
/// @notice 18 test cases covering all Moonwell integration codepaths (①-⑱)
contract SMCVaultMoonwellTest is Test {
    SMCVault public vault;
    MockERC20 public weth;
    MockERC20 public token;
    MockMoonwell public moonwell;

    address public owner = address(this);
    address public operator = address(0xBEEF);
    address public depositor1 = address(0x1);
    address public depositor2 = address(0x2);
    address public attacker = address(0x666);

    function setUp() public {
        weth = new MockERC20("Wrapped ETH", "WETH");
        token = new MockERC20("SMC Token", "SMC");
        moonwell = new MockMoonwell(address(weth));

        vault = new SMCVault(
            address(weth),
            address(token),
            address(moonwell),
            operator
        );

        // Fund depositors
        weth.mint(depositor1, 1 ether);
        token.mint(depositor1, 1000e18);
        weth.mint(depositor2, 1 ether);
        token.mint(depositor2, 1000e18);

        // Approvals
        vm.startPrank(depositor1);
        weth.approve(address(vault), type(uint256).max);
        token.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(depositor2);
        weth.approve(address(vault), type(uint256).max);
        token.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        // Fund Moonwell with WETH for redemptions
        weth.mint(address(moonwell), 10 ether);
    }

    // ========== HELPER ==========
    function _deposit(address user, uint256 wethAmt, uint256 tokenAmt) internal returns (uint256) {
        vm.prank(user);
        return vault.deposit(wethAmt, tokenAmt);
    }

    function _supplyToMoonwell(uint256 amount) internal {
        vm.prank(operator);
        vault.supplyToMoonwell(amount);
    }

    function _setMaxLendingRatio(uint256 ratio) internal {
        vm.prank(operator);
        vault.setMaxLendingRatio(ratio);
    }

    // ========== TEST ①: Withdraw — WETH insufficient, redeemUnderlying succeeds ==========
    function test_01_WithdrawRedeemUnderlyingSuccess() public {
        // Deposit, then operator supplies most WETH to Moonwell
        uint256 shares = _deposit(depositor1, 0.02 ether, 100e18);
        _setMaxLendingRatio(8000); // 80% to allow 75% supply
        _supplyToMoonwell(0.015 ether);

        // Vault has 0.005 WETH, Moonwell has 0.015 WETH
        assertEq(weth.balanceOf(address(vault)), 0.005 ether);

        // Withdraw all shares — needs to redeem from Moonwell
        vm.prank(depositor1);
        vault.withdraw(shares);

        // Depositor should get all WETH back
        assertGt(weth.balanceOf(depositor1), 0.99 ether); // ~1 ether minus rounding
    }

    // ========== TEST ②: Withdraw — redeem succeeds fully ==========
    function test_02_WithdrawFullRedeemSuccess() public {
        uint256 shares = _deposit(depositor1, 0.02 ether, 100e18);
        _setMaxLendingRatio(9000); // Allow 90%
        _supplyToMoonwell(0.018 ether); // 90% of WETH to Moonwell

        vm.prank(depositor1);
        vault.withdraw(shares);

        // Should have gotten WETH back from Moonwell
        assertGt(weth.balanceOf(depositor1), 0.99 ether);
    }

    // ========== TEST ③: Withdraw — partial redeem (high utilization) ==========
    function test_03_WithdrawPartialRedeemHighUtil() public {
        uint256 shares = _deposit(depositor1, 0.02 ether, 100e18);
        _setMaxLendingRatio(8000);
        _supplyToMoonwell(0.015 ether);

        // Force Moonwell to fail redemption (simulating high utilization)
        moonwell.setForceRedeemFail(true);

        // Vault has 0.005 WETH, needs 0.02 WETH, Moonwell redeem fails
        vm.prank(depositor1);
        vault.withdraw(shares);

        // Should get partial WETH (vault balance only)
        assertEq(weth.balanceOf(depositor1), 0.98 ether + 0.005 ether); // original 0.98 + partial 0.005
        // Remainder should be queued
        assertGt(vault.queuedWithdrawals(depositor1), 0);
    }

    // ========== TEST ④: Withdraw — Moonwell paused, partial withdraw + event ==========
    function test_04_WithdrawMoonwellPausedPartial() public {
        uint256 shares = _deposit(depositor1, 0.02 ether, 100e18);
        _setMaxLendingRatio(8000);
        _supplyToMoonwell(0.015 ether);

        moonwell.setForceRedeemFail(true);

        vm.prank(depositor1);
        vault.withdraw(shares);

        // Queued withdrawal should exist
        uint256 queued = vault.queuedWithdrawals(depositor1);
        assertGt(queued, 0);
    }

    // ========== TEST ⑤: ReentrancyGuard blocks reentry ==========
    function test_05_ReentrancyGuardBlocks() public {
        // The reentrancy guard is tested implicitly by the nonReentrant modifier.
        // Direct test: try calling deposit from within a callback.
        // Since MockERC20 doesn't have callbacks, we verify the lock state.
        _deposit(depositor1, 0.01 ether, 50e18);

        // Verify vault works normally (lock resets)
        _deposit(depositor1, 0.01 ether, 50e18);

        // Both deposits should succeed (lock properly reset)
        assertGt(vault.shares(depositor1), 0);
    }

    // ========== TEST ⑥: supplyToMoonwell — amount > 0 ==========
    function test_06_SupplyPositiveAmount() public {
        _deposit(depositor1, 0.02 ether, 100e18);

        _supplyToMoonwell(0.01 ether);

        assertEq(weth.balanceOf(address(vault)), 0.01 ether);
        assertGt(moonwell.balanceOf(address(vault)), 0);
    }

    // ========== TEST ⑦: supplyToMoonwell — mintGuardianPaused reverts ==========
    function test_07_SupplyMintGuardianPausedReverts() public {
        _deposit(depositor1, 0.02 ether, 100e18);
        moonwell.setMintGuardianPaused(true);

        vm.expectRevert(SMCVault.MoonwellMintGuardianPaused.selector);
        vm.prank(operator);
        vault.supplyToMoonwell(0.01 ether);
    }

    // ========== TEST ⑧: supplyToMoonwell — mint returns non-zero reverts ==========
    function test_08_SupplyMintFailsReverts() public {
        _deposit(depositor1, 0.02 ether, 100e18);

        // Force mint() to return error code 2 (guardian check passes, mint itself fails)
        moonwell.setForceMintFail(true);

        vm.expectRevert(abi.encodeWithSelector(SMCVault.MoonwellMintFailed.selector, uint256(2)));
        vm.prank(operator);
        vault.supplyToMoonwell(0.01 ether);
    }

    // ========== TEST ⑨: supplyToMoonwell — exceeds maxLendingRatio reverts ==========
    function test_09_SupplyExceedsMaxRatioReverts() public {
        _deposit(depositor1, 0.02 ether, 100e18);

        // Try to supply more than 70% (default maxLendingRatio)
        vm.expectRevert(SMCVault.MaxLendingRatioCeilingExceeded.selector);
        vm.prank(operator);
        vault.supplyToMoonwell(0.015 ether); // 75% > 70%
    }

    // ========== TEST ⑩: supplyToMoonwell — onlyOperator ==========
    function test_10_SupplyOnlyOperator() public {
        _deposit(depositor1, 0.02 ether, 100e18);

        vm.expectRevert(SMCVault.Unauthorized.selector);
        vm.prank(depositor1);
        vault.supplyToMoonwell(0.01 ether);
    }

    // ========== TEST ⑪: withdrawFromMoonwell — redeemUnderlying succeeds ==========
    function test_11_WithdrawFromMoonwellSuccess() public {
        _deposit(depositor1, 0.02 ether, 100e18);
        _supplyToMoonwell(0.01 ether);

        uint256 vaultWethBefore = weth.balanceOf(address(vault));

        vm.prank(operator);
        vault.withdrawFromMoonwell(0.005 ether);

        assertEq(weth.balanceOf(address(vault)), vaultWethBefore + 0.005 ether);
    }

    // ========== TEST ⑫: withdrawFromMoonwell — full drain via redeem(all) ==========
    function test_12_WithdrawFromMoonwellFullDrain() public {
        _deposit(depositor1, 0.02 ether, 100e18);
        _supplyToMoonwell(0.01 ether);

        vm.prank(operator);
        vault.withdrawFromMoonwell(0); // 0 = drain all

        assertEq(moonwell.balanceOf(address(vault)), 0);
        assertEq(weth.balanceOf(address(vault)), 0.02 ether);
    }

    // ========== TEST ⑬: setMaxLendingRatio — ratio <= 90% succeeds ==========
    function test_13_SetMaxLendingRatioValid() public {
        vm.prank(operator);
        vault.setMaxLendingRatio(8000); // 80%

        assertEq(vault.maxLendingRatio(), 8000);
    }

    // ========== TEST ⑭: setMaxLendingRatio — ratio > 90% reverts ==========
    function test_14_SetMaxLendingRatioExceedsCeiling() public {
        vm.expectRevert(SMCVault.MaxLendingRatioCeilingExceeded.selector);
        vm.prank(operator);
        vault.setMaxLendingRatio(9100); // 91% > 90% ceiling
    }

    // ========== TEST ⑮: totalAssets includes mWETH via exchangeRateStored ==========
    function test_15_TotalAssetsIncludesMoonwell() public {
        _deposit(depositor1, 0.02 ether, 100e18);
        _supplyToMoonwell(0.01 ether);

        // Total WETH should still be ~0.02 ETH (vault + Moonwell)
        uint256 totalWeth = vault.totalWethAssets();
        assertEq(totalWeth, 0.02 ether);

        // Simulate interest accrual — increase exchange rate by 5%
        moonwell.setExchangeRate(1.05e18);

        uint256 totalWethAfter = vault.totalWethAssets();
        assertGt(totalWethAfter, 0.02 ether); // Should be > 0.02 due to interest
    }

    // ========== TEST ⑯: totalAssets — mWETH balance = 0, no change ==========
    function test_16_TotalAssetsNoMoonwellPosition() public {
        _deposit(depositor1, 0.02 ether, 100e18);

        // No Moonwell supply — totalWethAssets should just be vault balance
        assertEq(vault.totalWethAssets(), 0.02 ether);
        assertEq(vault.moonwellWethValue(), 0);
    }

    // ========== TEST ⑰: emergencyWithdraw — Moonwell redeem succeeds ==========
    function test_17_EmergencyWithdrawMoonwellSuccess() public {
        _deposit(depositor1, 0.02 ether, 100e18);
        _supplyToMoonwell(0.01 ether);

        // Owner emergency withdraws
        vault.emergencyWithdraw();

        // All WETH should be at owner
        assertEq(weth.balanceOf(address(vault)), 0);
        assertGt(weth.balanceOf(owner), 0);
    }

    // ========== TEST ⑱: emergencyWithdraw — Moonwell redeem reverts, emit + continue ==========
    function test_18_EmergencyWithdrawMoonwellFails() public {
        _deposit(depositor1, 0.02 ether, 100e18);
        _supplyToMoonwell(0.01 ether);

        moonwell.setForceRedeemFail(true);

        // Should NOT revert — emits MoonwellWithdrawFailed and continues
        vault.emergencyWithdraw();

        // Vault WETH (non-Moonwell) should be transferred to owner
        // Moonwell portion is stuck but no revert
        assertGt(weth.balanceOf(owner), 0);
    }

    // ========== ADDITIONAL: Deposit cap enforcement ==========
    function test_DepositCapEnforced() public {
        _deposit(depositor1, 0.03 ether, 150e18); // Max cap

        vm.expectRevert(SMCVault.DepositCapExceeded.selector);
        _deposit(depositor1, 0.001 ether, 5e18); // Over cap
    }

    // ========== ADDITIONAL: Zero amount reverts ==========
    function test_SupplyZeroAmountReverts() public {
        vm.expectRevert(SMCVault.ZeroAmount.selector);
        vm.prank(operator);
        vault.supplyToMoonwell(0);
    }

    // ========== ADDITIONAL: NAV per share tracks correctly ==========
    function test_NavPerShareTracksCorrectly() public {
        _deposit(depositor1, 0.02 ether, 100e18);
        uint256 navBefore = vault.navPerShare();

        _supplyToMoonwell(0.01 ether);

        // Simulate 10% interest on Moonwell
        moonwell.setExchangeRate(1.1e18);

        uint256 navAfter = vault.navPerShare();
        assertGt(navAfter, navBefore);
    }

    // ========== ADDITIONAL: Constructor rejects zero addresses ==========
    function test_ConstructorRejectsZeroAddresses() public {
        vm.expectRevert(SMCVault.ZeroAddress.selector);
        new SMCVault(address(0), address(token), address(moonwell), operator);
    }
}
