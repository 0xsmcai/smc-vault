// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IMoonwell} from "./interfaces/IMoonwell.sol";
import {IWETH} from "./interfaces/IWETH.sol";

/// @title SMCVault — Community Liquidity Engine Vault
/// @notice Dual-asset vault (WETH + token) with Moonwell lending on idle WETH.
///         ERC-4626-inspired but not strictly compliant (dual-asset deposits).
/// @dev    Operator (keeper bot) can only interact with Uniswap + Moonwell.
///         $100 cap per depositor. NAV-per-share high-water mark performance fee.
///
/// Architecture:
///   Depositor → Vault (holds WETH + token + mWETH)
///                 ├── Uniswap LP positions (active capital, managed by operator)
///                 └── Moonwell supply (idle WETH, earns lending yield)
///
/// Moonwell integration (Yield Boost Vault):
///   - Operator calls supplyToMoonwell() to lend idle WETH
///   - Operator calls withdrawFromMoonwell() to retrieve WETH before rebalance
///   - totalAssets() includes mWETH value via exchangeRateStored()
///   - Withdrawals auto-redeem from Moonwell if vault WETH is insufficient
///   - Emergency withdraw drains Moonwell positions
///
/// Security:
///   - ReentrancyGuard on all external state-changing functions
///   - MAX_LENDING_RATIO_CEILING = 90% (immutable, cannot be overridden)
///   - Partial withdrawal with WithdrawalQueued event if Moonwell has high utilization

contract SMCVault {
    // ========== ERRORS ==========
    error Unauthorized();
    error ZeroAmount();
    error ZeroAddress();
    error DepositCapExceeded();
    error MaxLendingRatioCeilingExceeded();
    error MoonwellMintFailed(uint256 errorCode);
    error MoonwellRedeemFailed(uint256 errorCode);
    error MoonwellMintGuardianPaused();
    error InsufficientShares();
    error TransferFailed();
    error ReentrantCall();

    // ========== EVENTS ==========
    event Deposit(address indexed depositor, uint256 wethAmount, uint256 tokenAmount, uint256 shares);
    event Withdraw(address indexed depositor, uint256 shares, uint256 wethOut, uint256 tokenOut);
    event WithdrawalQueued(address indexed depositor, uint256 remainingWeth);
    event MoonwellSupply(uint256 amount);
    event MoonwellWithdraw(uint256 amount);
    event MoonwellWithdrawFailed(uint256 errorCode);
    event MaxLendingRatioUpdated(uint256 oldRatio, uint256 newRatio);
    event PerformanceFeeCollected(uint256 feeWeth, uint256 feeToken);
    event EmergencyWithdrawExecuted(address indexed caller);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);

    // ========== CONSTANTS ==========
    /// @notice Maximum lending ratio ceiling — immutable, cannot exceed 90%
    uint256 public constant MAX_LENDING_RATIO_CEILING = 9000; // 90% in basis points
    /// @notice Basis points denominator
    uint256 public constant BPS = 10000;
    /// @notice Performance fee rate (10% of profits above high-water mark)
    uint256 public constant PERFORMANCE_FEE_BPS = 1000;
    /// @notice Deposit cap per wallet in WETH (0.03 ETH ~ $100 at ~$3300/ETH)
    uint256 public constant DEPOSIT_CAP = 0.03 ether;
    /// @notice Minimum deposit to prevent dust/inflation attacks
    uint256 public constant MIN_DEPOSIT = 0.001 ether;
    /// @notice Initial shares minted to dead address to prevent inflation attack
    uint256 public constant INITIAL_SHARES = 1000;

    // ========== STATE ==========
    IWETH public immutable weth;
    IERC20 public immutable token;
    IMoonwell public immutable moonwellMarket; // mWETH on Moonwell

    address public owner;
    address public operator; // Keeper bot address

    /// @notice Maximum ratio of WETH that can be lent to Moonwell (in BPS)
    uint256 public maxLendingRatio = 7000; // Default 70%

    /// @notice Total shares outstanding
    uint256 public totalShares;
    /// @notice Shares per depositor
    mapping(address => uint256) public shares;
    /// @notice WETH deposited per address (for cap tracking)
    mapping(address => uint256) public wethDeposited;

    /// @notice High-water mark for NAV per share (scaled by 1e18)
    uint256 public highWaterMark;

    /// @notice Queued withdrawal amounts (WETH owed but not yet delivered)
    mapping(address => uint256) public queuedWithdrawals;

    /// @notice Reentrancy lock
    uint256 private _locked = 1;

    // ========== MODIFIERS ==========
    modifier nonReentrant() {
        if (_locked != 1) revert ReentrantCall();
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert Unauthorized();
        _;
    }

    modifier onlyOwnerOrOperator() {
        if (msg.sender != owner && msg.sender != operator) revert Unauthorized();
        _;
    }

    // ========== CONSTRUCTOR ==========
    constructor(
        address _weth,
        address _token,
        address _moonwellMarket,
        address _operator
    ) {
        if (_weth == address(0) || _token == address(0) || _moonwellMarket == address(0) || _operator == address(0))
            revert ZeroAddress();

        weth = IWETH(_weth);
        token = IERC20(_token);
        moonwellMarket = IMoonwell(_moonwellMarket);
        operator = _operator;
        owner = msg.sender;

        // Pre-approve WETH to Moonwell for supply operations
        IERC20(_weth).approve(_moonwellMarket, type(uint256).max);

        // Initial shares to dead address to prevent ERC-4626 inflation attack
        totalShares = INITIAL_SHARES;
        shares[address(0xdead)] = INITIAL_SHARES;
        highWaterMark = 1e18; // 1:1 initial NAV per share
    }

    // ========== DEPOSIT ==========
    /// @notice Deposit WETH + token into the vault
    /// @param wethAmount Amount of WETH to deposit
    /// @param tokenAmount Amount of token to deposit
    /// @return sharesOut Shares minted to depositor
    function deposit(uint256 wethAmount, uint256 tokenAmount) external nonReentrant returns (uint256 sharesOut) {
        if (wethAmount < MIN_DEPOSIT) revert ZeroAmount();
        if (wethDeposited[msg.sender] + wethAmount > DEPOSIT_CAP) revert DepositCapExceeded();

        // Calculate shares based on current NAV
        uint256 totalWeth = totalWethAssets();

        if (totalShares == INITIAL_SHARES) {
            // First real deposit — shares = wethAmount (1:1)
            sharesOut = wethAmount;
        } else {
            // Pro-rata based on WETH portion of NAV
            sharesOut = (wethAmount * totalShares) / totalWeth;
        }

        // Transfer assets in
        weth.transferFrom(msg.sender, address(this), wethAmount);
        token.transferFrom(msg.sender, address(this), tokenAmount);

        // Mint shares
        totalShares += sharesOut;
        shares[msg.sender] += sharesOut;
        wethDeposited[msg.sender] += wethAmount;

        emit Deposit(msg.sender, wethAmount, tokenAmount, sharesOut);
    }

    // ========== WITHDRAW ==========
    /// @notice Withdraw proportional share of vault assets
    /// @param shareAmount Number of shares to redeem
    function withdraw(uint256 shareAmount) external nonReentrant {
        if (shareAmount == 0) revert ZeroAmount();
        if (shares[msg.sender] < shareAmount) revert InsufficientShares();

        // Collect performance fee BEFORE calculating owed amounts
        // so wethOwed reflects post-fee asset values
        _collectPerformanceFee();

        // Calculate proportional amounts (after fee collection)
        uint256 wethOwed = (shareAmount * totalWethAssets()) / totalShares;
        uint256 tokenOwed = (shareAmount * token.balanceOf(address(this))) / totalShares;

        // Burn shares
        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;

        // Check WETH balance in vault (excluding Moonwell)
        uint256 vaultWeth = weth.balanceOf(address(this));
        uint256 wethToSend = wethOwed;

        if (vaultWeth < wethOwed) {
            // Need to redeem from Moonwell
            uint256 shortfall = wethOwed - vaultWeth;
            uint256 redeemResult = moonwellMarket.redeemUnderlying(shortfall);

            if (redeemResult != 0) {
                // Partial redemption failed (high utilization) — send what we have, queue rest
                wethToSend = vaultWeth;
                uint256 remaining = wethOwed - vaultWeth;
                queuedWithdrawals[msg.sender] += remaining;
                emit WithdrawalQueued(msg.sender, remaining);
            }
            // If redeemResult == 0, we now have enough WETH
        }

        // Transfer assets out
        if (wethToSend > 0) {
            bool success = weth.transfer(msg.sender, wethToSend);
            if (!success) revert TransferFailed();
        }
        if (tokenOwed > 0) {
            bool success = token.transfer(msg.sender, tokenOwed);
            if (!success) revert TransferFailed();
        }

        // Update deposit tracking
        uint256 wethDepositReduction = (shareAmount * wethDeposited[msg.sender]) /
            (shares[msg.sender] + shareAmount); // original shares before burn
        if (wethDepositReduction > wethDeposited[msg.sender]) {
            wethDeposited[msg.sender] = 0;
        } else {
            wethDeposited[msg.sender] -= wethDepositReduction;
        }

        emit Withdraw(msg.sender, shareAmount, wethToSend, tokenOwed);
    }

    /// @notice Claim queued withdrawal amount (called after keeper processes shortfall)
    function claimQueuedWithdrawal() external nonReentrant {
        uint256 amount = queuedWithdrawals[msg.sender];
        if (amount == 0) revert ZeroAmount();

        queuedWithdrawals[msg.sender] = 0;

        uint256 available = weth.balanceOf(address(this));
        uint256 toSend = amount > available ? available : amount;

        if (toSend < amount) {
            queuedWithdrawals[msg.sender] = amount - toSend;
        }

        bool success = weth.transfer(msg.sender, toSend);
        if (!success) revert TransferFailed();
    }

    // ========== MOONWELL LENDING (OPERATOR) ==========

    /// @notice Supply idle WETH to Moonwell to earn lending yield
    /// @param amount Amount of WETH to supply
    function supplyToMoonwell(uint256 amount) external onlyOperator nonReentrant {
        if (amount == 0) revert ZeroAmount();

        // Check guardian pause
        if (moonwellMarket.mintGuardianPaused()) revert MoonwellMintGuardianPaused();

        // Enforce max lending ratio
        uint256 totalWeth = totalWethAssets();
        uint256 currentlyLent = _moonwellWethValue();
        uint256 afterLend = currentlyLent + amount;
        if (totalWeth > 0 && (afterLend * BPS) / totalWeth > maxLendingRatio)
            revert MaxLendingRatioCeilingExceeded();

        // Supply to Moonwell
        uint256 result = moonwellMarket.mint(amount);
        if (result != 0) revert MoonwellMintFailed(result);

        emit MoonwellSupply(amount);
    }

    /// @notice Withdraw WETH from Moonwell
    /// @param amount Amount of WETH to withdraw (0 = withdraw all)
    function withdrawFromMoonwell(uint256 amount) external onlyOperator nonReentrant {
        if (amount == 0) {
            // Full drain — redeem all mTokens
            uint256 mTokenBalance = moonwellMarket.balanceOf(address(this));
            if (mTokenBalance == 0) revert ZeroAmount();
            uint256 result = moonwellMarket.redeem(mTokenBalance);
            if (result != 0) revert MoonwellRedeemFailed(result);
        } else {
            uint256 result = moonwellMarket.redeemUnderlying(amount);
            if (result != 0) revert MoonwellRedeemFailed(result);
        }

        emit MoonwellWithdraw(amount);
    }

    /// @notice Update the max lending ratio (operator or owner)
    /// @param newRatio New ratio in basis points (max 9000 = 90%)
    function setMaxLendingRatio(uint256 newRatio) external onlyOwnerOrOperator {
        if (newRatio > MAX_LENDING_RATIO_CEILING) revert MaxLendingRatioCeilingExceeded();
        uint256 oldRatio = maxLendingRatio;
        maxLendingRatio = newRatio;
        emit MaxLendingRatioUpdated(oldRatio, newRatio);
    }

    /// @notice Update the operator address
    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert ZeroAddress();
        address old = operator;
        operator = newOperator;
        emit OperatorUpdated(old, newOperator);
    }

    // ========== EMERGENCY ==========

    /// @notice Emergency withdraw all positions. Owner only.
    /// @dev Drains Moonwell, transfers all assets to owner.
    function emergencyWithdraw() external onlyOwner nonReentrant {
        // Try to drain Moonwell
        uint256 mTokenBalance = moonwellMarket.balanceOf(address(this));
        if (mTokenBalance > 0) {
            uint256 result = moonwellMarket.redeem(mTokenBalance);
            if (result != 0) {
                // Moonwell paused or high utilization — emit event, continue
                emit MoonwellWithdrawFailed(result);
            }
        }

        // Transfer all WETH to owner
        uint256 wethBal = weth.balanceOf(address(this));
        if (wethBal > 0) {
            bool wethSuccess = weth.transfer(owner, wethBal);
            if (!wethSuccess) revert TransferFailed();
        }

        // Transfer all tokens to owner
        uint256 tokenBal = token.balanceOf(address(this));
        if (tokenBal > 0) {
            bool tokenSuccess = token.transfer(owner, tokenBal);
            if (!tokenSuccess) revert TransferFailed();
        }

        emit EmergencyWithdrawExecuted(msg.sender);
    }

    // ========== VIEW FUNCTIONS ==========

    /// @notice Total WETH assets including Moonwell lending position
    /// @return Total WETH value (vault balance + Moonwell value via exchangeRateStored)
    function totalWethAssets() public view returns (uint256) {
        return weth.balanceOf(address(this)) + _moonwellWethValue();
    }

    /// @notice Total assets summary
    function totalAssets() external view returns (uint256 wethTotal, uint256 tokenTotal) {
        wethTotal = totalWethAssets();
        tokenTotal = token.balanceOf(address(this));
    }

    /// @notice NAV per share (scaled by 1e18)
    function navPerShare() public view returns (uint256) {
        if (totalShares == 0) return 1e18;
        return (totalWethAssets() * 1e18) / totalShares;
    }

    /// @notice Value of WETH lent to Moonwell
    function moonwellWethValue() external view returns (uint256) {
        return _moonwellWethValue();
    }

    /// @notice Current lending ratio in basis points
    function currentLendingRatio() external view returns (uint256) {
        uint256 total = totalWethAssets();
        if (total == 0) return 0;
        return (_moonwellWethValue() * BPS) / total;
    }

    /// @notice Get depositor info
    function getDepositorInfo(address depositor)
        external
        view
        returns (uint256 shareBalance, uint256 wethValue, uint256 tokenValue, uint256 queued)
    {
        shareBalance = shares[depositor];
        if (totalShares > 0) {
            wethValue = (shareBalance * totalWethAssets()) / totalShares;
            tokenValue = (shareBalance * token.balanceOf(address(this))) / totalShares;
        }
        queued = queuedWithdrawals[depositor];
    }

    // ========== INTERNAL ==========

    /// @dev Calculate WETH value of Moonwell position using exchangeRateStored
    function _moonwellWethValue() internal view returns (uint256) {
        uint256 mTokenBalance = moonwellMarket.balanceOf(address(this));
        if (mTokenBalance == 0) return 0;
        uint256 exchangeRate = moonwellMarket.exchangeRateStored();
        return (mTokenBalance * exchangeRate) / 1e18;
    }

    /// @dev Collect performance fee if NAV exceeds high-water mark
    function _collectPerformanceFee() internal {
        uint256 currentNav = navPerShare();
        if (currentNav <= highWaterMark) return;

        uint256 profit = currentNav - highWaterMark;
        uint256 feePerShare = (profit * PERFORMANCE_FEE_BPS) / BPS;

        // Calculate fee in WETH terms
        uint256 feeWeth = (feePerShare * totalShares) / 1e18;
        uint256 feeToken = 0; // Fee only taken in WETH for simplicity

        if (feeWeth > 0 && feeWeth <= weth.balanceOf(address(this))) {
            weth.transfer(owner, feeWeth);
            emit PerformanceFeeCollected(feeWeth, feeToken);
        }

        // Update high-water mark
        highWaterMark = currentNav;
    }
}
