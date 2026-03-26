// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {SMCVault} from "../src/SMCVault.sol";
import {MerkleClaim} from "../src/MerkleClaim.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @title Mock WETH for testnet (simplified)
contract MockWETH {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
    }
    function withdraw(uint256 amt) external {
        balanceOf[msg.sender] -= amt;
        totalSupply -= amt;
        (bool ok,) = msg.sender.call{value: amt}("");
        require(ok);
    }
    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }
    receive() external payable { balanceOf[msg.sender] += msg.value; totalSupply += msg.value; }
}

/// @title Mock Token for testnet
contract MockToken {
    string public name = "SMC Factory Token";
    string public symbol = "SMCF";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(uint256 initialSupply) {
        balanceOf[msg.sender] = initialSupply;
        totalSupply = initialSupply;
    }
    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }
}

/// @title Mock Moonwell for testnet (simplified cToken)
contract MockMoonwellTestnet {
    IERC20 public underlying;
    mapping(address => uint256) public balanceOf;
    uint256 public exchangeRateStored = 1e18;
    bool public mintGuardianPaused;

    constructor(address _underlying) { underlying = IERC20(_underlying); }

    function mint(uint256 amt) external returns (uint256) {
        if (mintGuardianPaused) return 1;
        underlying.transferFrom(msg.sender, address(this), amt);
        uint256 mTokens = (amt * 1e18) / exchangeRateStored;
        balanceOf[msg.sender] += mTokens;
        return 0;
    }
    function redeem(uint256 redeemTokens) external returns (uint256) {
        uint256 underlyingAmt = (redeemTokens * exchangeRateStored) / 1e18;
        balanceOf[msg.sender] -= redeemTokens;
        underlying.transfer(msg.sender, underlyingAmt);
        return 0;
    }
    function redeemUnderlying(uint256 redeemAmt) external returns (uint256) {
        uint256 mTokens = (redeemAmt * 1e18) / exchangeRateStored;
        if (mTokens > balanceOf[msg.sender]) return 1;
        balanceOf[msg.sender] -= mTokens;
        underlying.transfer(msg.sender, redeemAmt);
        return 0;
    }
    function balanceOfUnderlying(address owner) external view returns (uint256) {
        return (balanceOf[owner] * exchangeRateStored) / 1e18;
    }
}

/// @title Deploy everything to Base Sepolia for testing
contract DeployTestnetScript is Script {
    address constant UNISWAP_PM = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;

    function run() external {
        address operatorAddr = vm.envAddress("OPERATOR_ADDRESS");

        vm.startBroadcast();

        // Deploy mock WETH
        MockWETH weth = new MockWETH();

        // Deploy mock token (1B supply)
        MockToken token = new MockToken(1_000_000_000e18);

        // Deploy mock Moonwell
        MockMoonwellTestnet moonwell = new MockMoonwellTestnet(address(weth));

        // Deploy vault
        SMCVault vault = new SMCVault(
            address(weth),
            address(token),
            address(moonwell),
            UNISWAP_PM,
            operatorAddr
        );

        // Approve Uniswap PM
        vault.approveWethForUniswap();
        vault.approveTokenForUniswap();

        // Deploy Merkle claim
        MerkleClaim claim = new MerkleClaim(address(token));

        vm.stopBroadcast();

        console.log("=== Base Sepolia Deployment ===");
        console.log("MockWETH:", address(weth));
        console.log("MockToken:", address(token));
        console.log("MockMoonwell:", address(moonwell));
        console.log("SMCVault:", address(vault));
        console.log("MerkleClaim:", address(claim));
        console.log("Operator:", operatorAddr);
        console.log("UniswapPM:", UNISWAP_PM);
    }
}
