// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {BaseScript} from "./base/BaseScript.sol";

contract QueryPoolScript is BaseScript {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for *;
    using CurrencyLibrary for Currency;

    function run() external view {
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: hookContract
        });

        PoolId poolId = poolKey.toId();
        console2.log("=== Pool Info ===");
        console2.log("Pool ID:");
        console2.logBytes32(PoolId.unwrap(poolId));

        // Slot0: price, tick, fees
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) =
            poolManager.getSlot0(poolId);

        console2.log("");
        console2.log("=== Slot0 ===");
        console2.log("sqrtPriceX96:", sqrtPriceX96);
        console2.log("tick:", tick);
        console2.log("protocolFee:", protocolFee);
        console2.log("lpFee:", lpFee);

        // Total pool liquidity (active liquidity at current tick)
        uint128 liquidity = poolManager.getLiquidity(poolId);
        console2.log("");
        console2.log("=== Pool Liquidity ===");
        console2.log("Active liquidity:", liquidity);

        // Fee growth globals
        (uint256 feeGrowthGlobal0, uint256 feeGrowthGlobal1) =
            poolManager.getFeeGrowthGlobals(poolId);
        console2.log("");
        console2.log("=== Fee Growth Global ===");
        console2.log("feeGrowthGlobal0 (USDT):", feeGrowthGlobal0);
        console2.log("feeGrowthGlobal1 (WETH):", feeGrowthGlobal1);

        // Query our position via PositionManager
        // Token ID 6598 was minted (from the deploy logs)
        uint256 tokenId = positionManager.nextTokenId() - 1;
        console2.log("");
        console2.log("=== Position (tokenId:", tokenId, ") ===");

        uint128 posLiquidity = positionManager.getPositionLiquidity(tokenId);
        console2.log("Position liquidity:", posLiquidity);

        console2.log("");
        console2.log("=== Summary ===");
        if (liquidity == 0 && feeGrowthGlobal0 == 0 && feeGrowthGlobal1 == 0) {
            console2.log("No swaps have occurred yet. Fee rewards are 0.");
            console2.log("Rewards will accumulate when users swap through this pool.");
        } else {
            console2.log("Pool is active with swap activity.");
            console2.log("Fee rewards are accruing from swaps.");
        }
    }
}
