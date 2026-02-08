// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {CLMMRouter} from "./CLMMRouter.sol";
import {IIdentityRegistry} from "./interfaces/IIdentityRegistry.sol";
import {IReputationRegistry} from "./interfaces/IReputationRegistry.sol";

/// @title CLMM Liquidity Agent Manager
/// @notice Manages user deposits and allows ERC-8004 registered agents to create/manage CLMM positions
/// @dev Integrates with ERC-8004 IdentityRegistry & ReputationRegistry for agent trust.
///      Tokens are transferred to CLMMRouter before minting, because Permit2 pulls from the
///      caller of modifyLiquidities (CLMMRouter), not from the original sender.
contract CLMMLiquidityAgent is ReentrancyGuard, Ownable {

    // ══════════════════════════════════════════════════════
    //  TYPES & EVENTS
    // ══════════════════════════════════════════════════════

    enum AgentStrategy {
        CONSERVATIVE,  // Narrow range, frequent rebalancing
        BALANCED,      // Medium range, moderate rebalancing
        DEGEN          // Wide range, rare rebalancing
    }

    enum PositionStatus {
        ACTIVE,
        CLOSED,
        WITHDRAWN
    }

    struct UserDeposit {
        address user;
        uint256 amount0Remaining;      // Token0 balance not yet in a position
        uint256 amount1Remaining;      // Token1 balance not yet in a position
        uint256 depositTime;
        uint256 lockUntil;
        AgentStrategy strategy;
        address assignedAgent;
        PositionStatus status;
        uint256[] positionTokenIds;
    }

    struct PoolInfo {
        address token0;
        address token1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    event DepositCreated(
        uint256 indexed depositId,
        address indexed user,
        uint256 amount0,
        uint256 amount1,
        AgentStrategy strategy,
        uint256 lockUntil
    );

    event AgentAssigned(uint256 indexed depositId, address indexed agent);
    event PositionCreated(uint256 indexed depositId, uint256 indexed tokenId);
    event PositionClosed(uint256 indexed depositId, uint256 indexed tokenId);
    event WithdrawalCompleted(uint256 indexed depositId, uint256 amount0, uint256 amount1);
    event AgentAuthorized(address indexed agent, AgentStrategy strategy);
    event AgentRevoked(address indexed agent);

    // ══════════════════════════════════════════════════════
    //  STATE VARIABLES
    // ══════════════════════════════════════════════════════

    CLMMRouter public immutable clmmRouter;
    IPositionManager public immutable positionManager;
    IPermit2 public immutable permit2;
    IIdentityRegistry public immutable identityRegistry;
    IReputationRegistry public immutable reputationRegistry;

    PoolInfo public poolInfo;

    mapping(uint256 => UserDeposit) public deposits;
    mapping(address => uint256[]) public userDepositIds;
    uint256 public nextDepositId = 1;

    // Agent authorization
    mapping(address => bool) public authorizedAgents;
    mapping(address => AgentStrategy) public agentStrategy;

    // Track which deposit owns which NFT
    mapping(uint256 => uint256) public tokenIdToDepositId;

    // ══════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ══════════════════════════════════════════════════════

    constructor(
        address _clmmRouter,
        address _positionManager,
        address _permit2,
        address _identityRegistry,
        address _reputationRegistry,
        PoolInfo memory _poolInfo
    ) Ownable(msg.sender) {
        clmmRouter = CLMMRouter(_clmmRouter);
        positionManager = IPositionManager(_positionManager);
        permit2 = IPermit2(_permit2);
        identityRegistry = IIdentityRegistry(_identityRegistry);
        reputationRegistry = IReputationRegistry(_reputationRegistry);
        poolInfo = _poolInfo;

        // Approve tokens to CLMMRouter so we can transfer tokens to it
        IERC20(_poolInfo.token0).approve(_clmmRouter, type(uint256).max);
        IERC20(_poolInfo.token1).approve(_clmmRouter, type(uint256).max);

        // Approve CLMMRouter as operator for position NFTs (for decrease/close)
        IERC721(_positionManager).setApprovalForAll(_clmmRouter, true);
    }

    /// @notice One-time setup: have CLMMRouter approve Permit2 -> PositionManager flow
    /// @dev Must be called after deployment by the owner.
    function setupRouterApprovals() external onlyOwner {
        clmmRouter.approveToken(poolInfo.token0);
        clmmRouter.approveToken(poolInfo.token1);
    }

    // ══════════════════════════════════════════════════════
    //  USER FUNCTIONS
    // ══════════════════════════════════════════════════════

    /// @notice User deposits funds to be managed by an agent
    /// @param amount0 Amount of token0 to deposit
    /// @param amount1 Amount of token1 to deposit
    /// @param strategy Strategy type (CONSERVATIVE, BALANCED, DEGEN)
    /// @param lockPeriod Lock period in seconds (7 days, 30 days, or 365 days)
    /// @return depositId The ID of the created deposit
    function deposit(
        uint256 amount0,
        uint256 amount1,
        AgentStrategy strategy,
        uint256 lockPeriod
    ) external nonReentrant returns (uint256 depositId) {
        require(amount0 > 0 || amount1 > 0, "Must deposit something");
        require(
            lockPeriod == 7 days || lockPeriod == 30 days || lockPeriod == 365 days,
            "Invalid lock period"
        );

        depositId = nextDepositId++;

        if (amount0 > 0) {
            IERC20(poolInfo.token0).transferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 > 0) {
            IERC20(poolInfo.token1).transferFrom(msg.sender, address(this), amount1);
        }

        deposits[depositId] = UserDeposit({
            user: msg.sender,
            amount0Remaining: amount0,
            amount1Remaining: amount1,
            depositTime: block.timestamp,
            lockUntil: block.timestamp + lockPeriod,
            strategy: strategy,
            assignedAgent: address(0),
            status: PositionStatus.ACTIVE,
            positionTokenIds: new uint256[](0)
        });

        userDepositIds[msg.sender].push(depositId);

        emit DepositCreated(depositId, msg.sender, amount0, amount1, strategy, block.timestamp + lockPeriod);
    }

    /// @notice User assigns an ERC-8004 registered agent to manage their deposit
    /// @param depositId The deposit ID
    /// @param agent The agent address (must be registered in IdentityRegistry)
    function assignAgent(uint256 depositId, address agent) external {
        UserDeposit storage dep = deposits[depositId];
        require(dep.user == msg.sender, "Not your deposit");
        require(dep.assignedAgent == address(0), "Agent already assigned");
        require(authorizedAgents[agent], "Agent not authorized");
        require(agentStrategy[agent] == dep.strategy, "Strategy mismatch");

        // ERC-8004: Verify agent is registered in IdentityRegistry
        require(identityRegistry.agentExists(_getAgentId(agent)), "Agent not in IdentityRegistry");

        dep.assignedAgent = agent;
        emit AgentAssigned(depositId, agent);
    }

    /// @notice User withdraws their remaining funds after lock period
    /// @param depositId The deposit ID
    function withdraw(uint256 depositId) external nonReentrant {
        UserDeposit storage dep = deposits[depositId];
        require(dep.user == msg.sender, "Not your deposit");
        require(block.timestamp >= dep.lockUntil, "Still locked");
        require(dep.status != PositionStatus.WITHDRAWN, "Already withdrawn");
        require(dep.positionTokenIds.length == 0, "Positions must be closed first");

        uint256 out0 = dep.amount0Remaining;
        uint256 out1 = dep.amount1Remaining;

        dep.amount0Remaining = 0;
        dep.amount1Remaining = 0;
        dep.status = PositionStatus.WITHDRAWN;

        if (out0 > 0) {
            IERC20(poolInfo.token0).transfer(msg.sender, out0);
        }
        if (out1 > 0) {
            IERC20(poolInfo.token1).transfer(msg.sender, out1);
        }

        emit WithdrawalCompleted(depositId, out0, out1);
    }

    /// @notice Get user's deposit IDs
    function getUserDeposits(address user) external view returns (uint256[] memory) {
        return userDepositIds[user];
    }

    /// @notice Get deposit details
    function getDeposit(uint256 depositId) external view returns (UserDeposit memory) {
        return deposits[depositId];
    }

    // ══════════════════════════════════════════════════════
    //  AGENT FUNCTIONS
    // ══════════════════════════════════════════════════════

    /// @notice Agent creates a new CLMM position using deposit funds
    /// @param depositId The deposit ID to use funds from
    /// @param tickLower Lower tick of the position
    /// @param tickUpper Upper tick of the position
    /// @param liquidity Amount of liquidity to mint
    /// @param amount0Max Maximum token0 to spend
    /// @param amount1Max Maximum token1 to spend
    /// @param deadline Transaction deadline
    function agentMintPosition(
        uint256 depositId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        uint256 deadline
    ) external nonReentrant {
        UserDeposit storage dep = deposits[depositId];
        require(dep.assignedAgent == msg.sender, "Not assigned agent");
        require(dep.status == PositionStatus.ACTIVE, "Deposit not active");
        require(block.timestamp < dep.lockUntil, "Lock period expired");
        require(amount0Max <= dep.amount0Remaining, "Exceeds token0 balance");
        require(amount1Max <= dep.amount1Remaining, "Exceeds token1 balance");

        // Record the next tokenId before minting
        uint256 tokenId = positionManager.nextTokenId();

        // Transfer tokens to CLMMRouter so Permit2 can pull from it
        IERC20(poolInfo.token0).transfer(address(clmmRouter), amount0Max);
        IERC20(poolInfo.token1).transfer(address(clmmRouter), amount1Max);

        CLMMRouter.PoolParams memory params = CLMMRouter.PoolParams({
            token0: poolInfo.token0,
            token1: poolInfo.token1,
            fee: poolInfo.fee,
            tickSpacing: poolInfo.tickSpacing,
            hooks: poolInfo.hooks
        });

        // Mint — NFT goes to this contract so we can manage it
        clmmRouter.mintPosition(
            params,
            tickLower,
            tickUpper,
            liquidity,
            amount0Max,
            amount1Max,
            address(this),
            deadline
        );

        // Track the position
        dep.positionTokenIds.push(tokenId);
        tokenIdToDepositId[tokenId] = depositId;

        // Deduct from remaining balances
        dep.amount0Remaining -= amount0Max;
        dep.amount1Remaining -= amount1Max;

        emit PositionCreated(depositId, tokenId);
    }

    /// @notice Agent closes a position and returns tokens to the deposit
    /// @param depositId The deposit ID
    /// @param tokenId The NFT token ID to close
    /// @param amount0Min Minimum token0 to receive
    /// @param amount1Min Minimum token1 to receive
    /// @param deadline Transaction deadline
    function agentClosePosition(
        uint256 depositId,
        uint256 tokenId,
        uint128 amount0Min,
        uint128 amount1Min,
        uint256 deadline
    ) external nonReentrant {
        UserDeposit storage dep = deposits[depositId];
        require(dep.assignedAgent == msg.sender, "Not assigned agent");
        require(tokenIdToDepositId[tokenId] == depositId, "Token not in deposit");

        uint256 balance0Before = IERC20(poolInfo.token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(poolInfo.token1).balanceOf(address(this));

        // Close position — tokens come back to this contract
        clmmRouter.closePosition(
            tokenId,
            amount0Min,
            amount1Min,
            address(this),
            deadline
        );

        uint256 received0 = IERC20(poolInfo.token0).balanceOf(address(this)) - balance0Before;
        uint256 received1 = IERC20(poolInfo.token1).balanceOf(address(this)) - balance1Before;

        // Credit received tokens back to the deposit
        dep.amount0Remaining += received0;
        dep.amount1Remaining += received1;

        // Remove from tracked positions
        _removePositionTokenId(depositId, tokenId);
        delete tokenIdToDepositId[tokenId];

        emit PositionClosed(depositId, tokenId);
    }

    // ══════════════════════════════════════════════════════
    //  ADMIN FUNCTIONS
    // ══════════════════════════════════════════════════════

    /// @notice Owner authorizes an agent (must be registered in IdentityRegistry)
    /// @param agent The agent's EVM address
    /// @param strategy The strategy this agent will manage
    function authorizeAgent(address agent, AgentStrategy strategy) external onlyOwner {
        // ERC-8004: Verify agent is registered in IdentityRegistry
        IIdentityRegistry.AgentInfo memory info = identityRegistry.resolveByAddress(agent);
        require(info.agentId != 0, "Agent not registered in ERC-8004");

        authorizedAgents[agent] = true;
        agentStrategy[agent] = strategy;
        emit AgentAuthorized(agent, strategy);
    }

    /// @notice Owner removes agent authorization
    function revokeAgent(address agent) external onlyOwner {
        authorizedAgents[agent] = false;
        emit AgentRevoked(agent);
    }

    // ══════════════════════════════════════════════════════
    //  INTERNAL HELPERS
    // ══════════════════════════════════════════════════════

    /// @dev Resolve an agent address to its ERC-8004 agentId (returns 0 if not found)
    function _getAgentId(address agent) internal view returns (uint256) {
        try identityRegistry.resolveByAddress(agent) returns (IIdentityRegistry.AgentInfo memory info) {
            return info.agentId;
        } catch {
            return 0;
        }
    }

    function _removePositionTokenId(uint256 depositId, uint256 tokenId) internal {
        UserDeposit storage dep = deposits[depositId];
        uint256[] storage tokenIds = dep.positionTokenIds;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (tokenIds[i] == tokenId) {
                tokenIds[i] = tokenIds[tokenIds.length - 1];
                tokenIds.pop();
                break;
            }
        }
    }

    // ERC721 receiver so this contract can hold position NFTs
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}
