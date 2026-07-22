# UZR Leverage

A smart contract system for recursive leverage and deleverage operations on the UZR Lending Market, with a Next.js frontend interface.

## ⚠️ DISCLAIMER

**EXPERIMENTAL SOFTWARE - USE AT YOUR OWN RISK**

This software is experimental and has not been audited. It is provided "as is" without warranty of any kind. Use of this software may result in financial loss. The authors and contributors are not responsible for any losses, damages, or liabilities that may arise from the use of this software. **You use this software at your own risk.**

## Overview

UZR Leverage automates recursive leverage and deleverage operations on the UZR Lending Market. The system enables users to:

- **Increase leverage** by recursively supplying collateral, borrowing, and swapping tokens
- **Decrease leverage** by repaying debt, withdrawing collateral, and swapping tokens
- **Manage positions** through a web-based interface with real-time position tracking

## Project Structure

```
firaleverage/
├── contract/          # Solidity smart contracts
│   ├── src/
│   │   └── UZRLeverage.sol    # Main leverage contract
│   ├── test/          # Foundry tests
│   └── foundry.toml   # Foundry configuration
├── frontend/          # Next.js frontend application
│   ├── app/           # Next.js app directory
│   ├── components/    # React components
│   └── lib/           # Utilities and contract ABIs
└── README.md          # This file
```

## Key Components

### Smart Contract (`contract/src/UZRLeverage.sol`)

The core contract that handles leverage operations:
- **Leverage (pool route)**: Recursively supplies collateral, borrows at 88% LTV, and swaps USD0→BUSD0
- **Leverage (mint route)**: `leverageFlashMint` — single-tx flashloan + `Usd0PP.mint` at par; the rt-USD0 leg goes to the user's wallet for a later par exit
- **Unleverage**: `unleverageFlash` — single-tx flashloan unwind: repay debt (by shares on full close), withdraw collateral, then convert BUSD0→USD0 at par via `Usd0PP.reconstruct` (bUSD0 + rt-USD0 → USD0) for up to the user's rt-USD0, selling only the remainder on the pool or at the Usd0PP floor price
- **Quoter**: `UZRUnwindQuoter` lens simulates the pool leg (vendored V3 swap simulator) to compute `minUsd0Out` and pick the better remainder exit
- **Integration**: Uses Uniswap Universal Router V4 for leverage swaps via Permit2, direct pool swaps for the unwind, and the UZR lending market's free flashloan

### Frontend (`frontend/`)

A Next.js web application with:
- **Wallet Connection**: Support for injected wallets (Rabby, MetaMask, etc.)
- **Contract Deployment**: Deploy UZRLeverage contracts directly from the UI
- **Leverage Controls**: Execute leverage/unleverage operations with configurable iterations
- **Position Tracking**: Real-time display of user positions, balances, and health factors
- **Authorization**: Manage contract authorizations on the lending market

## Features

- ✅ Recursive leverage operations with configurable iterations
- ✅ Single-transaction flashloan deleverage (full or partial, zero debt dust)
- ✅ Par exits via bUSD0 + rt-USD0 reconstruction (no pool fee/slippage on the rt-covered part)
- ✅ Mint-based leverage that stockpiles rt-USD0 for pool-friction-free round trips
- ✅ Automatic token swaps via Uniswap V4
- ✅ Real-time position tracking and balances
- ✅ Slippage protection on swaps (quoted `minUsd0Out` on unwind)
- ✅ User-friendly web interface with futuristic dark theme
- ✅ Contract authorization management

## Quick Start

### Prerequisites

- Node.js 18+
- Foundry (for contract development)
- Web3 wallet (Rabby, MetaMask, etc.)
- Access to Ethereum Mainnet

### Contract

```bash
cd contract
forge build
forge test
```

### Frontend

```bash
cd frontend
npm install
npm run dev
```

See the [contract documentation](contract/UZRLeverage.md) and [frontend README](frontend/README.md) for detailed setup instructions.

## Technical Details

- **Solidity**: 0.8.30
- **Frontend**: Next.js 14, React, TypeScript, Tailwind CSS
- **Web3**: Wagmi, Viem
- **Testing**: Foundry
- **Network**: Ethereum Mainnet

## Market Configuration

- **Collateral Token**: BUSD0
- **Loan Token**: USD0
- **LTV**: 88% (0.88)
- **Liquidation LTV**: 99.99% (0.9999)
- **Uniswap Pool Fee**: 0.01% (100)

## Security Considerations

- This software is **experimental and unaudited**
- Always verify contract addresses before use
- Review all transactions carefully
- Be aware of liquidation risks when using leverage
- Interest accrues on borrowed amounts, increasing debt over time

## License

See individual component licenses for details.

## Links

- Contract Documentation: [contract/UZRLeverage.md](contract/UZRLeverage.md)
- Frontend Documentation: [frontend/README.md](frontend/README.md)
