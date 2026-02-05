// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";

import {CLMMRouter} from "../src/CLMMRouter.sol";

contract CLMMRouterTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    CLMMRouter router;

    Currency currency0;
    Currency currency1;

    MockERC20 token0;
    MockERC20 token1;

    CLMMRouter.PoolParams poolParams;
    PoolKey poolKey;
    PoolId poolId;

    uint160 constant SQRT_PRICE_1_1 = Constants.SQRT_PRICE_1_1;

    function setUp() public {
        // Warp to a realistic timestamp so Permit2 expiry works
        vm.warp(1700000000);

        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        // Deploy CLMMRouter
        router = new CLMMRouter(poolManager, positionManager, permit2);
        vm.label(address(router), "CLMMRouter");

        // Setup pool params
        poolParams = CLMMRouter.PoolParams({
            token0: address(token0),
            token1: address(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        poolId = poolKey.toId();

        // Approve tokens: this -> Permit2 -> PositionManager (for EasyPosm direct calls)
        token0.approve(address(permit2), type(uint256).max);
        token1.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token0), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(positionManager), type(uint160).max, type(uint48).max);

        // Approve tokens: this -> CLMMRouter
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);

        // The CLMMRouter calls positionManager.modifyLiquidities, which pulls tokens
        // from msg.sender (CLMMRouter) via Permit2. So CLMMRouter needs:
        // 1. token approval to Permit2
        // 2. Permit2 allowance to PositionManager
        // These are set up by calling router.approveToken() — but approveToken
        // approves from msg.sender (this test contract), not the router itself.
        //
        // Actually the PositionManager pulls tokens from the CALLER of modifyLiquidities
        // which is the CLMMRouter. So the CLMMRouter needs its own Permit2 allowance.
        // We need to give CLMMRouter some tokens and have it approve.

        // Transfer tokens to router and have it approve Permit2
        token0.transfer(address(router), 5_000_000 ether);
        token1.transfer(address(router), 5_000_000 ether);

        // Call approveToken on the router (this sets up router's Permit2 approvals)
        router.approveToken(address(token0));
        router.approveToken(address(token1));

        // Approve CLMMRouter as operator for position NFTs
        // (needed for decreaseLiquidity and closePosition where CLMMRouter modifies positions owned by this)
        IERC721(address(positionManager)).setApprovalForAll(address(router), true);
    }

    // ═══════════════════════════════════════════════
    //  PURE HELPERS
    // ═══════════════════════════════════════════════

    function test_sqrtPriceToTick() public view {
        int24 tick = router.sqrtPriceToTick(SQRT_PRICE_1_1, 60);
        // SQRT_PRICE_1_1 corresponds to tick 0
        assertEq(tick, 0);
    }

    function test_sqrtPriceToTick_roundsDown() public view {
        // Get sqrtPrice at tick 65 (not a multiple of 60)
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(65);
        int24 tick = router.sqrtPriceToTick(sqrtPrice, 60);
        // Should round down to 60
        assertEq(tick, 60);
    }

    function test_tickToSqrtPrice() public view {
        uint160 sqrtPrice = router.tickToSqrtPrice(0);
        assertEq(sqrtPrice, SQRT_PRICE_1_1);
    }

    function test_getTickBounds() public view {
        (int24 minTick, int24 maxTick) = router.getTickBounds(60);
        assertEq(minTick, TickMath.minUsableTick(60));
        assertEq(maxTick, TickMath.maxUsableTick(60));
        assertTrue(minTick < 0);
        assertTrue(maxTick > 0);
    }

    // ═══════════════════════════════════════════════
    //  CREATE POOL
    // ═══════════════════════════════════════════════

    function test_createPool() public {
        int24 tick = router.createPool(poolParams, SQRT_PRICE_1_1);
        assertEq(tick, 0);

        // Verify pool is initialized
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1);
    }

    // ═══════════════════════════════════════════════
    //  GET POOL STATE
    // ═══════════════════════════════════════════════

    function test_getPoolState() public {
        // Initialize pool first
        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        CLMMRouter.PoolState memory state = router.getPoolState(poolParams);

        assertEq(PoolId.unwrap(state.poolId), PoolId.unwrap(poolId));
        assertEq(state.sqrtPriceX96, SQRT_PRICE_1_1);
        assertEq(state.tick, 0);
        assertEq(state.lpFee, 3000);
        assertEq(state.liquidity, 0); // no liquidity added yet
    }

    function test_getPoolState_withLiquidity() public {
        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        // Add liquidity via EasyPosm
        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint128 liquidityAmount = 100e18;

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        positionManager.mint(
            poolKey, tickLower, tickUpper, liquidityAmount,
            amount0 + 1, amount1 + 1, address(this), block.timestamp, ""
        );

        CLMMRouter.PoolState memory state = router.getPoolState(poolParams);
        assertEq(state.liquidity, liquidityAmount);
    }

    // ═══════════════════════════════════════════════
    //  MINT POSITION
    // ═══════════════════════════════════════════════

    function test_mintPosition() public {
        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint128 liquidity = 100e18;

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );

        uint256 routerBalance0Before = token0.balanceOf(address(router));
        uint256 routerBalance1Before = token1.balanceOf(address(router));

        router.mintPosition(
            poolParams,
            tickLower,
            tickUpper,
            liquidity,
            amount0 + 1e18, // generous slippage
            amount1 + 1e18,
            address(this),
            block.timestamp + 1
        );

        // Verify tokens were spent from CLMMRouter (Permit2 pulls from msg.sender of modifyLiquidities)
        assertTrue(token0.balanceOf(address(router)) < routerBalance0Before);
        assertTrue(token1.balanceOf(address(router)) < routerBalance1Before);

        // Verify pool has liquidity
        uint128 poolLiquidity = poolManager.getLiquidity(poolId);
        assertEq(poolLiquidity, liquidity);
    }

    function test_mintPosition_narrowRange() public {
        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        // Narrow CLMM range: tick 0 ± 60 (very concentrated)
        int24 tickLower = -60;
        int24 tickUpper = 60;
        uint128 liquidity = 50e18;

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );

        router.mintPosition(
            poolParams,
            tickLower,
            tickUpper,
            liquidity,
            amount0 + 1e18,
            amount1 + 1e18,
            address(this),
            block.timestamp + 1
        );

        uint128 poolLiquidity = poolManager.getLiquidity(poolId);
        assertEq(poolLiquidity, liquidity);
    }

    // ═══════════════════════════════════════════════
    //  INCREASE LIQUIDITY
    // ═══════════════════════════════════════════════

    function test_increaseLiquidity() public {
        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint128 liquidity = 50e18;

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );

        // Mint initial position
        uint256 tokenId = positionManager.nextTokenId();
        router.mintPosition(
            poolParams,
            tickLower,
            tickUpper,
            liquidity,
            amount0 + 1e18,
            amount1 + 1e18,
            address(this),
            block.timestamp + 1
        );

        // Increase liquidity
        uint128 additionalLiquidity = 25e18;
        (uint256 add0, uint256 add1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            additionalLiquidity
        );

        router.increaseLiquidity(
            tokenId,
            additionalLiquidity,
            add0 + 1e18,
            add1 + 1e18,
            block.timestamp + 1
        );

        // Verify total liquidity
        uint128 poolLiquidity = poolManager.getLiquidity(poolId);
        assertEq(poolLiquidity, liquidity + additionalLiquidity);
    }

    // ═══════════════════════════════════════════════
    //  DECREASE LIQUIDITY
    // ═══════════════════════════════════════════════

    function test_decreaseLiquidity() public {
        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint128 liquidity = 100e18;

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );

        uint256 tokenId = positionManager.nextTokenId();
        router.mintPosition(
            poolParams, tickLower, tickUpper, liquidity,
            amount0 + 1e18, amount1 + 1e18, address(this), block.timestamp + 1
        );

        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));

        // Remove half
        uint128 removeAmount = 50e18;
        router.decreaseLiquidity(
            tokenId, removeAmount, 0, 0, address(this), block.timestamp + 1
        );

        // Verify tokens returned
        assertTrue(token0.balanceOf(address(this)) > balance0Before);
        assertTrue(token1.balanceOf(address(this)) > balance1Before);

        // Verify remaining liquidity
        uint128 poolLiquidity = poolManager.getLiquidity(poolId);
        assertEq(poolLiquidity, liquidity - removeAmount);
    }

    // ═══════════════════════════════════════════════
    //  CLOSE POSITION
    // ═══════════════════════════════════════════════

    function test_closePosition() public {
        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint128 liquidity = 100e18;

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );

        uint256 tokenId = positionManager.nextTokenId();
        router.mintPosition(
            poolParams, tickLower, tickUpper, liquidity,
            amount0 + 1e18, amount1 + 1e18, address(this), block.timestamp + 1
        );

        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));

        // Close position (withdraw all + burn NFT)
        // setApprovalForAll in setUp covers NFT approval
        router.closePosition(tokenId, 0, 0, address(this), block.timestamp + 1);

        // Verify tokens returned to recipient (address(this))
        assertTrue(token0.balanceOf(address(this)) > balance0Before);
        assertTrue(token1.balanceOf(address(this)) > balance1Before);

        // Verify pool liquidity is 0
        uint128 poolLiquidity = poolManager.getLiquidity(poolId);
        assertEq(poolLiquidity, 0);
    }

    // ═══════════════════════════════════════════════
    //  GET POSITION
    // ═══════════════════════════════════════════════

    function test_getPosition() public {
        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint128 liquidity = 100e18;

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );

        uint256 tokenId = positionManager.nextTokenId();
        router.mintPosition(
            poolParams, tickLower, tickUpper, liquidity,
            amount0 + 1e18, amount1 + 1e18, address(this), block.timestamp + 1
        );

        CLMMRouter.PositionInfo memory info = router.getPosition(tokenId);

        assertEq(info.tokenId, tokenId);
        assertEq(info.liquidity, liquidity);
        assertEq(info.sqrtPriceX96, SQRT_PRICE_1_1);
        assertEq(info.currentTick, 0);
    }

    // ═══════════════════════════════════════════════
    //  GET USER POSITIONS
    // ═══════════════════════════════════════════════

    function test_getUserPositions() public {
        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        int24 tickLower = -600;
        int24 tickUpper = 600;
        uint128 liquidity = 10e18;

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );

        // Mint 3 positions
        for (uint256 i = 0; i < 3; i++) {
            router.mintPosition(
                poolParams,
                tickLower - int24(int256(i)) * 120, // different ranges
                tickUpper + int24(int256(i)) * 120,
                liquidity,
                amount0 + 1e18,
                amount1 + 1e18,
                address(this),
                block.timestamp + 1
            );
        }

        (uint256[] memory tokenIds, uint256 count) = router.getUserPositions(address(this), 1, 100);

        assertEq(count, 3);
        assertEq(tokenIds.length, 3);
    }

    function test_getUserPositions_noPositions() public view {
        (uint256[] memory tokenIds, uint256 count) = router.getUserPositions(address(0xdead), 1, 100);

        assertEq(count, 0);
        assertEq(tokenIds.length, 0);
    }

    // ═══════════════════════════════════════════════
    //  FULL FLOW: mint -> swap -> fees -> decrease -> close
    // ═══════════════════════════════════════════════

    function test_fullFlow() public {
        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        // 1. Mint position
        int24 tickLower = -6000;
        int24 tickUpper = 6000;
        uint128 liquidity = 1000e18;

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );

        uint256 tokenId = positionManager.nextTokenId();
        router.mintPosition(
            poolParams, tickLower, tickUpper, liquidity,
            amount0 + 10e18, amount1 + 10e18, address(this), block.timestamp + 1
        );

        // Verify position
        CLMMRouter.PositionInfo memory info = router.getPosition(tokenId);
        assertEq(info.liquidity, liquidity);

        // 2. Perform swap to generate fees
        token0.approve(address(swapRouter), type(uint256).max);
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: "",
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // 3. Check fee growth
        CLMMRouter.PoolState memory state = router.getPoolState(poolParams);
        assertTrue(state.feeGrowthGlobal0 > 0, "Should have fee growth after swap");

        // 4. Decrease half liquidity
        router.decreaseLiquidity(
            tokenId, uint128(liquidity / 2), 0, 0, address(this), block.timestamp + 1
        );

        uint128 remaining = poolManager.getLiquidity(poolId);
        assertEq(remaining, liquidity / 2);

        // 5. Close position (setApprovalForAll in setUp covers NFT approval)
        router.closePosition(tokenId, 0, 0, address(this), block.timestamp + 1);

        uint128 finalLiquidity = poolManager.getLiquidity(poolId);
        assertEq(finalLiquidity, 0);
    }
}
