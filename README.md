# 🦄 CLMM Liquidity Agent - Uniswap V4 Integration

**Trustless AI-managed liquidity positions on Uniswap V4 with ERC-8004 agent identity**

## 📋 Overview

CLMM Liquidity Agent is a system that enables AI agents to manage Concentrated Liquidity Market Maker (CLMM) positions on Uniswap V4 in a trustless manner. This system integrates:

- **Uniswap V4 CLMM**: Concentrated liquidity positions with maximum capital efficiency
- **ERC-8004 Registries**: Identity and reputation registry for agent trust
- **Multi-Strategy Management**: Conservative, Balanced, and Degen strategies

## 🎯 Key Features

- ✅ **Trustless Agent Management**: Agents verified through ERC-8004 IdentityRegistry
- ✅ **Multi-Strategy Support**: 3 different strategies (Conservative, Balanced, Degen)
- ✅ **Lock Period Protection**: User funds protected with lock period
- ✅ **Position Tracking**: Track multiple positions per deposit
- ✅ **Automated Rebalancing**: Agents can close & reopen positions to optimize returns
- ✅ **Security First**: ReentrancyGuard, Ownable, and strict validation

## 📁 Project Structure

```
uniswap-contract/
├── src/
│   ├── CLMMLiquidityAgent.sol    # Main contract - manages deposits & agents
│   ├── CLMMRouter.sol             # Router helper for CLMM operations
│   ├── IdentityRegistry.sol       # ERC-8004 identity registry (copied for reference)
│   ├── ReputationRegistry.sol     # ERC-8004 reputation registry (copied for reference)
│   └── interfaces/
│       ├── IIdentityRegistry.sol
│       └── IReputationRegistry.sol
├── script/
│   ├── DeployCLMM.s.sol          # Deploy CLMM agent (RECOMMENDED)
│   ├── DeployERC8004.s.sol       # Info script - deploy from agent-erc8004/
│   └── DEPLOYMENT.md             # Detailed deployment guide
└── test/
    └── (test files)
```

## 🏗️ Architecture

### 1. CLMMLiquidityAgent (Main Contract)

Main contract that manages:
- User deposits with lock periods
- Agent authorization & assignment
- Position creation & closing
- Withdrawal management

**Key Components:**
```solidity
struct UserDeposit {
    address user;
    uint256 amount0Remaining;      // Remaining token0 balance
    uint256 amount1Remaining;      // Remaining token1 balance
    uint256 depositTime;
    uint256 lockUntil;             // Lock until timestamp
    AgentStrategy strategy;         // CONSERVATIVE | BALANCED | DEGEN
    address assignedAgent;
    PositionStatus status;
    uint256[] positionTokenIds;    // Array of position NFT IDs
}

enum AgentStrategy {
    CONSERVATIVE,  // Narrow range, frequent rebalancing
    BALANCED,      // Medium range, moderate rebalancing
    DEGEN          // Wide range, rare rebalancing
}
```

### 2. CLMMRouter (Helper Contract)

Stateless helper to simplify CLMM operations:
- Mint positions (create liquidity)
- Close positions (remove liquidity)
- Get position info
- Calculate amounts

### 3. ERC-8004 Integration

**IdentityRegistry**: Central registry for agent identities
- Domain registration (`agent.liqu.finance`)
- Address mapping
- Spam protection with registration fee

**ReputationRegistry**: Feedback system between agents
- Authorization tracking
- Client-server feedback links

## 🚀 Quick Start

### Prerequisites

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install dependencies
forge install
```

### Environment Setup

Create `.env` file:
```bash
# Network RPC
UNICHAIN_SEPOLIA_RPC_URL=https://sepolia.unichain.org

# Deployment
PRIVATE_KEY=your_private_key_here

# Verification
UNISCAN_API_KEY=your_uniscan_api_key
```

### Build & Test

```bash
# Compile contracts
forge build

# Run tests
forge test

# Run tests with gas report
forge test --gas-report

# Run specific test
forge test --match-test testDeposit -vvv
```

## 📦 Deployment

### Two-Step Deployment Process

Deployment is separated into 2 steps to avoid circular dependencies:

#### Step 1: Deploy ERC-8004 Registries

```bash
# Deploy from agent-erc8004 folder
cd ../agent-erc8004

forge script script/DeployERC8004.s.sol:DeployERC8004Script \
  --rpc-url $UNICHAIN_SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $UNISCAN_API_KEY
```

**Output:** Save these addresses:
- IdentityRegistry: `0x...`
- ReputationRegistry: `0x...`
- ValidationRegistry: `0x...`

#### Step 2: Deploy CLMM Liquidity Agent

1. Update addresses in [script/DeployCLMM.s.sol](script/DeployCLMM.s.sol):
```solidity
address constant IDENTITY_REGISTRY = 0x...; // from Step 1
address constant REPUTATION_REGISTRY = 0x...; // from Step 1
```

2. Deploy:
```bash
cd ../uniswap-contract

forge script script/DeployCLMM.s.sol:DeployCLMMScript \
  --rpc-url $UNICHAIN_SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $UNISCAN_API_KEY
```

📖 **Detailed Guide:** See [script/DEPLOYMENT.md](script/DEPLOYMENT.md)

## 📖 Usage

### For Users

#### 1. Deposit Funds

```solidity
// Approve tokens first
IERC20(TOKEN0).approve(address(agent), amount0);
IERC20(TOKEN1).approve(address(agent), amount1);

// Deposit
uint256 depositId = agent.deposit(
    amount0,              // Amount of token0
    amount1,              // Amount of token1
    AgentStrategy.BALANCED, // Strategy
    30 days               // Lock period (7, 30, or 365 days)
);
```

#### 2. Assign Agent

```solidity
// Assign an authorized agent to manage your deposit
agent.assignAgent(depositId, agentAddress);
```

#### 3. Withdraw After Lock Period

```solidity
// Wait until lock period expires
// Then withdraw remaining funds
agent.withdraw(depositId);
```

### For Agents

#### 1. Create Position

```solidity
agent.agentMintPosition(
    depositId,
    tickLower,    // Lower tick of range
    tickUpper,    // Upper tick of range
    liquidity,    // Amount of liquidity
    amount0Max,   // Max token0 to use
    amount1Max,   // Max token1 to use
    deadline      // Transaction deadline
);
```

#### 2. Close Position

```solidity
agent.agentClosePosition(
    depositId,
    tokenId,      // Position NFT ID
    amount0Min,   // Min token0 to receive
    amount1Min,   // Min token1 to receive
    deadline      // Transaction deadline
);
```

### For Admin

#### Authorize Agent

```solidity
// Agent must be registered in IdentityRegistry first
agent.authorizeAgent(
    agentAddress,
    AgentStrategy.CONSERVATIVE
);
```

#### Revoke Agent

```solidity
agent.revokeAgent(agentAddress);
```

## 🔧 Configuration

### Network: Unichain Sepolia

| Contract | Address |
|----------|---------|
| CLMM Router | `0x11A74D375951D27a3E159a7B6CFfaa7B2A2cbC36` |
| Position Manager | `0xf969Aee60879C54bAAed9F3eD26147Db216Fd664` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |

### Pool Configuration

| Parameter | Value |
|-----------|-------|
| TOKEN0 (USDT) | `0x4dABf45C8cF333Ef1e874c3FDFC3C86799af80c8` |
| TOKEN1 (WETH) | `0xf96c5C189a949C73745a277A4Acf071B1B9f6DF5` |
| Fee Tier | `3000` (0.3%) |
| Tick Spacing | `60` |

### Agent Addresses

| Agent | Address | Domain | Strategy |
|-------|---------|--------|----------|
| Conservative | `0x5b6A404F8958E7e10028301549e61435925725Bf` | `conservative.liqu.finance` | Conservative |
| Balanced | `0x6c52aAD1Cbb66C0f666b62b36261d2f2205A8607` | `balanced.liqu.finance` | Balanced |
| Degen | `0x5B20B5a4Bba73bC6363fBE90E6b2Ab4fFF5C820e` | `degen.liqu.finance` | Degen |

## 🔐 Security

### Security Features

- ✅ **ReentrancyGuard**: Prevents reentrancy attacks
- ✅ **Ownable**: Admin functions protected
- ✅ **ERC-8004 Validation**: Agents must be registered
- ✅ **Lock Period**: User funds protected during management
- ✅ **Authorization Checks**: Only assigned agents can manage positions
- ✅ **Balance Tracking**: Remaining balances tracked separately

### Audit Status

⚠️ **Not Audited**: This is a hackathon project. DO NOT use in production without proper audit.

### Known Limitations

1. **No Emergency Withdraw**: Users cannot withdraw during lock period
2. **Single Pool**: Contract configured for one pool only
3. **No Fee Collection**: Trading fees not separately tracked
4. **Gas Intensive**: Multiple positions can increase gas costs

## 🧪 Testing

```bash
# Run all tests
forge test

# Run specific test file
forge test --match-path test/CLMMLiquidityAgent.t.sol

# Run with verbosity
forge test -vvv

# Run with gas report
forge test --gas-report

# Fork testing (Unichain Sepolia)
forge test --fork-url $UNICHAIN_SEPOLIA_RPC_URL
```

## 📊 Contract Interfaces

### CLMMLiquidityAgent

**User Functions:**
- `deposit(amount0, amount1, strategy, lockPeriod)` - Create deposit
- `assignAgent(depositId, agent)` - Assign agent
- `withdraw(depositId)` - Withdraw after lock period
- `getUserDeposits(user)` - Get user's deposit IDs
- `getDeposit(depositId)` - Get deposit details

**Agent Functions:**
- `agentMintPosition(...)` - Create new position
- `agentClosePosition(...)` - Close existing position

**Admin Functions:**
- `authorizeAgent(agent, strategy)` - Authorize agent
- `revokeAgent(agent)` - Revoke authorization
- `setupRouterApprovals()` - One-time setup

### CLMMRouter

**Functions:**
- `mintPosition(...)` - Mint liquidity position
- `closePosition(...)` - Close position & collect fees
- `getPositionInfo(tokenId)` - Get position details
- `calculateAmountsForLiquidity(...)` - Calculate token amounts
- `approveToken(token)` - Approve Permit2

## 🐛 Troubleshooting

### Common Issues

#### 1. "Agent not registered in ERC-8004"
**Solution:** Deploy ERC-8004 registries first and register agents

#### 2. "IDENTITY_REGISTRY not set"
**Solution:** Update addresses in `DeployCLMM.s.sol` after Step 1

#### 3. "Import not found"
**Solution:** Run `forge install` to install dependencies

#### 4. "Strategy mismatch"
**Solution:** Ensure agent strategy matches deposit strategy

#### 5. "Still locked"
**Solution:** Wait until lock period expires before withdrawing

### Debug Commands

```bash
# Check agent registration
cast call $IDENTITY_REGISTRY \
  "agentExists(uint256)(bool)" 1 \
  --rpc-url $UNICHAIN_SEPOLIA_RPC_URL

# Check agent authorization
cast call $CLMM_AGENT \
  "authorizedAgents(address)(bool)" $AGENT_ADDRESS \
  --rpc-url $UNICHAIN_SEPOLIA_RPC_URL

# Get deposit info
cast call $CLMM_AGENT \
  "getDeposit(uint256)" $DEPOSIT_ID \
  --rpc-url $UNICHAIN_SEPOLIA_RPC_URL
```

## 📚 Additional Resources

### Uniswap V4
- [Uniswap V4 Docs](https://docs.uniswap.org/contracts/v4/overview)
- [v4-core](https://github.com/uniswap/v4-core)
- [v4-periphery](https://github.com/uniswap/v4-periphery)
- [v4-by-example](https://v4-by-example.org)

### ERC-8004
- [ERC-8004 Specification](https://eips.ethereum.org/EIPS/eip-8004)
- [Agent Identity Standard](../agent-erc8004/README.md)

### Foundry
- [Foundry Book](https://book.getfoundry.sh/)
- [Forge Documentation](https://book.getfoundry.sh/forge/)

## 🤝 Contributing

This is a hackathon project. Contributions welcome!

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing`)
5. Open a Pull Request

## 📄 License

MIT License - see [LICENSE](../LICENSE) file for details

## 🙏 Acknowledgments

- Uniswap Foundation for V4 template
- ERC-8004 standard authors
- Foundry team for amazing tooling

---

**⚠️ Disclaimer:** This is a hackathon project for educational purposes. Not audited. Use at your own risk.

**Built with ❤️ for Uniswap V4 + ERC-8004 integration**
