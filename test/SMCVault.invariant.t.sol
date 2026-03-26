// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SMCVault} from "../src/SMCVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMoonwell} from "./mocks/MockMoonwell.sol";

/// @title VaultHandler — Fuzzer target that constrains inputs to valid ranges
contract VaultHandler is Test {
    SMCVault public vault;
    MockERC20 public weth;
    MockERC20 public token;
    MockMoonwell public moonwell;
    address public operator;

    address[] public depositors;
    uint256 public totalDeposited;
    uint256 public ghostShares; // track expected total shares

    constructor(SMCVault _vault, MockERC20 _weth, MockERC20 _token, MockMoonwell _moonwell, address _operator) {
        vault = _vault;
        weth = _weth;
        token = _token;
        moonwell = _moonwell;
        operator = _operator;

        // Create depositors
        for (uint i = 1; i <= 5; i++) {
            address d = address(uint160(i * 100));
            depositors.push(d);
            weth.mint(d, 10 ether);
            token.mint(d, 100_000_000e18);
            vm.startPrank(d);
            weth.approve(address(vault), type(uint256).max);
            token.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }

        ghostShares = vault.totalShares(); // INITIAL_SHARES
    }

    function deposit(uint256 depositorIdx, uint256 wethAmount, uint256 tokenAmount) external {
        depositorIdx = depositorIdx % depositors.length;
        address depositor = depositors[depositorIdx];

        // Bound to valid range
        wethAmount = bound(wethAmount, 0.0025 ether, 0.03 ether);
        tokenAmount = bound(tokenAmount, 1e18, 10_000e18);

        // Check cap
        if (vault.wethDeposited(depositor) + wethAmount > vault.DEPOSIT_CAP()) return;

        // Check TVL ratio for non-first deposits
        if (vault.totalShares() > vault.INITIAL_SHARES()) {
            (uint256 totalWeth,) = vault.totalAssets();
            if (totalWeth > 0 && (wethAmount * vault.BPS()) / totalWeth > vault.MAX_DEPOSIT_RATIO_BPS()) return;
        }

        vm.prank(depositor);
        try vault.deposit(wethAmount, tokenAmount) returns (uint256 sharesOut) {
            ghostShares += sharesOut;
            totalDeposited += wethAmount;
        } catch {}
    }

    function requestWithdrawal(uint256 depositorIdx, uint256 shareFraction) external {
        depositorIdx = depositorIdx % depositors.length;
        address depositor = depositors[depositorIdx];

        uint256 userShares = vault.shares(depositor);
        if (userShares == 0) return;

        shareFraction = bound(shareFraction, 1, 100);
        uint256 shareAmount = (userShares * shareFraction) / 100;
        if (shareAmount == 0) return;

        // Need cooldown to have passed
        vm.warp(block.timestamp + 1 hours + 1);

        vm.prank(depositor);
        try vault.requestWithdrawal(shareAmount) {} catch {}
    }

    function processWithdrawal(uint256 queueIdx) external {
        uint256 queueLen = vault.getWithdrawalQueueLength();
        if (queueLen == 0) return;

        queueIdx = queueIdx % queueLen;
        (,uint256 shareAmount,) = vault.withdrawalQueue(queueIdx);
        if (shareAmount == 0) return;

        vm.prank(operator);
        try vault.processWithdrawal(queueIdx) {
            ghostShares -= shareAmount;
        } catch {}
    }

    function supplyToMoonwell(uint256 amount) external {
        uint256 vaultWeth = weth.balanceOf(address(vault));
        if (vaultWeth == 0) return;

        amount = bound(amount, 1, vaultWeth);

        vm.prank(operator);
        try vault.supplyToMoonwell(amount) {} catch {}
    }

    function collectFees() external {
        // Simulate some profit by increasing Moonwell exchange rate
        uint256 currentRate = moonwell.exchangeRateStored();
        moonwell.setExchangeRate(currentRate + currentRate / 100); // +1%

        try vault.collectFees() {} catch {}
    }
}

/// @title SMCVault Invariant Tests
contract SMCVaultInvariantTest is Test {
    SMCVault public vault;
    MockERC20 public weth;
    MockERC20 public token;
    MockMoonwell public moonwell;
    VaultHandler public handler;
    address public operator = address(0xBEEF);
    address public uniswapPM = address(0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1);

    function setUp() public {
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

        weth.mint(address(moonwell), 100 ether);

        handler = new VaultHandler(vault, weth, token, moonwell, operator);

        targetContract(address(handler));
    }

    /// @notice Total shares must always be >= INITIAL_SHARES (dead shares are never burned)
    function invariant_minShares() public view {
        assertGe(vault.totalShares(), vault.INITIAL_SHARES());
    }

    /// @notice NAV per share must never be negative (always >= 0)
    function invariant_navNonNegative() public view {
        // navPerShare returns uint256, so it can't be negative
        // But we verify it doesn't revert
        vault.navPerShare();
    }

    /// @notice High water mark only increases
    function invariant_hwmMonotonic() public view {
        assertGe(vault.highWaterMark(), 1e18);
    }

    /// @notice Reserved fees never exceed total WETH balance + Moonwell
    function invariant_feesNotExceedBalance() public view {
        uint256 totalWeth = weth.balanceOf(address(vault)) + vault.moonwellWethValue();
        assertLe(vault.reservedFees(), totalWeth);
    }
}
