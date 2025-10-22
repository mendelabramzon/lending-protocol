# Yield-Bearing Collateral Lending Protocol

A production-ready lending protocol that accepts yield-bearing tokens (wstETH, rETH) as collateral, featuring MEV-resistant liquidations and comprehensive security safeguards.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Core Components](#core-components)
- [Design Choices](#design-choices)
- [Liquidation Mechanism](#liquidation-mechanism)
- [Security Features](#security-features)
- [Getting Started](#getting-started)
- [Testing](#testing)
- [Deployment](#deployment)

## Overview

This protocol allows users to deposit yield-bearing collateral (such as Lido's wstETH or Rocket Pool's rETH) and borrow a native stablecoin against it. The system automatically benefits from yield accrual, which improves vault health ratios over time without requiring manual updates.

### Key Features

- **Yield-bearing collateral support** - Native integration with wstETH, rETH, and other yield tokens
- **MEV-resistant liquidations** - Commit-reveal auction system prevents front-running
- **Stability Pool fallback** - Ensures liquidations complete even when auctions fail
- **TWAP price protection** - Time-weighted average pricing prevents flash loan manipulation
- **Emergency safeguards** - Circuit breakers and pausability for rapid incident response
- **Gas-optimized** - Efficient storage patterns and batched operations

### Protocol Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| Minimum Collateralization Ratio | 150% | Required for opening/maintaining positions |
| Liquidation Threshold | 120% | Vault becomes liquidatable below this ratio |
| Liquidation Bonus | 5% | Incentive paid to liquidators |
| Liquidation Penalty | 5% | Fee collected by protocol |
| Maximum Single Liquidation | 50% | Prevents cascading liquidations |
| Borrow APR | 5% | Annual interest rate (adjustable) |
| Protocol Fee | 10% | Percentage of interest going to reserves |

## Architecture

The protocol uses a modular architecture with clear separation of concerns:

```
┌─────────────────────────────────────────────────────────────┐
│                         User Layer                          │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                     VaultManager (Core)                     │
│  - Collateral deposits/withdrawals                          │
│  - Debt management (borrow/repay)                           │
│  - Health ratio calculations                                │
│  - Yield accrual tracking                                   │
└─────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        ▼                     ▼                     ▼
┌──────────────┐    ┌──────────────────┐    ┌──────────────┐
│ StableToken  │    │ LiquidationEngine│    │ PriceOracle  │
│              │    │                  │    │              │
│ - Mint/Burn  │    │ - Commit-Reveal  │    │ - Chainlink  │
│ - Access Ctrl│    │ - Batch Auctions │    │ - TWAP       │
└──────────────┘    └──────────────────┘    └──────────────┘
                              │
                              ▼
                    ┌──────────────────┐
                    │  StabilityPool   │
                    │                  │
                    │ - Fallback Liq.  │
                    │ - Debt Absorption│
                    └──────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        ▼                     ▼                     ▼
┌──────────────┐    ┌──────────────────┐    ┌──────────────┐
│WstETHAdapter │    │  RETHAdapter     │    │StETHAdapter  │
│              │    │                  │    │              │
│ - Exchange   │    │ - Exchange       │    │ - Exchange   │
│   Rate Track │    │   Rate Track     │    │   Rate Track │
│ - Slashing   │    │ - Slashing       │    │ - Slashing   │
│   Detection  │    │   Detection      │    │   Detection  │
└──────────────┘    └──────────────────┘    └──────────────┘
```

### Data Flow

1. **Deposit Flow**: User deposits wstETH → VaultManager records collateral → Adapter tracks exchange rate
2. **Borrow Flow**: User requests debt → VaultManager checks health ratio via PriceOracle TWAP → Mints stablecoins
3. **Liquidation Flow**: Health < 120% → Liquidator commits bid → Reveals after delay → Winner executes → Collateral transferred
4. **Fallback Flow**: Auction times out → LiquidationEngine triggers StabilityPool → Debt absorbed → Collateral distributed

## Core Components

### VaultManager

The central contract managing collateralized debt positions (CDPs). Each user has a vault containing:
- Collateral amount (in yield-bearing tokens)
- Debt amount (in stablecoins)
- Last accrual timestamp
- Last exchange rate (for yield tracking)

**Key Functions:**
- `depositCollateral()` - Add collateral to vault
- `withdrawCollateral()` - Remove collateral (must maintain 150% ratio)
- `borrow()` - Mint stablecoins against collateral
- `repay()` - Burn stablecoins to reduce debt
- `accrueYield()` - Update vault with yield gains
- `liquidate()` - Called by LiquidationEngine to seize collateral

**Yield Tracking:**
The VaultManager tracks yield through exchange rates rather than rebasing balances. For wstETH:
- Collateral balance remains constant in storage
- Exchange rate (stETH per wstETH) increases over time
- Price oracle prices the wrapper token directly
- Effective collateral value increases automatically

This approach is gas-efficient and works naturally with non-rebasing wrapped tokens.

### LiquidationEngine

Implements a MEV-resistant commit-reveal auction system for liquidations.

**Auction Phases:**

1. **Commit Phase** (1-20 minutes)
   - Liquidator submits hash of their bid with ETH deposit
   - Deposit requirement: max(0.1 ETH, 0.1% of debt value)
   - Multiple liquidators can commit competing bids

2. **Reveal Phase** (10 minutes after first commit)
   - Liquidators reveal their actual bid parameters
   - Must match committed hash or reveal is rejected
   - Liquidator must have sufficient stablecoin balance

3. **Finalization** (5 minute grace period)
   - Anyone can finalize once reveal period ends
   - Winner selected: lowest collateral requested (best for protocol)
   - Winner receives collateral, losers get deposits refunded
   - Failed reveals forfeit deposits (griefing protection)

4. **Fallback** (30 minutes total timeout)
   - If no valid bids, liquidation routes to StabilityPool
   - Debt absorbed from pool deposits
   - Collateral distributed proportionally to depositors

**Anti-MEV Features:**
- Commit-reveal prevents front-running bid parameters
- Dynamic deposits scale with liquidation size
- Winner selection favors protocol over liquidators
- Griefing protection through deposit slashing

### StabilityPool

Acts as a liquidation backstop and yield source for passive participants.

**Mechanism:**
- Users deposit stablecoins to earn liquidation collateral
- When fallback liquidation occurs:
  - Debt offset from total pool deposits
  - Collateral distributed proportionally to depositors
  - Each depositor's share decreases by loss ratio
  - Collateral gains accumulate separately

**Math:**
Uses a product-based accounting system:
- `P` tracks cumulative loss ratio: `P = P × (1 - debt_loss/total_deposits)`
- Compounded deposit: `initial_deposit × (current_P / snapshot_P)`
- Collateral gains: `deposit × (current_gains_per_unit - snapshot_gains_per_unit)`

This allows efficient O(1) updates regardless of depositor count.

### PriceOracle

Provides manipulation-resistant pricing using Chainlink feeds with TWAP.

**Features:**
- Primary source: Chainlink price feeds
- TWAP calculation: Circular buffer storing 24 observations
- Update cooldown: 5 minutes between observations
- Staleness checks: 1 hour for spot prices, 2 hours for TWAP
- Automatic updates: getPrice() updates TWAP if cooldown elapsed

**Critical Requirement:**
The oracle must price the **wrapper token directly**, not the underlying:
- Use wstETH/USD feed, not stETH/USD
- Wrapper price naturally includes exchange rate appreciation
- Example: wstETH = 1.1 stETH, stETH = $2000 → wstETH price = $2200

This ensures yield automatically improves health ratios without manual intervention.

### Adapters

Adapters abstract away differences between yield-bearing tokens, implementing a common `IYieldToken` interface.

**WstETHAdapter:**
- Tracks stETH per wstETH exchange rate
- Detects slashing events (>5% rate drop)
- Auto-trips circuit breaker on slashing
- Passes through ERC20 operations to underlying wstETH

**Design Rationale:**
Adapters serve two purposes:
1. Uniform interface for VaultManager (can support multiple collateral types)
2. Protocol-specific safety checks (slashing detection for staked ETH)

## Design Choices

### 1. Yield-Bearing Collateral Approach

**Decision:** Price wrapper tokens directly via oracle, track exchange rates for transparency

**Alternatives Considered:**
- Rebasing collateral balances based on exchange rates
- Manual yield claiming and redepositing

**Why This Approach:**
- Gas efficiency: No need to update every vault on yield accrual
- Simplicity: Wrapper token prices naturally include yield
- Safety: No complex rebasing math or overflow risks
- Composability: Works with any non-rebasing wrapped yield token

**Trade-offs:**
- Requires oracle to price wrapper correctly (Chainlink does this)
- Exchange rate tracking adds minor storage overhead
- Users don't see "balance increase" (vault value increases instead)

### 2. Interest Model

**Decision:** Simple fixed APR with 90/10 split (user/protocol)

**Alternatives Considered:**
- Utilization-based rates (Aave/Compound style)
- Zero interest rate (rely on liquidation fees)
- Dynamic rates based on system health

**Why This Approach:**
- Predictable for users (no rate surprises)
- Simple implementation (no complex math)
- Protocol revenue through fees
- Can be upgraded to dynamic model later via governance

**Trade-offs:**
- May not optimize capital efficiency
- Fixed rate might be too high/low in certain market conditions
- Requires governance to adjust rates

### 3. Collateralization Requirements

**Decision:** 150% minimum, 120% liquidation threshold, 50% max liquidation

**Rationale:**

**150% Minimum:**
- Buffer above liquidation threshold
- Protects against moderate price volatility
- Standard in DeFi (Maker uses similar ratios)

**120% Liquidation:**
- 30% cushion before insolvency
- Gives liquidators room for profit
- Accounts for gas costs and slippage

**50% Max Liquidation:**
- Prevents liquidation cascades
- Allows partial recovery for borrowers
- Multiple liquidations give price time to stabilize
- Reduces systemic risk

**Trade-offs:**
- Conservative ratios reduce capital efficiency
- Multiple partial liquidations cost more gas
- Borrowers have lower leverage than some protocols

### 4. Minimum Debt Requirement

**Decision:** 100 stablecoin minimum debt per vault

**Why:**
- Prevents dust attacks (many tiny vaults)
- Makes liquidations economically viable
- Reduces blockchain bloat
- Gas cost floor for liquidators

**Trade-offs:**
- Excludes very small users
- Less democratic than no minimum

## Liquidation Mechanism

### Defense of the Commit-Reveal Auction System

The liquidation mechanism is the most critical and complex part of the protocol. Here's a detailed defense of the chosen approach.

#### Problem Statement

Liquidations must:
1. Execute quickly to protect protocol solvency
2. Be profitable enough to attract liquidators
3. Resist MEV extraction that harms borrowers
4. Handle edge cases (no participation, manipulation)
5. Distribute benefits fairly

Traditional instant liquidation systems (like Compound V2) suffer from:
- Severe front-running (bots extract borrower value)
- Winner-take-all dynamics (single bot monopolizes liquidations)
- Race conditions (gas wars waste resources)
- Poor price discovery (first liquidator wins regardless of bid)

#### Our Approach: Multi-Phase Commit-Reveal Auctions

**Phase 1: Commitment (1-20 minutes)**

Liquidators submit hashed bids with ETH deposits.

**Why commit-reveal?**
- Prevents front-running: Bid parameters are secret
- Enables true competition: Multiple liquidators can participate
- Price discovery: Competition drives better terms for protocol

**Why ETH deposits?**
- Anti-griefing: Prevents spam commits
- Economic alignment: Liquidators have skin in the game
- Dynamic scaling: Larger liquidations require larger deposits (0.1% of debt)

**Why 1-20 minute window?**
- Minimum 1 minute: Prevents instant reveal (defeats MEV resistance)
- Maximum 20 minutes: Expired commits are slashed (encourages reveals)
- Balance: Long enough for competition, short enough for safety

**Phase 2: Reveal (10 minutes)**

Liquidators reveal bid parameters: debt to repay and collateral requested.

**Why 10 minutes?**
- Enough time for multiple reveals to compete
- Not so long that protocol is at risk
- Allows late entrants who committed early

**Bid validation:**
- Must match commitment hash (integrity check)
- Must have stablecoin balance + approval (prevents fake bids)
- Recorded with timestamp (audit trail)

**Phase 3: Finalization (5 minute grace period)**

Winner selected and liquidation executed.

**Winner selection: Lowest collateral requested**

This is a critical design choice. Alternatives:
- Highest debt offered: Could lead to over-liquidation
- Random selection: No incentive to compete
- First-come-first-served: Still has MEV issues

**Why lowest collateral?**
- Minimizes borrower loss
- Maximizes protocol penalty collection
- Incentivizes liquidators to bid aggressively
- Natural price discovery mechanism

**Grace period rationale:**
- Allows coordination time for finalization
- Anyone can finalize (no single point of failure)
- After grace period, still finalizeable (no lockup)

**Phase 4: Fallback (30 minute total timeout)**

If auction fails, StabilityPool absorbs liquidation.

**Why fallback?**
- Protocol safety: Liquidations must complete
- No liquidator risk: Auction failure doesn't harm protocol
- Passive participation: StabilityPool depositors earn without active management

#### Trade-offs and Limitations

**Advantages:**
1. **MEV Resistance**: Commit-reveal prevents front-running
2. **Fair Price Discovery**: Competition drives optimal bids
3. **Reliability**: StabilityPool ensures liquidations complete
4. **Griefing Protection**: Deposits punish malicious behavior
5. **Decentralization**: No privileged liquidators or oracles
6. **Borrower Protection**: Minimizes losses through competition

**Disadvantages:**
1. **Complexity**: More complex than instant liquidations
2. **Latency**: 11-30 minute delay vs instant
3. **Gas Costs**: Multiple transactions (commit, reveal, finalize)
4. **Capital Requirements**: Liquidators need upfront deposits
5. **Coordination**: Someone must call finalize (usually keeper bots)

#### Why The Trade-offs Are Worth It

**1. Latency is Acceptable**

With a 150% minimum ratio and 120% liquidation threshold:
- 30% price drop required for undercollateralization
- Even with 10% daily volatility (extreme), takes 3+ days
- 30 minute liquidation delay is insignificant
- Health ratio checks prevent new borrows during liquidation

**2. Complexity is Manageable**

Complexity lives in the liquidation engine, not user-facing contracts:
- Borrowers interact only with VaultManager (simple)
- Liquidators can use keeper bots (standard in DeFi)
- StabilityPool users are fully passive
- Core logic is well-tested and audited

**3. Better Borrower Experience**

Traditional instant liquidations:
- Borrower loses maximum possible value
- No opportunity to prevent liquidation once started
- MEV bots extract value that could save the position

Commit-reveal auctions:
- Competition minimizes borrower losses
- 1+ minute warning (commit phase visible on-chain)
- Better outcomes through price discovery

**4. Protocol Revenue**

Better liquidation terms mean:
- Higher penalties collected by protocol
- More revenue from liquidation fees
- Stronger protocol reserves for bad debt
- More sustainable tokenomics

**5. Market Efficiency**

The auction system creates a legitimate market for liquidation rights:
- Most efficient liquidators (lowest cost) win
- No MEV rent extraction
- Liquidators compete on execution efficiency, not gas prices
- Resources allocated efficiently

#### Alternative Mechanisms Considered

**Dutch Auctions (Maker/Liquity style):**
- Pro: Simple, instant execution
- Con: Still front-runnable, no true price discovery
- Con: Fixed price curve may not reflect market

**Keeper Liquidations (Compound style):**
- Pro: Very simple, instant
- Con: Severe MEV problems
- Con: Winner-take-all dynamics

**Off-chain Auctions:**
- Pro: Better price discovery
- Con: Centralization risk
- Con: Trust requirements

**Flashbot-style Priority:**
- Pro: Captures MEV for protocol
- Con: Centralization (relies on Flashbots)
- Con: Not chain-agnostic

**On-chain Dutch Auctions with TWAP:**
- Pro: Better MEV resistance than instant
- Con: Still has some front-running
- Con: Price curve design is complex

#### Production Considerations

**Keeper Infrastructure:**

The system requires keeper bots to:
1. Monitor vault health ratios
2. Commit to liquidations quickly
3. Reveal bids before deadline
4. Finalize auctions after reveal period

This is standard in DeFi (Maker, Compound, Aave all use keepers).

**Economic Sustainability:**

For liquidators to participate:
- Profit = (bonus%) × collateral_value - gas_costs - deposit_opportunity_cost
- At 5% bonus and $10k liquidation: $500 profit
- Gas costs ~$50-100 (mainnet), deposit cost ~$2 (0.1 ETH @ 5% APY × 30 min)
- Net profit: ~$400+ per liquidation
- Economically attractive for professional liquidators

**Risk Mitigation:**

The system handles edge cases:
- No liquidators: StabilityPool absorbs debt
- Fake commits: Deposits slashed if no reveal
- Insufficient balance: Bids rejected at finalization
- Auction manipulation: TWAP prevents price manipulation
- Circuit breaker: Extreme events trigger pause

### Liquidation Comparison Table

| Feature | Our System | Maker | Compound | Aave |
|---------|-----------|-------|----------|------|
| MEV Resistance | High (commit-reveal) | Medium (Dutch) | Low (instant) | Medium (Dutch) |
| Latency | 11-30 min | Minutes-Hours | Instant | Minutes |
| Borrower Protection | High (competition) | Medium (curve) | Low | Medium |
| Gas Efficiency | Medium (3 txs) | High (1 tx) | High (1 tx) | Medium |
| Reliability | High (fallback) | High | High | High |
| Complexity | High | Medium | Low | Medium |
| Liquidator Profit | Competitive (5%+) | Competitive | Fixed (8-13%) | Competitive |

## Security Features

### 1. Flash Loan Protection

**TWAP Pricing:**
- All health ratio checks use 1-hour TWAP
- Flash loan attacks cannot manipulate time-weighted prices
- 5-minute cooldown between oracle updates

**Borrow Delay:**
- Minimum 1 block between borrow operations
- Prevents same-transaction borrow-liquidate attacks
- Simple but effective safeguard

### 2. Reentrancy Protection

- OpenZeppelin's `ReentrancyGuard` on all state-changing functions
- Checks-Effects-Interactions pattern throughout
- External calls only after state updates

### 3. Circuit Breakers

**Emergency Guardian:**
- Can instantly pause specific functions
- Owner can pause entire protocol
- Unpause requires owner (prevents guardian abuse)

**Automatic Triggers:**
- Slashing detection in adapters
- Price volatility (>20% change)
- 1-hour cooldown before reset

**What Gets Paused:**
- Withdrawals (prevent bank runs)
- Borrows (prevent new risk)
- Liquidations continue (protect solvency)

### 4. Oracle Safety

**Multiple Checks:**
- Chainlink staleness: 1 hour max age
- Price validity: Must be positive
- TWAP staleness: 2 hour max observation age
- Minimum observations: 2 required for TWAP

**Fallback Behavior:**
- State-changing operations revert if TWAP unavailable
- View functions fall back to spot price (display only)
- Never use stale data for critical operations

### 5. Parameter Bounds

**Hard Limits:**
- APR: Max 20%, max change 5% per update
- Collateral ratio: Constants (150%/120%)
- Liquidation ratio: Max 50% per liquidation
- Min debt: 100 stablecoins (anti-dust)

**Governance Delays:**
- Timelock: 2-day minimum delay
- Grace period: 7 days to execute
- Expiry: 30 days maximum
- Users can exit before changes take effect

### 6. Slashing Protection

**Adapter-level Detection:**
- Monitors exchange rate decreases
- >5% drop triggers circuit breaker
- Automatic pause of withdrawals/borrows
- Prevents cascading liquidations during slashing

**Recovery Process:**
1. Guardian pauses protocol
2. Team assesses damage
3. If needed, adjust oracle prices
4. Resume operations after stabilization

### 7. Economic Safeguards

**Bad Debt Tracking:**
- Protocol tracks undercollateralized debt
- Reserves can cover bad debt
- Transparent accounting of system health

**Protocol Reserves:**
- 10% of all interest income
- 5% penalty from all liquidations
- Can cover shortfalls from slashing or failed liquidations

**Liquidation Cooldown:**
- 10 minutes between liquidations of same vault
- Prevents cascading liquidations
- Allows market stabilization

### 8. Grace Periods

**Interest Accrual Grace:**
- 1-hour grace after interest accrual before liquidation
- Prevents surprise liquidations from accrued interest
- Users have time to add collateral

**Liquidation Cooldown:**
- 10 minutes between liquidations of same vault
- Partial liquidation philosophy gives users chances to recover

## Getting Started

### Prerequisites

- Foundry installed ([installation guide](https://book.getfoundry.sh/getting-started/installation))
- Node.js 16+ (for auxiliary scripts)
- Git

### Installation

```bash
# Clone the repository
git clone https://github.com/mendelabramzon/lending-protocol
cd lending-protocol

# Install dependencies
forge install

# Build contracts
forge build
```

### Local Testing

```bash
# Run all tests
forge test

# Run with verbosity
forge test -vvv

# Run specific test file
forge test --match-path test/unit/VaultManager.t.sol

# Run with gas reporting
forge test --gas-report

# Run fuzz tests
forge test --match-test "testFuzz"

# Run invariant tests
forge test --match-test "invariant"
```

### Test Coverage

```bash
# Generate coverage report
forge coverage

# Generate detailed HTML report
forge coverage --report lcov
genhtml lcov.info -o coverage
open coverage/index.html
```

## Testing

The protocol includes comprehensive test suites:

### Unit Tests (`test/unit/`)

- `VaultManager.t.sol` - Core vault operations
- `LiquidationEngine.t.sol` - Liquidation mechanics
- `StabilityPool.t.sol` - Pool accounting
- `PriceOracle.t.sol` - Price feeds and TWAP
- `StableToken.t.sol` - Token minting/burning
- `EnhancedFeatures.t.sol` - Advanced features

### Fuzz Tests (`test/fuzz/`)

- `VaultManagerFuzz.t.sol` - Randomized vault operations
- `StabilityPoolFuzz.t.sol` - Pool edge cases

### Invariant Tests (`test/invariant/`)

- `ProtocolInvariant.t.sol` - System-wide invariants:
  - Total debt = Sum of vault debts
  - Total collateral = Sum of vault collateral + reserves
  - Token supply = Total debt + reserves - stability pool
  - Solvency: Total collateral value ≥ Total debt (minus bad debt)

### Attack Tests (`test/attack/`)

- `FlashLoanAttack.t.sol` - Flash loan manipulation attempts
- `MEVAttack.t.sol` - Front-running scenarios
- `GriefingAttack.t.sol` - Griefing vectors

### Running Specific Test Suites

```bash
# Unit tests only
forge test --match-path "test/unit/*"

# Fuzz tests with more runs
forge test --match-path "test/fuzz/*" --fuzz-runs 10000

# Invariant tests with more depth
forge test --match-path "test/invariant/*" --invariant-runs 512 --invariant-depth 20

# Attack tests
forge test --match-path "test/attack/*" -vvv
```

## Deployment

### Deployment Scripts

The protocol includes deployment scripts for different environments:

```bash
# Deploy to local anvil
anvil # In separate terminal
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast

# Deploy to testnet
forge script script/DeployTestnet.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify

# Deploy to mainnet (requires confirmation)
forge script script/Deploy.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  --broadcast \
  --verify \
  --slow
```