// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {SMCVault} from "../src/SMCVault.sol";
import {MerkleClaim} from "../src/MerkleClaim.sol";

/// @title Deploy SMCVault + MerkleClaim on Base (Sepolia or Mainnet)
/// @dev Usage:
///   TESTNET=true TOKEN_ADDRESS=0x... OPERATOR_ADDRESS=0x... forge script script/Deploy.s.sol --rpc-url $RPC --broadcast
contract DeployScript is Script {
    // Base mainnet addresses
    address constant WETH_MAINNET = 0x4200000000000000000000000000000000000006;
    address constant MOONWELL_MWETH_MAINNET = 0x628ff693426583D9a7FB391E54366292F509D457;
    address constant UNISWAP_PM_MAINNET = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;

    // Base Sepolia addresses
    address constant WETH_SEPOLIA = 0x4200000000000000000000000000000000000006;
    address constant MOONWELL_MWETH_SEPOLIA = address(0); // No Moonwell on Sepolia — use mock
    address constant UNISWAP_PM_SEPOLIA = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;

    function run() external {
        address tokenAddr = vm.envAddress("TOKEN_ADDRESS");
        address operatorAddr = vm.envAddress("OPERATOR_ADDRESS");
        bool isTestnet = vm.envOr("TESTNET", false);

        address wethAddr = isTestnet ? WETH_SEPOLIA : WETH_MAINNET;
        address moonwellAddr = isTestnet ? MOONWELL_MWETH_SEPOLIA : MOONWELL_MWETH_MAINNET;
        address uniswapPMAddr = isTestnet ? UNISWAP_PM_SEPOLIA : UNISWAP_PM_MAINNET;

        require(moonwellAddr != address(0) || isTestnet, "Moonwell address required for mainnet");

        vm.startBroadcast();

        // Deploy vault
        SMCVault vault = new SMCVault(
            wethAddr,
            tokenAddr,
            moonwellAddr,
            uniswapPMAddr,
            operatorAddr
        );

        // Approve Uniswap PM to spend vault's WETH and token
        vault.approveWethForUniswap();
        vault.approveTokenForUniswap();

        // Deploy Merkle claim
        MerkleClaim merkleClaim = new MerkleClaim(tokenAddr);

        vm.stopBroadcast();

        console.log("=== Deployment Summary ===");
        console.log("Network:", isTestnet ? "Base Sepolia" : "Base Mainnet");
        console.log("SMCVault:", address(vault));
        console.log("MerkleClaim:", address(merkleClaim));
        console.log("Token:", tokenAddr);
        console.log("WETH:", wethAddr);
        console.log("Moonwell:", moonwellAddr);
        console.log("UniswapPM:", uniswapPMAddr);
        console.log("Operator:", operatorAddr);
    }
}
