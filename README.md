# BitLend Protocol
*Bitcoin-Native Cross-Chain Lending via Stacks & sBTC*

## 🚀 Vision

BitLend transforms Bitcoin into productive cross-chain collateral without compromising self-custody. Deposit your Bitcoin directly on the Bitcoin blockchain, mint synthetic assets across any supported chain. No wrapped tokens, no bridge risks - just pure Bitcoin-backed liquidity everywhere.

## 🎯 What Problem We're Solving

Bitcoin holders want DeFi access but face impossible choices:
- **Sell Bitcoin** → Lose upside exposure
- **Use wrapped BTC** → Trust centralized bridges
- **Bridge to L2s** → Pay fees + counterparty risk

BitLend eliminates these tradeoffs. Your Bitcoin stays on Bitcoin. Your liquidity works everywhere.

## 🏗️ How It Works

1. **Deposit Bitcoin** → Lock BTC in sBTC contract on Bitcoin L1
2. **Mint sBTC** → Trust-minimized Bitcoin representation on Stacks
3. **Cross-Chain Magic** → Use sBTC as collateral to mint synthetic assets on Ethereum, Solana, Polygon, etc.
4. **Keep Earning** → Your Bitcoin position remains intact while accessing DeFi yields

Built on Stacks' revolutionary sBTC bridge + Chainlink CCIP for seamless cross-chain execution.

## 🛠️ Tech Stack

- **Bitcoin Layer**: Native BTC deposits via sBTC protocol
- **Stacks Layer**: Clarity smart contracts for collateral management
- **Cross-Chain**: Chainlink CCIP for multi-chain synthetic asset minting
- **Frontend**: Next.js 15 with Stacks.js integration
- **Oracles**: Chainlink Price Feeds + Stacks native oracles

## ⚡ Getting Started

> **Note**: This is a solo developer project built with passion, coffee, and countless Stack Overflow visits. Expecting some rough edges while we build toward production!

### Prerequisites
```bash
# Bitcoin testnet access
# Stacks testnet (Nakamoto)
# Node.js 18+
# Clarinet CLI for Stacks development
```

### Installation
```bash
git clone https://github.com/yourusername/bitlend-protocol
cd bitlend-protocol
npm install

# Install Stacks dependencies
cd contracts/stacks
clarinet install

# Install EVM dependencies  
cd ../evm
npm install

# Install Solana dependencies
cd ../solana
npm install
```

### Environment Setup
```bash
cp .env.example .env.local
# Add your RPC URLs, API keys, and wallet addresses
```

### Development
```bash
# Start local development
npm run dev

# Test Stacks contracts
cd contracts/stacks && clarinet test

# Test EVM contracts
cd contracts/evm && npm run test

# Deploy to testnets
npm run deploy:testnet
```

## 📁 Contract Architecture

### Core Stacks Contracts (`/contracts/stacks/`)

**`bitlend-core.clar`**
- Main protocol logic and state management
- sBTC collateral tracking and health factor calculations
- User position management and liquidation logic

**`sbtc-collateral-manager.clar`**
- Interfaces with sBTC bridge for Bitcoin deposits/withdrawals
- Collateral validation and reserve management
- Emergency pause and recovery mechanisms

**`cross-chain-messenger.clar`**
- Handles outbound messages to other chains via Chainlink CCIP
- Message validation and cross-chain state synchronization
- Implements secure message replay protection

**`price-oracle-aggregator.clar`**
- Aggregates price feeds from multiple sources
- Implements fallback mechanisms for oracle failures
- Provides real-time BTC/USD and collateral ratios

**`governance.clar`**
- Protocol parameter management (LTV ratios, interest rates)
- Timelock mechanisms for critical updates
- Community voting for protocol upgrades

**`liquidation-engine.clar`**
- Automated liquidation detection and execution
- Keeper incentive mechanisms
- Partial liquidation support for better capital efficiency

### EVM Contracts (`/contracts/evm/`)

**`BitLendEthereum.sol`**
- Receives cross-chain messages from Stacks via Chainlink CCIP
- Mints synthetic USDC/USDT backed by Bitcoin collateral
- Implements ERC-20 synthetic asset standards

**`SyntheticAssetFactory.sol`**
- Factory pattern for creating new synthetic assets
- Manages synthetic asset metadata and configurations
- Handles synthetic asset burning and redemption

**`CCIPMessageReceiver.sol`**
- Chainlink CCIP integration for cross-chain message handling
- Message validation and authentication
- Gas optimization for cross-chain operations

**`EmergencyControls.sol`**
- Circuit breakers and emergency pause functionality
- Multi-sig controls for critical operations
- Upgrade mechanisms with timelock delays

### Solana Programs (`/contracts/solana/`)

**`bitlend_solana/src/lib.rs`**
- Main Anchor program for Solana synthetic asset minting
- Cross-chain message verification and processing
- SPL token integration for synthetic assets

**`instructions/mint_synthetic.rs`**
- Handles synthetic asset minting on Solana
- Validates cross-chain collateral commitments
- Implements proper PDA (Program Derived Address) patterns

**`instructions/cross_chain_verify.rs`**
- Verifies Chainlink CCIP messages from Stacks
- Signature validation and replay protection
- State synchronization with Bitcoin collateral

### Frontend Integration (`/frontend/`)

**Key Components:**
- **Stacks Wallet Integration**: Connect.js for Bitcoin/Stacks wallets
- **Multi-Chain UI**: Unified interface for cross-chain operations
- **Real-Time Monitoring**: Position health, collateral ratios, liquidation alerts
- **Transaction Batching**: Optimize cross-chain operation costs

## 🔒 Security Features

- **Time-locked governance** for protocol changes
- **Multi-signature controls** for emergency functions
- **Comprehensive test coverage** (targeting 95%+)
- **Formal verification** for critical contract functions
- **Bug bounty program** (coming with mainnet)

## 🗺️ Roadmap

**Phase 1 (Current)**: Core Bitcoin collateral + Ethereum synthetic assets
**Phase 2**: Expand to Solana, Polygon, Arbitrum
**Phase 3**: Flash loans, yield optimization, governance token
**Phase 4**: Mobile app, institutional features

## 🤝 Contributing

This is a solo project that needs community help! Areas where contributions are most valuable:

- **Smart contract optimization** and gas improvements
- **Frontend UX/UI** enhancements and mobile responsiveness  
- **Security reviews** and formal verification assistance
- **Documentation** improvements and tutorial creation
- **Integration ideas** for new chains and protocols

## 📞 Support & Community

- **Issues**: GitHub Issues for bugs and feature requests
- **Discussions**: GitHub Discussions for general questions

## ⚠️ Disclaimer

BitLend is experimental software under active development. Use testnet funds only. Mainnet deployment will occur after comprehensive security audits and community testing.

---

*Built with ❤️, Bitcoin maximalism, and the belief that DeFi should work for everyone*

**Live Demo**: [coming soon]  
**Documentation**: [Coming Soon]  
**Audit Reports**: [Pending Mainnet]
