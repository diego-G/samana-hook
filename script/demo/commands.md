# SamanaHook Demo - Command Cheat Sheet

Commands only. Full context and expected output: [instructions.md](instructions.md).

## Prerequisites

Wallet must be the SamanaHook owner, with Sepolia ETH for gas and at least 30 test USDC.
One-time keystore setup: see [instructions.md](instructions.md).

```bash
export ETH_KEYSTORE_ACCOUNT=samana-owner          # SamanaHook owner
export ETH_PASSWORD=~/.foundry/samana-owner.pwd   # keystore password file
export RPC_URL=https://...                        # Sepolia RPC
export ETH_PRIORITY_GAS_PRICE=2000000000          # 2 gwei tip so txs land next block
```

## Act 1 - Basic lifecycle

### Step 1 - Create bounty

```bash
forge script script/demo/Demo1BountyCreation.s.sol:Demo1BountyCreation --broadcast
```

If the pool is fresh, this run only initializes the pool and prints
`Pool initialized. Bounty NOT created yet.` Wait ~30 seconds, then run the same
command again to create the bounty.

### Step 2 - Qualify an LP

```bash
forge script script/demo/Demo2Qualify.s.sol:Demo2Qualify --broadcast
```

Copy and run the printed export line:

```bash
export LP_ACTOR=0x...
```

### Step 3 - Early claim (expected revert: `LiquidityStillLocked`)

Run immediately after Step 2.

```bash
forge script script/demo/Demo3Claim.s.sol:Demo3Claim --broadcast
```

### Step 4 - Claim after lockup

Wait at least 10 seconds after Step 2.

```bash
forge script script/demo/Demo3Claim.s.sol:Demo3Claim --broadcast
```

## Act 2 - Budget rules

### Step 5 - Second LP qualifies

```bash
forge script script/demo/Demo2Qualify.s.sol:Demo2Qualify --broadcast
```

```bash
export LP_ACTOR=0x...   # from output
```

### Step 6 - Third LP: budget exhausted (pending reward = 0)

```bash
forge script script/demo/Demo2Qualify.s.sol:Demo2Qualify --broadcast
```

Do not re-export `LP_ACTOR` here; Step 7 claims for the second LP from Step 5.

### Step 7 - Claim second LP's reward

Wait at least 10 seconds after Step 5.

```bash
forge script script/demo/Demo3Claim.s.sol:Demo3Claim --broadcast
```

### Step 8 - Deactivate and recover unspent budget

```bash
forge script script/demo/Demo4Deactivate.s.sol:Demo4Deactivate --broadcast
```

## Act 3 - IL insurance

### Step 9 - Create bounty with IL coverage

Requires Step 8 first, otherwise reverts with `ActiveBountiesPresent`.

```bash
forge script script/demo/Demo1BountyCreation.s.sol:Demo1BountyCreation --broadcast
```

### Step 10 - Full-range LP qualifies, swap moves price

```bash
forge script script/demo/Demo5ILInsurance.s.sol:Demo5ILInsurance --broadcast
```

```bash
export LP_ACTOR=0x...   # from output
export SWAPPER=0x...    # from output; later Demo5 runs reuse it (one tx less)
```

### Step 11 - Claim base reward + IL insurance payout

Wait at least 10 seconds after Step 10.

```bash
forge script script/demo/Demo3Claim.s.sol:Demo3Claim --broadcast
```

## Reminders

- Re-export `LP_ACTOR` after every Demo2Qualify / Demo5ILInsurance run.
- The revert in Step 3 is intentional, a real on-chain rejection.
- Steps 1, 8, and 9 require the owner wallet.
