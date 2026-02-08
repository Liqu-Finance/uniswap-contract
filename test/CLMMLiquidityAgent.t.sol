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

import {BaseTest} from "./utils/BaseTest.sol";

import {CLMMRouter} from "../src/CLMMRouter.sol";
import {CLMMLiquidityAgent} from "../src/CLMMLiquidityAgent.sol";
import {IdentityRegistry} from "../src/IdentityRegistry.sol";
import {ReputationRegistry} from "../src/ReputationRegistry.sol";

contract CLMMLiquidityAgentTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    CLMMRouter router;
    CLMMLiquidityAgent agent;
    IdentityRegistry identityRegistry;
    ReputationRegistry reputationRegistry;

    Currency currency0;
    Currency currency1;
    MockERC20 token0;
    MockERC20 token1;

    PoolKey poolKey;
    PoolId poolId;

    uint160 constant SQRT_PRICE_1_1 = Constants.SQRT_PRICE_1_1;

    // Actors
    address user = address(0xBEEF);
    address agentWallet = address(0xA6E47);
    address otherUser = address(0xCAFE);
    address unregisteredAgent = address(0xDEAD);

    function setUp() public {
        vm.warp(1700000000);

        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        // Deploy CLMMRouter
        router = new CLMMRouter(poolManager, positionManager, permit2);
        vm.label(address(router), "CLMMRouter");

        // Deploy ERC-8004 registries
        identityRegistry = new IdentityRegistry();
        reputationRegistry = new ReputationRegistry(address(identityRegistry));
        vm.label(address(identityRegistry), "IdentityRegistry");
        vm.label(address(reputationRegistry), "ReputationRegistry");

        // Register agent in IdentityRegistry
        identityRegistry.newAgent("agent.liqu.finance", agentWallet);

        // Deploy CLMMLiquidityAgent
        agent = new CLMMLiquidityAgent(
            address(router),
            address(positionManager),
            address(permit2),
            address(identityRegistry),
            address(reputationRegistry),
            CLMMLiquidityAgent.PoolInfo({
                token0: address(token0),
                token1: address(token1),
                fee: 3000,
                tickSpacing: 60,
                hooks: address(0)
            })
        );
        vm.label(address(agent), "CLMMLiquidityAgent");

        // Setup router approvals (Permit2 flow for CLMMRouter)
        agent.setupRouterApprovals();

        // Transfer tokens to CLMMRouter for Permit2 flow
        // (CLMMRouter needs its own balance because Permit2 pulls from the modifyLiquidities caller)
        token0.transfer(address(router), 5_000_000 ether);
        token1.transfer(address(router), 5_000_000 ether);

        // Setup pool
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        poolId = poolKey.toId();

        // Initialize pool
        poolManager.initialize(poolKey, SQRT_PRICE_1_1);

        // Authorize the agent
        agent.authorizeAgent(agentWallet, CLMMLiquidityAgent.AgentStrategy.CONSERVATIVE);

        // Give tokens to user
        token0.transfer(user, 1_000_000 ether);
        token1.transfer(user, 1_000_000 ether);

        // Give tokens to otherUser
        token0.transfer(otherUser, 1_000_000 ether);
        token1.transfer(otherUser, 1_000_000 ether);
    }

    // ═══════════════════════════════════════════════
    //  HELPER
    // ═══════════════════════════════════════════════

    function _depositAsUser(
        uint256 amount0,
        uint256 amount1,
        CLMMLiquidityAgent.AgentStrategy strategy,
        uint256 lockPeriod
    ) internal returns (uint256 depositId) {
        vm.startPrank(user);
        token0.approve(address(agent), amount0);
        token1.approve(address(agent), amount1);
        depositId = agent.deposit(amount0, amount1, strategy, lockPeriod);
        vm.stopPrank();
    }

    function _depositAndAssignAgent() internal returns (uint256 depositId) {
        depositId = _depositAsUser(100 ether, 100 ether, CLMMLiquidityAgent.AgentStrategy.CONSERVATIVE, 7 days);
        vm.prank(user);
        agent.assignAgent(depositId, agentWallet);
    }

    // ═══════════════════════════════════════════════
    //  DEPOSIT
    // ═══════════════════════════════════════════════

    function test_deposit() public {
        uint256 depositId = _depositAsUser(100 ether, 50 ether, CLMMLiquidityAgent.AgentStrategy.CONSERVATIVE, 7 days);

        assertEq(depositId, 1);
        assertEq(token0.balanceOf(address(agent)), 100 ether);
        assertEq(token1.balanceOf(address(agent)), 50 ether);

        CLMMLiquidityAgent.UserDeposit memory dep = agent.getDeposit(depositId);
        assertEq(dep.user, user);
        assertEq(dep.amount0Remaining, 100 ether);
        assertEq(dep.amount1Remaining, 50 ether);
        assertEq(uint8(dep.strategy), uint8(CLMMLiquidityAgent.AgentStrategy.CONSERVATIVE));
        assertEq(dep.lockUntil, block.timestamp + 7 days);
        assertEq(dep.assignedAgent, address(0));
    }

    function test_deposit_onlyToken0() public {
        uint256 depositId = _depositAsUser(100 ether, 0, CLMMLiquidityAgent.AgentStrategy.BALANCED, 30 days);

        CLMMLiquidityAgent.UserDeposit memory dep = agent.getDeposit(depositId);
        assertEq(dep.amount0Remaining, 100 ether);
        assertEq(dep.amount1Remaining, 0);
    }

    function test_deposit_revert_zeroAmounts() public {
        vm.startPrank(user);
        vm.expectRevert("Must deposit something");
        agent.deposit(0, 0, CLMMLiquidityAgent.AgentStrategy.CONSERVATIVE, 7 days);
        vm.stopPrank();
    }

    function test_deposit_revert_invalidLockPeriod() public {
        vm.startPrank(user);
        token0.approve(address(agent), 100 ether);
        vm.expectRevert("Invalid lock period");
        agent.deposit(100 ether, 0, CLMMLiquidityAgent.AgentStrategy.CONSERVATIVE, 10 days);
        vm.stopPrank();
    }

    function test_deposit_multipleDeposits() public {
        uint256 id1 = _depositAsUser(100 ether, 100 ether, CLMMLiquidityAgent.AgentStrategy.CONSERVATIVE, 7 days);
        uint256 id2 = _depositAsUser(200 ether, 200 ether, CLMMLiquidityAgent.AgentStrategy.CONSERVATIVE, 30 days);

        assertEq(id1, 1);
        assertEq(id2, 2);

        uint256[] memory ids = agent.getUserDeposits(user);
        assertEq(ids.length, 2);
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);
    }

    // ═══════════════════════════════════════════════
    //  ASSIGN AGENT
    // ═══════════════════════════════════════════════

    function test_assignAgent() public {
        uint256 depositId = _depositAsUser(100 ether, 100 ether, CLMMLiquidityAgent.AgentStrategy.CONSERVATIVE, 7 days);

        vm.prank(user);
        agent.assignAgent(depositId, agentWallet);

        CLMMLiquidityAgent.UserDeposit memory dep = agent.getDeposit(depositId);
        assertEq(dep.assignedAgent, agentWallet);
    }

    function test_assignAgent_revert_notYourDeposit() public {
        uint256 depositId = _depositAsUser(100 ether, 100 ether, CLMMLiquidityAgent.AgentStrategy.CONSERVATIVE, 7 days);

        vm.prank(otherUser);
        vm.expectRevert("Not your deposit");
        agent.assignAgent(depositId, agentWallet);
    }

    function test_assignAgent_revert_alreadyAssigned() public {
        uint256 depositId = _depositAndAssignAgent();

        vm.prank(user);
        vm.expectRevert("Agent already assigned");
        agent.assignAgent(depositId, agentWallet);
    }

    function test_assignAgent_revert_notAuthorized() public {
        uint256 depositId = _depositAsUser(100 ether, 100 ether, CLMMLiquidityAgent.AgentStrategy.CONSERVATIVE, 7 days);

        vm.prank(user);
        vm.expectRevert("Agent not authorized");
        agent.assignAgent(depositId, unregisteredAgent);
    }

    function test_assignAgent_revert_strategyMismatch() public {
        // Deposit with BALANCED strategy, but agent is authorized for CONSERVATIVE
        uint256 depositId = _depositAsUser(100 ether, 100 ether, CLMMLiquidityAgent.AgentStrategy.BALANCED, 7 days);

        vm.prank(user);
        vm.expectRevert("Strategy mismatch");
        agent.assignAgent(depositId, agentWallet);
    }

    // ═══════════════════════════════════════════════
    //  AUTHORIZE / REVOKE AGENT (ADMIN)
    // ═══════════════════════════════════════════════

    function test_authorizeAgent_onlyOwner() public {
        // Register a new agent in IdentityRegistry first
        address newAgent = address(0x1234);
        identityRegistry.newAgent("new-agent.liqu.finance", newAgent);

        agent.authorizeAgent(newAgent, CLMMLiquidityAgent.AgentStrategy.DEGEN);
        assertTrue(agent.authorizedAgents(newAgent));
    }

    function test_authorizeAgent_revert_notOwner() public {
        vm.prank(user);
        vm.expectRevert();
        agent.authorizeAgent(agentWallet, CLMMLiquidityAgent.AgentStrategy.BALANCED);
    }

    function test_authorizeAgent_revert_notRegistered() public {
        vm.expectRevert(); // resolveByAddress reverts with AgentNotFound
        agent.authorizeAgent(unregisteredAgent, CLMMLiquidityAgent.AgentStrategy.CONSERVATIVE);
    }

    function test_revokeAgent() public {
        agent.revokeAgent(agentWallet);
        assertFalse(agent.authorizedAgents(agentWallet));
    }

    function test_revokeAgent_revert_notOwner() public {
        vm.prank(user);
        vm.expectRevert();
        agent.revokeAgent(agentWallet);
    }

    // ═══════════════════════════════════════════════
    //  AGENT MINT POSITION
    // ═══════════════════════════════════════════════

    function test_agentMintPosition() public {
        uint256 depositId = _depositAndAssignAgent();

        int24 tickLower = -60;
        int24 tickUpper = 60;
        uint128 liquidity = 10e18;

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );

        uint256 tokenId = positionManager.nextTokenId();

        vm.prank(agentWallet);
        agent.agentMintPosition(
            depositId,
            tickLower,
            tickUpper,
            liquidity,
            amount0 + 1 ether,
            amount1 + 1 ether,
            block.timestamp + 1
        );

        // Verify pool has liquidity
        uint128 poolLiquidity = poolManager.getLiquidity(poolId);
        assertEq(poolLiquidity, liquidity);

        // Verify deposit was debited
        CLMMLiquidityAgent.UserDeposit memory dep = agent.getDeposit(depositId);
        assertEq(dep.amount0Remaining, 100 ether - (amount0 + 1 ether));
        assertEq(dep.amount1Remaining, 100 ether - (amount1 + 1 ether));

        // Verify NFT is owned by agent contract
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), address(agent));

        // Verify tokenId is tracked
        assertEq(agent.tokenIdToDepositId(tokenId), depositId);
    }

    function test_agentMintPosition_revert_notAssigned() public {
        uint256 depositId = _depositAndAssignAgent();

        vm.prank(otherUser);
        vm.expectRevert("Not assigned agent");
        agent.agentMintPosition(depositId, -60, 60, 10e18, 10 ether, 10 ether, block.timestamp + 1);
    }

    function test_agentMintPosition_revert_exceedsBalance() public {
        uint256 depositId = _depositAndAssignAgent();

        vm.prank(agentWallet);
        vm.expectRevert("Exceeds token0 balance");
        agent.agentMintPosition(depositId, -60, 60, 10e18, 200 ether, 10 ether, block.timestamp + 1);
    }

    function test_agentMintPosition_revert_lockExpired() public {
        uint256 depositId = _depositAndAssignAgent();

        // Warp past lock period
        vm.warp(block.timestamp + 8 days);

        vm.prank(agentWallet);
        vm.expectRevert("Lock period expired");
        agent.agentMintPosition(depositId, -60, 60, 10e18, 10 ether, 10 ether, block.timestamp + 1);
    }

    // ═══════════════════════════════════════════════
    //  AGENT CLOSE POSITION
    // ═══════════════════════════════════════════════

    function test_agentClosePosition() public {
        uint256 depositId = _depositAndAssignAgent();

        int24 tickLower = -60;
        int24 tickUpper = 60;
        uint128 liquidity = 10e18;

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );

        uint256 amount0Max = amount0 + 1 ether;
        uint256 amount1Max = amount1 + 1 ether;

        uint256 tokenId = positionManager.nextTokenId();

        vm.prank(agentWallet);
        agent.agentMintPosition(
            depositId, tickLower, tickUpper, liquidity,
            amount0Max, amount1Max, block.timestamp + 1
        );

        // Close the position
        vm.prank(agentWallet);
        agent.agentClosePosition(depositId, tokenId, 0, 0, block.timestamp + 1);

        // Verify pool liquidity is 0
        assertEq(poolManager.getLiquidity(poolId), 0);

        // Verify tokens returned to deposit
        CLMMLiquidityAgent.UserDeposit memory dep = agent.getDeposit(depositId);
        // amount0Remaining should be back close to the original (minus dust/rounding)
        assertTrue(dep.amount0Remaining > 0);
        assertTrue(dep.amount1Remaining > 0);

        // Verify tokenId untracked
        assertEq(agent.tokenIdToDepositId(tokenId), 0);
    }

    function test_agentClosePosition_revert_notAssigned() public {
        uint256 depositId = _depositAndAssignAgent();

        int24 tickLower = -60;
        int24 tickUpper = 60;
        uint128 liquidity = 10e18;

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );

        uint256 tokenId = positionManager.nextTokenId();

        vm.prank(agentWallet);
        agent.agentMintPosition(
            depositId, tickLower, tickUpper, liquidity,
            amount0 + 1 ether, amount1 + 1 ether, block.timestamp + 1
        );

        vm.prank(otherUser);
        vm.expectRevert("Not assigned agent");
        agent.agentClosePosition(depositId, tokenId, 0, 0, block.timestamp + 1);
    }

    // ═══════════════════════════════════════════════
    //  WITHDRAW
    // ═══════════════════════════════════════════════

    function test_withdraw() public {
        uint256 depositId = _depositAsUser(100 ether, 100 ether, CLMMLiquidityAgent.AgentStrategy.CONSERVATIVE, 7 days);

        uint256 userBal0Before = token0.balanceOf(user);
        uint256 userBal1Before = token1.balanceOf(user);

        // Warp past lock
        vm.warp(block.timestamp + 8 days);

        vm.prank(user);
        agent.withdraw(depositId);

        // Verify tokens returned to user
        assertEq(token0.balanceOf(user), userBal0Before + 100 ether);
        assertEq(token1.balanceOf(user), userBal1Before + 100 ether);

        // Verify status
        CLMMLiquidityAgent.UserDeposit memory dep = agent.getDeposit(depositId);
        assertEq(uint8(dep.status), uint8(CLMMLiquidityAgent.PositionStatus.WITHDRAWN));
        assertEq(dep.amount0Remaining, 0);
        assertEq(dep.amount1Remaining, 0);
    }

    function test_withdraw_revert_stillLocked() public {
        uint256 depositId = _depositAsUser(100 ether, 100 ether, CLMMLiquidityAgent.AgentStrategy.CONSERVATIVE, 7 days);

        vm.prank(user);
        vm.expectRevert("Still locked");
        agent.withdraw(depositId);
    }

    function test_withdraw_revert_notYourDeposit() public {
        uint256 depositId = _depositAsUser(100 ether, 100 ether, CLMMLiquidityAgent.AgentStrategy.CONSERVATIVE, 7 days);

        vm.warp(block.timestamp + 8 days);

        vm.prank(otherUser);
        vm.expectRevert("Not your deposit");
        agent.withdraw(depositId);
    }

    function test_withdraw_revert_alreadyWithdrawn() public {
        uint256 depositId = _depositAsUser(100 ether, 100 ether, CLMMLiquidityAgent.AgentStrategy.CONSERVATIVE, 7 days);

        vm.warp(block.timestamp + 8 days);

        vm.prank(user);
        agent.withdraw(depositId);

        vm.prank(user);
        vm.expectRevert("Already withdrawn");
        agent.withdraw(depositId);
    }

    function test_withdraw_revert_positionsOpen() public {
        uint256 depositId = _depositAndAssignAgent();

        int24 tickLower = -60;
        int24 tickUpper = 60;
        uint128 liquidity = 10e18;

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );

        vm.prank(agentWallet);
        agent.agentMintPosition(
            depositId, tickLower, tickUpper, liquidity,
            amount0 + 1 ether, amount1 + 1 ether, block.timestamp + 1
        );

        vm.warp(block.timestamp + 8 days);

        vm.prank(user);
        vm.expectRevert("Positions must be closed first");
        agent.withdraw(depositId);
    }

    // ═══════════════════════════════════════════════
    //  MULTI-USER ISOLATION
    // ═══════════════════════════════════════════════

    function test_multiUser_isolation() public {
        // User1 deposits
        uint256 id1 = _depositAsUser(100 ether, 100 ether, CLMMLiquidityAgent.AgentStrategy.CONSERVATIVE, 7 days);

        // User2 deposits
        vm.startPrank(otherUser);
        token0.approve(address(agent), 200 ether);
        token1.approve(address(agent), 200 ether);
        uint256 id2 = agent.deposit(200 ether, 200 ether, CLMMLiquidityAgent.AgentStrategy.CONSERVATIVE, 7 days);
        vm.stopPrank();

        // Warp past lock
        vm.warp(block.timestamp + 8 days);

        // User1 withdraws — should only get 100, not 300
        vm.prank(user);
        agent.withdraw(id1);
        CLMMLiquidityAgent.UserDeposit memory dep1 = agent.getDeposit(id1);
        assertEq(uint8(dep1.status), uint8(CLMMLiquidityAgent.PositionStatus.WITHDRAWN));

        // User2 still has their deposit
        CLMMLiquidityAgent.UserDeposit memory dep2 = agent.getDeposit(id2);
        assertEq(dep2.amount0Remaining, 200 ether);
        assertEq(dep2.amount1Remaining, 200 ether);

        // User2 withdraws — should get exactly 200
        uint256 otherBal0Before = token0.balanceOf(otherUser);
        vm.prank(otherUser);
        agent.withdraw(id2);
        assertEq(token0.balanceOf(otherUser), otherBal0Before + 200 ether);
    }

    // ═══════════════════════════════════════════════
    //  FULL FLOW: deposit -> assign -> mint -> close -> withdraw
    // ═══════════════════════════════════════════════

    function test_fullFlow() public {
        // 1. User deposits
        uint256 depositId = _depositAsUser(
            100 ether, 100 ether,
            CLMMLiquidityAgent.AgentStrategy.CONSERVATIVE,
            7 days
        );

        // 2. User assigns agent
        vm.prank(user);
        agent.assignAgent(depositId, agentWallet);

        // 3. Agent creates position
        int24 tickLower = -60;
        int24 tickUpper = 60;
        uint128 liquidity = 10e18;

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );

        uint256 amount0Max = amount0 + 1 ether;
        uint256 amount1Max = amount1 + 1 ether;
        uint256 tokenId = positionManager.nextTokenId();

        vm.prank(agentWallet);
        agent.agentMintPosition(
            depositId, tickLower, tickUpper, liquidity,
            amount0Max, amount1Max, block.timestamp + 1
        );

        // 4. Verify pool liquidity
        assertEq(poolManager.getLiquidity(poolId), liquidity);

        // 5. Agent closes position
        vm.prank(agentWallet);
        agent.agentClosePosition(depositId, tokenId, 0, 0, block.timestamp + 1);

        assertEq(poolManager.getLiquidity(poolId), 0);

        // 6. User withdraws after lock
        vm.warp(block.timestamp + 8 days);

        uint256 userBal0Before = token0.balanceOf(user);
        uint256 userBal1Before = token1.balanceOf(user);

        vm.prank(user);
        agent.withdraw(depositId);

        // User gets tokens back (minus potential dust from rounding)
        assertTrue(token0.balanceOf(user) > userBal0Before);
        assertTrue(token1.balanceOf(user) > userBal1Before);

        CLMMLiquidityAgent.UserDeposit memory dep = agent.getDeposit(depositId);
        assertEq(uint8(dep.status), uint8(CLMMLiquidityAgent.PositionStatus.WITHDRAWN));
    }
}
