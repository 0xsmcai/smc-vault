// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {SMCVault} from "../src/SMCVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMoonwell} from "./mocks/MockMoonwell.sol";

/// @title SMCVault v3 — Comprehensive Test Suite
/// @notice Tests all features: deposit, withdrawal queue, emergency, operator LP management,
///         Moonwell lending, performance fees, security constraints.
contract SMCVaultTest is Test {
    SMCVault public vault;
    MockERC20 public weth;
    MockERC20 public token;
    MockMoonwell public moonwell;

    address public owner;
    address public operator = address(0xBEEF);
    address public uniswapPM = address(0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public attacker = address(0x666);

    function setUp() public {
        owner = address(this);
        weth = new MockERC20("Wrapped ETH", "WETH");
        token = new MockERC20("SMC Token", "SMC");
        moonwell = new MockMoonwell(address(weth));

        vault = new SMCVault(
            address(weth),
            address(token),
            address(moonwell),
            uniswapPM,
            operator
        );

        // Fund depositors
        weth.mint(alice, 1 ether);
        token.mint(alice, 1_000_000e18);
        weth.mint(bob, 1 ether);
        token.mint(bob, 1_000_000e18);

        // Approvals
        vm.startPrank(alice);
        weth.approve(address(vault), type(uint256).max);
        token.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        weth.approve(address(vault), type(uint256).max);
        token.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        // Fund Moonwell for redemptions
        weth.mint(address(moonwell), 10 ether);
    }

    // ═══════════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════════

    function _deposit(address user, uint256 wethAmt, uint256 tokenAmt) internal returns (uint256) {
        vm.prank(user);
        return vault.deposit(wethAmt, tokenAmt);
    }

    function _requestWithdrawal(address user, uint256 shareAmt) internal {
        vm.prank(user);
        vault.requestWithdrawal(shareAmt);
    }

    // ═══════════════════════════════════════════════
    //  DEPOSIT TESTS
    // ═══════════════════════════════════════════════

    function test_firstDeposit() public {
        uint256 shares = _deposit(alice, 0.02 ether, 100e18);

        assertGt(shares, 0);
        assertGt(vault.shares(alice), 0);
        assertEq(weth.balanceOf(address(vault)), 0.02 ether);
        assertEq(token.balanceOf(address(vault)), 100e18);
    }

    function test_deadSharesProtection() public {
        _deposit(alice, 0.02 ether, 100e18);
        assertEq(vault.shares(address(0xdead)), 1000);
    }

    function test_secondDeposit() public {
        _deposit(alice, 0.02 ether, 100e18);
        uint256 bobShares = _deposit(bob, 0.003 ether, 15e18); // <20% of TVL
        assertGt(bobShares, 0);
    }

    function test_revertDepositTooSmall() public {
        vm.prank(alice);
        vm.expectRevert(SMCVault.DepositTooSmall.selector);
        vault.deposit(0.001 ether, 1e18); // Below MIN_DEPOSIT
    }

    function test_revertDepositCapExceeded() public {
        _deposit(alice, 0.03 ether, 150e18); // Max cap

        vm.prank(alice);
        vm.expectRevert(SMCVault.DepositCapExceeded.selector);
        vault.deposit(0.0025 ether, 5e18); // Over cap (already at max)
    }

    function test_revertDepositTooLarge() public {
        _deposit(alice, 0.02 ether, 100e18); // Seed TVL

        // Bob tries to deposit >20% of TVL
        vm.prank(bob);
        vm.expectRevert(SMCVault.DepositTooLarge.selector);
        vault.deposit(0.02 ether, 100e18); // 100% of TVL > 20%
    }

    // ═══════════════════════════════════════════════
    //  WITHDRAWAL QUEUE TESTS
    // ═══════════════════════════════════════════════

    function test_requestWithdrawal() public {
        _deposit(alice, 0.02 ether, 100e18);
        uint256 aliceShares = vault.shares(alice);

        vm.warp(block.timestamp + 1 hours + 1);
        _requestWithdrawal(alice, aliceShares);

        assertEq(vault.shares(alice), 0);
        assertEq(vault.getWithdrawalQueueLength(), 1);
    }

    function test_revertWithdrawalCooldown() public {
        _deposit(alice, 0.02 ether, 100e18);
        uint256 s = vault.shares(alice);

        vm.prank(alice);
        vm.expectRevert(SMCVault.CooldownNotMet.selector);
        vault.requestWithdrawal(s);
    }

    function test_revertZeroShareWithdrawal() public {
        _deposit(alice, 0.02 ether, 100e18);
        vm.warp(block.timestamp + 1 hours + 1);

        vm.prank(alice);
        vm.expectRevert(SMCVault.ZeroAmount.selector);
        vault.requestWithdrawal(0);
    }

    function test_processWithdrawal() public {
        _deposit(alice, 0.02 ether, 100e18);
        uint256 aliceShares = vault.shares(alice);

        vm.warp(block.timestamp + 1 hours + 1);
        _requestWithdrawal(alice, aliceShares);

        uint256 wethBefore = weth.balanceOf(alice);
        uint256 tokenBefore = token.balanceOf(alice);

        vm.prank(operator);
        vault.processWithdrawal(0);

        assertGt(weth.balanceOf(alice), wethBefore);
        assertGt(token.balanceOf(alice), tokenBefore);
    }

    function test_revertProcessNonOperator() public {
        _deposit(alice, 0.02 ether, 100e18);
        vm.warp(block.timestamp + 1 hours + 1);
        _requestWithdrawal(alice, vault.shares(alice));

        vm.prank(alice);
        vm.expectRevert(SMCVault.Unauthorized.selector);
        vault.processWithdrawal(0);
    }

    // ═══════════════════════════════════════════════
    //  EMERGENCY WITHDRAWAL TESTS
    // ═══════════════════════════════════════════════

    function test_emergencyWithdraw() public {
        _deposit(alice, 0.02 ether, 100e18);
        uint256 aliceShares = vault.shares(alice);

        vm.warp(block.timestamp + 1 hours + 1);
        _requestWithdrawal(alice, aliceShares);

        // Wait 4 hours
        vm.warp(block.timestamp + 4 hours + 1);

        uint256 wethBefore = weth.balanceOf(alice);
        vm.prank(alice);
        vault.emergencyWithdraw(0);

        assertGt(weth.balanceOf(alice), wethBefore);
    }

    function test_revertEmergencyTooEarly() public {
        _deposit(alice, 0.02 ether, 100e18);
        vm.warp(block.timestamp + 1 hours + 1);
        _requestWithdrawal(alice, vault.shares(alice));

        vm.warp(block.timestamp + 2 hours);
        vm.prank(alice);
        vm.expectRevert(SMCVault.EmergencyNotReady.selector);
        vault.emergencyWithdraw(0);
    }

    function test_revertEmergencyWrongUser() public {
        _deposit(alice, 0.02 ether, 100e18);
        vm.warp(block.timestamp + 1 hours + 1);
        _requestWithdrawal(alice, vault.shares(alice));

        vm.warp(block.timestamp + 4 hours + 1);
        vm.prank(bob);
        vm.expectRevert(SMCVault.Unauthorized.selector);
        vault.emergencyWithdraw(0);
    }

    function test_emergencyWithdrawWithMoonwell() public {
        _deposit(alice, 0.02 ether, 100e18);

        // Supply most WETH to Moonwell
        vm.prank(operator);
        vault.supplyToMoonwell(0.013 ether);

        uint256 aliceShares = vault.shares(alice);
        vm.warp(block.timestamp + 1 hours + 1);
        _requestWithdrawal(alice, aliceShares);

        vm.warp(block.timestamp + 4 hours + 1);
        vm.prank(alice);
        vault.emergencyWithdraw(0);

        // Alice should get WETH back (from vault + Moonwell)
        assertGt(weth.balanceOf(alice), 0.98 ether);
    }

    // ═══════════════════════════════════════════════
    //  OPERATOR EXECUTE (UNISWAP) TESTS
    // ═══════════════════════════════════════════════

    function test_operatorExecuteAllowedSelector() public {
        // mint selector 0x88316456 — will fail at Uniswap level but pass our checks
        // Build minimal calldata with vault as recipient at correct offset
        bytes memory data = new bytes(356);
        data[0] = 0x88; data[1] = 0x31; data[2] = 0x64; data[3] = 0x56; // selector

        // Set recipient at offset 292 (10th word) to vault address
        bytes20 vaultAddr = bytes20(address(vault));
        for (uint i = 0; i < 20; i++) {
            data[304 + i] = vaultAddr[i]; // offset 292 + 12 (left-padding)
        }

        vm.prank(operator);
        // Will revert at Uniswap level (mock address), not at our allowlist
        try vault.operatorExecute(data) {} catch (bytes memory reason) {
            assertTrue(bytes4(reason) != SMCVault.UnauthorizedCall.selector);
            assertTrue(bytes4(reason) != SMCVault.InvalidRecipient.selector);
        }
    }

    function test_revertUnauthorizedSelector() public {
        bytes memory data = abi.encodeWithSelector(bytes4(0x12345678));
        vm.prank(operator);
        vm.expectRevert(SMCVault.UnauthorizedCall.selector);
        vault.operatorExecute(data);
    }

    function test_revertInvalidRecipientMint() public {
        // mint selector with wrong recipient
        bytes memory data = new bytes(356);
        data[0] = 0x88; data[1] = 0x31; data[2] = 0x64; data[3] = 0x56;
        // Recipient at offset 292 is zero (not vault)

        vm.prank(operator);
        vm.expectRevert(SMCVault.InvalidRecipient.selector);
        vault.operatorExecute(data);
    }

    function test_revertInvalidRecipientCollect() public {
        // collect selector 0xfc6f7865 with wrong recipient
        bytes memory data = new bytes(132);
        data[0] = 0xfc; data[1] = 0x6f; data[2] = 0x78; data[3] = 0x65;
        // Recipient at offset 36 is zero (not vault)

        vm.prank(operator);
        vm.expectRevert(SMCVault.InvalidRecipient.selector);
        vault.operatorExecute(data);
    }

    function test_revertOperatorExecuteNonOperator() public {
        bytes memory data = abi.encodeWithSelector(bytes4(0x88316456));
        vm.prank(alice);
        vm.expectRevert(SMCVault.Unauthorized.selector);
        vault.operatorExecute(data);
    }

    // ═══════════════════════════════════════════════
    //  MOONWELL LENDING TESTS
    // ═══════════════════════════════════════════════

    function test_supplyToMoonwell() public {
        _deposit(alice, 0.02 ether, 100e18);
        vm.prank(operator);
        vault.supplyToMoonwell(0.01 ether);

        assertEq(weth.balanceOf(address(vault)), 0.01 ether);
        assertGt(moonwell.balanceOf(address(vault)), 0);
    }

    function test_revertSupplyExceedsRatio() public {
        _deposit(alice, 0.02 ether, 100e18);
        vm.expectRevert(SMCVault.MaxLendingRatioCeilingExceeded.selector);
        vm.prank(operator);
        vault.supplyToMoonwell(0.015 ether); // 75% > 70% default
    }

    function test_revertSupplyMintPaused() public {
        _deposit(alice, 0.02 ether, 100e18);
        moonwell.setMintGuardianPaused(true);

        vm.expectRevert(SMCVault.MoonwellMintGuardianPaused.selector);
        vm.prank(operator);
        vault.supplyToMoonwell(0.01 ether);
    }

    function test_revertSupplyMintFails() public {
        _deposit(alice, 0.02 ether, 100e18);
        moonwell.setForceMintFail(true);

        vm.expectRevert(abi.encodeWithSelector(SMCVault.MoonwellMintFailed.selector, uint256(2)));
        vm.prank(operator);
        vault.supplyToMoonwell(0.01 ether);
    }

    function test_withdrawFromMoonwell() public {
        _deposit(alice, 0.02 ether, 100e18);
        vm.prank(operator);
        vault.supplyToMoonwell(0.01 ether);

        vm.prank(operator);
        vault.withdrawFromMoonwell(0.005 ether);

        assertEq(weth.balanceOf(address(vault)), 0.015 ether);
    }

    function test_withdrawFromMoonwellFullDrain() public {
        _deposit(alice, 0.02 ether, 100e18);
        vm.prank(operator);
        vault.supplyToMoonwell(0.01 ether);

        vm.prank(operator);
        vault.withdrawFromMoonwell(0); // 0 = drain all

        assertEq(moonwell.balanceOf(address(vault)), 0);
        assertEq(weth.balanceOf(address(vault)), 0.02 ether);
    }

    function test_totalAssetsIncludesMoonwell() public {
        _deposit(alice, 0.02 ether, 100e18);
        vm.prank(operator);
        vault.supplyToMoonwell(0.01 ether);

        // Total should include Moonwell position
        (uint256 wethTotal,) = vault.totalAssets();
        assertEq(wethTotal, 0.02 ether);

        // Simulate 5% interest
        moonwell.setExchangeRate(1.05e18);
        (uint256 wethAfter,) = vault.totalAssets();
        assertGt(wethAfter, 0.02 ether);
    }

    // ═══════════════════════════════════════════════
    //  PERFORMANCE FEE TESTS
    // ═══════════════════════════════════════════════

    function test_noFeeUnderwater() public {
        _deposit(alice, 0.02 ether, 100e18);
        vault.collectFees(); // Should not revert, fees = 0
        assertEq(vault.reservedFees(), 0);
    }

    function test_feeOnMoonwellInterest() public {
        _deposit(alice, 0.02 ether, 100e18);
        vm.prank(operator);
        vault.supplyToMoonwell(0.01 ether);

        // Simulate 10% interest
        moonwell.setExchangeRate(1.1e18);

        uint256 ownerBefore = weth.balanceOf(owner);
        vault.collectFees();
        assertGt(weth.balanceOf(owner), ownerBefore);
    }

    function test_feeCollectedBeforeWithdrawal() public {
        _deposit(alice, 0.02 ether, 100e18);
        vm.prank(operator);
        vault.supplyToMoonwell(0.01 ether);
        moonwell.setExchangeRate(1.1e18);

        vm.warp(block.timestamp + 1 hours + 1);
        _requestWithdrawal(alice, vault.shares(alice));

        vm.prank(operator);
        vault.processWithdrawal(0);

        // Fee should have been collected
        assertGt(vault.highWaterMark(), 1e18);
    }

    // ═══════════════════════════════════════════════
    //  ADMIN TESTS
    // ═══════════════════════════════════════════════

    function test_setOperator() public {
        address newOp = address(0xCAFE);
        vault.setOperator(newOp);
        assertEq(vault.operator(), newOp);
    }

    function test_revertSetOperatorNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(SMCVault.Unauthorized.selector);
        vault.setOperator(address(0xCAFE));
    }

    function test_setMaxLendingRatio() public {
        vm.prank(operator);
        vault.setMaxLendingRatio(8000);
        assertEq(vault.maxLendingRatio(), 8000);
    }

    function test_revertSetRatioTooHigh() public {
        vm.expectRevert(SMCVault.MaxLendingRatioCeilingExceeded.selector);
        vm.prank(operator);
        vault.setMaxLendingRatio(9100);
    }

    function test_addRemoveSelector() public {
        bytes4 sel = bytes4(0xabcdef01);
        vault.addAllowedSelector(sel);
        assertTrue(vault.allowedSelectors(sel));
        vault.removeAllowedSelector(sel);
        assertFalse(vault.allowedSelectors(sel));
    }

    function test_emergencyDrain() public {
        _deposit(alice, 0.02 ether, 100e18);
        vm.prank(operator);
        vault.supplyToMoonwell(0.01 ether);

        vault.emergencyDrain();

        assertEq(weth.balanceOf(address(vault)), 0);
        assertGt(weth.balanceOf(owner), 0);
        assertGt(token.balanceOf(owner), 0);
    }

    function test_revertEmergencyDrainNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(SMCVault.Unauthorized.selector);
        vault.emergencyDrain();
    }

    // ═══════════════════════════════════════════════
    //  CONSTRUCTOR TESTS
    // ═══════════════════════════════════════════════

    function test_revertZeroWeth() public {
        vm.expectRevert(SMCVault.ZeroAddress.selector);
        new SMCVault(address(0), address(token), address(moonwell), uniswapPM, operator);
    }

    function test_revertZeroToken() public {
        vm.expectRevert(SMCVault.ZeroAddress.selector);
        new SMCVault(address(weth), address(0), address(moonwell), uniswapPM, operator);
    }

    function test_revertZeroMoonwell() public {
        vm.expectRevert(SMCVault.ZeroAddress.selector);
        new SMCVault(address(weth), address(token), address(0), uniswapPM, operator);
    }

    function test_revertZeroUniswapPM() public {
        vm.expectRevert(SMCVault.ZeroAddress.selector);
        new SMCVault(address(weth), address(token), address(moonwell), address(0), operator);
    }

    function test_revertZeroOperator() public {
        vm.expectRevert(SMCVault.ZeroAddress.selector);
        new SMCVault(address(weth), address(token), address(moonwell), uniswapPM, address(0));
    }

    // ═══════════════════════════════════════════════
    //  VIEW FUNCTION TESTS
    // ═══════════════════════════════════════════════

    function test_navPerShareInitial() public view {
        // Only dead shares — navPerShare should be 0 (dead shares / 0 WETH)
        // Actually totalShares = 1000 but no WETH deposited yet
        uint256 nav = vault.navPerShare();
        assertEq(nav, 0); // No WETH in vault
    }

    function test_navPerShareAfterDeposit() public {
        _deposit(alice, 0.02 ether, 100e18);
        uint256 nav = vault.navPerShare();
        assertGt(nav, 0);
    }

    function test_getDepositorInfo() public {
        _deposit(alice, 0.02 ether, 100e18);
        (uint256 shareBalance, uint256 wethValue, uint256 tokenValue) = vault.getDepositorInfo(alice);
        assertGt(shareBalance, 0);
        assertGt(wethValue, 0);
        assertGt(tokenValue, 0);
    }

    function test_withdrawalQueueLength() public {
        assertEq(vault.getWithdrawalQueueLength(), 0);

        _deposit(alice, 0.02 ether, 100e18);
        vm.warp(block.timestamp + 1 hours + 1);
        _requestWithdrawal(alice, vault.shares(alice));

        assertEq(vault.getWithdrawalQueueLength(), 1);
    }

    // ═══════════════════════════════════════════════
    //  MULTI-USER E2E FLOW
    // ═══════════════════════════════════════════════

    function test_fullLifecycle() public {
        // Alice deposits
        uint256 aliceShares = _deposit(alice, 0.02 ether, 100e18);

        // Bob deposits (within 20% TVL limit)
        uint256 bobShares = _deposit(bob, 0.003 ether, 15e18);

        // Operator supplies to Moonwell
        vm.prank(operator);
        vault.supplyToMoonwell(0.01 ether);

        // Interest accrues
        moonwell.setExchangeRate(1.05e18);

        // Owner collects fees
        vault.collectFees();
        assertGt(vault.highWaterMark(), 1e18);

        // Alice withdraws
        vm.warp(block.timestamp + 1 hours + 1);
        _requestWithdrawal(alice, aliceShares);

        vm.prank(operator);
        vault.processWithdrawal(0);

        // Bob still has shares
        assertGt(vault.shares(bob), 0);

        // Bob emergency withdraws after timeout
        _requestWithdrawal(bob, bobShares);
        vm.warp(block.timestamp + 4 hours + 1);
        vm.prank(bob);
        vault.emergencyWithdraw(1);

        // Both got their assets back
        assertGt(weth.balanceOf(alice), 0.98 ether);
        assertGt(weth.balanceOf(bob), 0.99 ether);
    }

    receive() external payable {}
}
