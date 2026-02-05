// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockERC20} from "../src/MockERC20.sol";

/// @notice Deploys MockERC20 tokens: mock WETH and USDT
contract DeployTokensScript is Script {
    function run() external {
        vm.startBroadcast();

        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        MockERC20 usdt = new MockERC20("Tether USD", "USDT", 6);

        // Mint initial supply to deployer
        address deployer = msg.sender;
        weth.mint(deployer, 1_000_000 ether); // 1M WETH
        usdt.mint(deployer, 1_000_000e6); // 1M USDT

        vm.stopBroadcast();

        console2.log("WETH deployed at:", address(weth));
        console2.log("USDT deployed at:", address(usdt));
        console2.log("Minted 1,000,000 WETH to:", deployer);
        console2.log("Minted 1,000,000 USDT to:", deployer);
    }
}
