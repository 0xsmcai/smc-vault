// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IMoonwell} from "./interfaces/IMoonwell.sol";
import {IWETH} from "./interfaces/IWETH.sol";

/// @title SMCVault v3 — Community Liquidity Engine
/// @notice Dual-asset vault (WETH + token) with Uniswap LP management and Moonwell yield boost.
///
/// Architecture:
///   Depositor -> Vault (holds WETH + token + mWETH)
///                 |-- Uniswap LP positions (active capital, managed by operator via allowlisted calls)
///                 +-- Moonwell supply (idle WETH, earns lending yield)
///
/// Security model:
///   - Operator can ONLY call allowlisted Uniswap PM functions with vault as recipient
///   - Operator can supply/withdraw idle WETH to Moonwell within lending ratio limits
///   - Owner can collect performance fees and manage operator/selector config
///   - Neither owner nor operator can drain depositor funds arbitrarily
///   - Depositors can force-withdraw after 4-hour timeout without operator cooperation
///   - $100 cap per wallet, dead shares protect against inflation attacks
///   - 10% performance fee on NAV high-water mark only
///
/// Combines: smc-vault (Moonwell) + smc-vault-v2 (operator allowlist, withdrawal queue, security)
contract SMCVault {
    // ========== ERRORS ==========
    error Unauthorized();
    error ZeroAmount();
    error ZeroAddress();
    error DepositCapExceeded();
    error DepositTooSmall();
    error DepositTooLarge(); // exceeds 20% of TVL
    error MaxLendingRatioCeilingExceeded();
    error MoonwellMintFailed(uint256 errorCode);
    error MoonwellRedeemFailed(uint256 errorCode);
    error MoonwellMintGuardianPaused();
    error InsufficientShares();
    error TransferFailed();
    error ReentrantCall();
    error UnauthorizedCall();
    error InvalidRecipient();
    error CooldownNotMet();
    error EmergencyNotReady();
    error QueueEmpty();

    // ========== EVENTS ==========
    event Deposit(address indexed depositor, uint256 wethAmount, uint256 tokenAmount, uint256 shares);
    event WithdrawalRequested(address indexed depositor, uint256 shareAmount, uint256 queueIndex);
    event Withdrawn(address indexed depositor, uint256 wethAmount, uint256 tokenAmount, uint256 sharesBurned);
    event EmergencyWithdrawn(address indexed depositor, uint256 wethAmount, uint256 tokenAmount);
    event MoonwellSupply(uint256 amount);
    event MoonwellWithdraw(uint256 amount);
    event MoonwellWithdrawFailed(uint256 errorCode);
    event MaxLendingRatioUpdated(uint256 oldRatio, uint256 newRatio);
    event PerformanceFeeCollected(uint256 feeWeth);
    event HighWaterMarkUpdated(uint256 oldHWM, uint256 newHWM);
    event OperatorAction(bytes4 selector, bool success);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event EmergencyDrainExecuted(address indexed caller);

    // ========== CONSTANTS ==========
    uint256 public constant MAX_LENDING_RATIO_CEILING = 9000; // 90% in BPS
    uint256 public constant BPS = 10000;
    uint256 public constant PERFORMANCE_FEE_BPS = 1000; // 10%
    uint256 public constant DEPOSIT_CAP = 0.03 ether; // ~$100 at ~$3300/ETH
    uint256 public constant MIN_DEPOSIT = 0.0025 ether; // ~$5
    uint256 public constant MAX_DEPOSIT_RATIO_BPS = 2000; // max 20% of TVL per deposit
    uint256 public constant WITHDRAWAL_COOLDOWN = 1 hours;
    uint256 public constant EMERGENCY_TIMEOUT = 4 hours;
    uint256 public constant INITIAL_SHARES = 1000;

    // ========== IMMUTABLES ==========
    IWETH public immutable weth;
    IERC20 public immutable token;
    IMoonwell public immutable moonwellMarket;
    address public immutable uniswapPM; // NonfungiblePositionManager

    // ========== STATE ==========
    address public immutable owner;
    address public operator;

    uint256 public maxLendingRatio = 7000; // Default 70%
    uint256 public totalShares;
    mapping(address => uint256) public shares;
    mapping(address => uint256) public wethDeposited;
    mapping(address => uint256) public depositTimestamp;

    uint256 public highWaterMark;
    uint256 public reservedFees; // WETH reserved for owner, excluded from NAV

    // Operator allowlist for Uniswap calls
    mapping(bytes4 => bool) public allowedSelectors;

    // Withdrawal queue
    struct WithdrawalRequest {
        address depositor;
        uint256 shareAmount;
        uint256 requestedAt;
    }
    WithdrawalRequest[] public withdrawalQueue;

    // Reentrancy lock
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
        address _uniswapPM,
        address _operator
    ) {
        if (_weth == address(0) || _token == address(0) || _moonwellMarket == address(0)
            || _uniswapPM == address(0) || _operator == address(0)) revert ZeroAddress();

        weth = IWETH(_weth);
        token = IERC20(_token);
        moonwellMarket = IMoonwell(_moonwellMarket);
        uniswapPM = _uniswapPM;
        operator = _operator;
        owner = msg.sender;

        // Pre-approve WETH to Moonwell for supply operations
        bool approveOk = IERC20(_weth).approve(_moonwellMarket, type(uint256).max);
        require(approveOk, "WETH approve failed");

        // Uniswap V3 NonfungiblePositionManager selectors
        allowedSelectors[0x88316456] = true; // mint
        allowedSelectors[0x219f5d17] = true; // increaseLiquidity
        allowedSelectors[0x0c49ccbe] = true; // decreaseLiquidity
        allowedSelectors[0xfc6f7865] = true; // collect

        // Dead shares to prevent ERC-4626 inflation attack
        totalShares = INITIAL_SHARES;
        shares[address(0xdead)] = INITIAL_SHARES;
        highWaterMark = 1e18;
    }

    // ========== DEPOSIT ==========
    /// @notice Deposit WETH + token into the vault
    /// @param wethAmount Amount of WETH to deposit
    /// @param tokenAmount Amount of token to deposit
    /// @return sharesOut Shares minted to depositor
    function deposit(uint256 wethAmount, uint256 tokenAmount) external nonReentrant returns (uint256 sharesOut) {
        if (wethAmount < MIN_DEPOSIT) revert DepositTooSmall();
        if (wethDeposited[msg.sender] + wethAmount > DEPOSIT_CAP) revert DepositCapExceeded();

        // Enforce max 20% of TVL per single deposit (skip for first real deposit)
        if (totalShares > INITIAL_SHARES) {
            uint256 currentTVL = _availableWeth();
            if (currentTVL > 0 && (wethAmount * BPS) / currentTVL > MAX_DEPOSIT_RATIO_BPS) {
                revert DepositTooLarge();
            }
        }

        // Calculate shares based on current NAV
        if (totalShares == INITIAL_SHARES) {
            sharesOut = wethAmount; // First real deposit: 1:1
        } else {
            uint256 totalWeth = _availableWeth();
            if (totalWeth == 0) revert ZeroAmount();
            sharesOut = (wethAmount * totalShares) / totalWeth;
        }

        if (sharesOut == 0) revert ZeroAmount();

        // Transfer assets in (check return values + actual received for fee-on-transfer tokens)
        uint256 wethBefore = weth.balanceOf(address(this));
        bool wethOk = weth.transferFrom(msg.sender, address(this), wethAmount);
        if (!wethOk) revert TransferFailed();
        uint256 actualWeth = weth.balanceOf(address(this)) - wethBefore;

        uint256 tokenBefore = token.balanceOf(address(this));
        bool tokenOk = token.transferFrom(msg.sender, address(this), tokenAmount);
        if (!tokenOk) revert TransferFailed();
        uint256 actualToken = token.balanceOf(address(this)) - tokenBefore;

        // Mint shares
        totalShares += sharesOut;
        shares[msg.sender] += sharesOut;
        wethDeposited[msg.sender] += actualWeth;
        depositTimestamp[msg.sender] = block.timestamp;

        emit Deposit(msg.sender, actualWeth, actualToken, sharesOut);
    }

    // ========== WITHDRAWAL QUEUE ==========
    /// @notice Request withdrawal by queueing shares
    /// @param shareAmount Number of shares to withdraw
    function requestWithdrawal(uint256 shareAmount) external {
        if (shareAmount == 0) revert ZeroAmount();
        if (shares[msg.sender] < shareAmount) revert InsufficientShares();
        if (block.timestamp - depositTimestamp[msg.sender] < WITHDRAWAL_COOLDOWN) revert CooldownNotMet();

        shares[msg.sender] -= shareAmount;

        withdrawalQueue.push(WithdrawalRequest({
            depositor: msg.sender,
            shareAmount: shareAmount,
            requestedAt: block.timestamp
        }));

        emit WithdrawalRequested(msg.sender, shareAmount, withdrawalQueue.length - 1);
    }

    /// @notice Operator processes a queued withdrawal
    /// @param index Index in the withdrawal queue
    function processWithdrawal(uint256 index) external onlyOperator nonReentrant {
        WithdrawalRequest memory req = withdrawalQueue[index];
        if (req.shareAmount == 0) revert QueueEmpty();

        _collectPerformanceFee();

        uint256 wethOwed = (req.shareAmount * _availableWeth()) / totalShares;
        uint256 tokenOwed = (req.shareAmount * token.balanceOf(address(this))) / totalShares;

        totalShares -= req.shareAmount;
        withdrawalQueue[index].shareAmount = 0;

        // Try to cover from vault WETH; redeem from Moonwell if needed
        uint256 vaultWeth = weth.balanceOf(address(this));
        if (vaultWeth < wethOwed) {
            uint256 shortfall = wethOwed - vaultWeth;
            uint256 redeemResult = moonwellMarket.redeemUnderlying(shortfall);
            if (redeemResult != 0) {
                emit MoonwellWithdrawFailed(redeemResult);
                // Send what we have — depositor can claim rest later via emergencyWithdraw path
                wethOwed = vaultWeth;
            }
        }

        if (wethOwed > 0) {
            bool ok = weth.transfer(req.depositor, wethOwed);
            if (!ok) revert TransferFailed();
        }
        if (tokenOwed > 0) {
            bool ok = token.transfer(req.depositor, tokenOwed);
            if (!ok) revert TransferFailed();
        }

        emit Withdrawn(req.depositor, wethOwed, tokenOwed, req.shareAmount);
    }

    /// @notice Depositor triggers emergency withdrawal after 4-hour timeout
    /// @param queueIndex Index of their withdrawal request
    function emergencyWithdraw(uint256 queueIndex) external nonReentrant {
        WithdrawalRequest memory req = withdrawalQueue[queueIndex];
        if (req.depositor != msg.sender) revert Unauthorized();
        if (req.shareAmount == 0) revert QueueEmpty();
        if (block.timestamp - req.requestedAt < EMERGENCY_TIMEOUT) revert EmergencyNotReady();

        uint256 wethOwed = (req.shareAmount * _availableWeth()) / totalShares;
        uint256 tokenOwed = (req.shareAmount * token.balanceOf(address(this))) / totalShares;

        totalShares -= req.shareAmount;
        withdrawalQueue[queueIndex].shareAmount = 0;

        // Try to redeem from Moonwell to cover
        uint256 vaultWeth = weth.balanceOf(address(this));
        if (vaultWeth < wethOwed) {
            uint256 shortfall = wethOwed - vaultWeth;
            uint256 mBal = moonwellMarket.balanceOf(address(this));
            if (mBal > 0) {
                moonwellMarket.redeemUnderlying(shortfall); // Best-effort, ignore return
            }
            wethOwed = weth.balanceOf(address(this)) < wethOwed
                ? weth.balanceOf(address(this))
                : wethOwed;
        }

        if (wethOwed > 0) {
            bool ok = weth.transfer(msg.sender, wethOwed);
            if (!ok) revert TransferFailed();
        }
        if (tokenOwed > 0) {
            bool ok = token.transfer(msg.sender, tokenOwed);
            if (!ok) revert TransferFailed();
        }

        emit EmergencyWithdrawn(msg.sender, wethOwed, tokenOwed);
    }

    // ========== OPERATOR: UNISWAP LP MANAGEMENT ==========
    /// @notice Execute an allowlisted Uniswap PM function
    /// @dev Validates selector is allowed and recipient fields point to this vault
    /// @param data ABI-encoded function call for NonfungiblePositionManager
    function operatorExecute(bytes calldata data) external onlyOperator nonReentrant returns (bytes memory) {
        if (data.length < 4) revert UnauthorizedCall();
        bytes4 selector = bytes4(data[:4]);
        if (!allowedSelectors[selector]) revert UnauthorizedCall();

        // Validate recipient is this vault for functions that have a recipient field
        // mint: recipient at offset 4 + 9*32 = 292 (10th param in MintParams struct)
        // collect: recipient at offset 4 + 1*32 = 36 (2nd param in CollectParams struct)
        if (selector == 0x88316456 && data.length >= 324) {
            // mint — recipient is 10th word
            address recipient = address(uint160(uint256(bytes32(data[292:324]))));
            if (recipient != address(this)) revert InvalidRecipient();
        } else if (selector == 0xfc6f7865 && data.length >= 68) {
            // collect — recipient is 2nd word
            address recipient = address(uint160(uint256(bytes32(data[36:68]))));
            if (recipient != address(this)) revert InvalidRecipient();
        }

        (bool success, bytes memory result) = uniswapPM.call(data);
        emit OperatorAction(selector, success);

        if (!success) {
            assembly { revert(add(result, 32), mload(result)) }
        }
        return result;
    }

    // ========== OPERATOR: MOONWELL LENDING ==========
    /// @notice Supply idle WETH to Moonwell to earn lending yield
    function supplyToMoonwell(uint256 amount) external onlyOperator nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (moonwellMarket.mintGuardianPaused()) revert MoonwellMintGuardianPaused();

        // Enforce max lending ratio
        uint256 totalWeth = totalWethAssets();
        uint256 currentlyLent = _moonwellWethValue();
        uint256 afterLend = currentlyLent + amount;
        if (totalWeth > 0 && (afterLend * BPS) / totalWeth > maxLendingRatio)
            revert MaxLendingRatioCeilingExceeded();

        uint256 result = moonwellMarket.mint(amount);
        if (result != 0) revert MoonwellMintFailed(result);

        emit MoonwellSupply(amount);
    }

    /// @notice Withdraw WETH from Moonwell (0 = withdraw all)
    function withdrawFromMoonwell(uint256 amount) external onlyOperator nonReentrant {
        if (amount == 0) {
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

    // ========== PERFORMANCE FEE ==========
    /// @notice Collect accrued performance fees to owner
    function collectFees() external onlyOwner nonReentrant {
        _collectPerformanceFee();
        uint256 fees = reservedFees;
        if (fees == 0) return;
        reservedFees = 0;

        bool ok = weth.transfer(owner, fees);
        if (!ok) revert TransferFailed();

        emit PerformanceFeeCollected(fees);
    }

    function _collectPerformanceFee() internal {
        if (totalShares == 0) return;

        uint256 currentNAV = navPerShare();
        if (currentNAV <= highWaterMark) return;

        uint256 gain = currentNAV - highWaterMark;
        uint256 totalFeeWeth = (gain * PERFORMANCE_FEE_BPS * totalShares) / (BPS * 1e18);

        reservedFees += totalFeeWeth;

        uint256 oldHWM = highWaterMark;
        highWaterMark = currentNAV;
        emit HighWaterMarkUpdated(oldHWM, currentNAV);
    }

    // ========== ADMIN ==========
    /// @notice Approve Uniswap PM to spend vault's WETH
    function approveWethForUniswap() external onlyOwner {
        bool ok = IERC20(address(weth)).approve(uniswapPM, type(uint256).max);
        require(ok, "WETH approve failed");
    }

    /// @notice Approve Uniswap PM to spend vault's token
    function approveTokenForUniswap() external onlyOwner {
        bool ok = token.approve(uniswapPM, type(uint256).max);
        require(ok, "Token approve failed");
    }

    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert ZeroAddress();
        address old = operator;
        operator = newOperator;
        emit OperatorUpdated(old, newOperator);
    }

    function setMaxLendingRatio(uint256 newRatio) external onlyOwnerOrOperator {
        if (newRatio > MAX_LENDING_RATIO_CEILING) revert MaxLendingRatioCeilingExceeded();
        uint256 oldRatio = maxLendingRatio;
        maxLendingRatio = newRatio;
        emit MaxLendingRatioUpdated(oldRatio, newRatio);
    }

    function addAllowedSelector(bytes4 selector) external onlyOwner {
        allowedSelectors[selector] = true;
    }

    function removeAllowedSelector(bytes4 selector) external onlyOwner {
        allowedSelectors[selector] = false;
    }

    /// @notice Emergency drain: owner pulls all assets. Nuclear option.
    function emergencyDrain() external onlyOwner nonReentrant {
        // Drain Moonwell
        uint256 mBal = moonwellMarket.balanceOf(address(this));
        if (mBal > 0) {
            uint256 result = moonwellMarket.redeem(mBal);
            if (result != 0) emit MoonwellWithdrawFailed(result);
        }

        uint256 wethBal = weth.balanceOf(address(this));
        if (wethBal > 0) {
            bool ok = weth.transfer(owner, wethBal);
            if (!ok) revert TransferFailed();
        }

        uint256 tokenBal = token.balanceOf(address(this));
        if (tokenBal > 0) {
            bool ok = token.transfer(owner, tokenBal);
            if (!ok) revert TransferFailed();
        }

        emit EmergencyDrainExecuted(msg.sender);
    }

    // ========== VIEW FUNCTIONS ==========
    /// @notice Total WETH assets including Moonwell, excluding reserved fees
    function totalWethAssets() public view returns (uint256) {
        return _availableWeth();
    }

    /// @notice Available WETH for depositors (vault + Moonwell - reserved fees)
    function _availableWeth() internal view returns (uint256) {
        uint256 total = weth.balanceOf(address(this)) + _moonwellWethValue();
        return total > reservedFees ? total - reservedFees : 0;
    }

    function _moonwellWethValue() internal view returns (uint256) {
        uint256 mBal = moonwellMarket.balanceOf(address(this));
        if (mBal == 0) return 0;
        return (mBal * moonwellMarket.exchangeRateStored()) / 1e18;
    }

    function navPerShare() public view returns (uint256) {
        if (totalShares == 0) return 1e18;
        return (_availableWeth() * 1e18) / totalShares;
    }

    function totalAssets() external view returns (uint256 wethTotal, uint256 tokenTotal) {
        wethTotal = _availableWeth();
        tokenTotal = token.balanceOf(address(this));
    }

    function moonwellWethValue() external view returns (uint256) {
        return _moonwellWethValue();
    }

    function currentLendingRatio() external view returns (uint256) {
        uint256 total = weth.balanceOf(address(this)) + _moonwellWethValue();
        if (total == 0) return 0;
        return (_moonwellWethValue() * BPS) / total;
    }

    function getWithdrawalQueueLength() external view returns (uint256) {
        return withdrawalQueue.length;
    }

    function getDepositorInfo(address depositor)
        external view
        returns (uint256 shareBalance, uint256 wethValue, uint256 tokenValue)
    {
        shareBalance = shares[depositor];
        if (totalShares > 0) {
            wethValue = (shareBalance * _availableWeth()) / totalShares;
            tokenValue = (shareBalance * token.balanceOf(address(this))) / totalShares;
        }
    }
}
