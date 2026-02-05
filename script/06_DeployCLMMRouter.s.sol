// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {BaseScript} from "./base/BaseScript.sol";
import {CLMMRouter} from "../src/CLMMRouter.sol";

contract DeployCLMMRouterScript is BaseScript {
    function run() external {
        vm.startBroadcast();

        CLMMRouter router = new CLMMRouter(poolManager, positionManager, permit2);

        vm.stopBroadcast();

        console2.log("CLMMRouter deployed at:", address(router));
        console2.log("  PoolManager:", address(poolManager));
        console2.log("  PositionManager:", address(positionManager));
        console2.log("  Permit2:", address(permit2));
    }
}
