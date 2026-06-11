# SamanaHook - Demo Instructions

End-to-end walkthrough on Sepolia. Three acts, run in order.

## Deployed contracts

| Contract     | Address |
|--------------|---------|
| PoolManager  | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| SamanaHook   | `0x597cb94f36f8ECA3a450c7f13C237e4D667E9680` |
| USDC (test)  | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` |
| DALPHA       | `0xe24Df7dd2ea0Ed4258EE295dc663F57a2198ed7F` |
| DBETA        | `0xeda8fb2a4b1f00d05bA5aa898562D92Eb18cfdCA` |

## Prerequisites

One-time: import the owner key into an encrypted keystore (prompts for the key and a
password; the key never appears in commands or shell history again):

```bash
cast wallet import samana-owner --interactive
printf '%s' '<keystore password>' > ~/.foundry/samana-owner.pwd
chmod 600 ~/.foundry/samana-owner.pwd
```

Each session:

```bash
export ETH_KEYSTORE_ACCOUNT=samana-owner          # must be SamanaHook owner
export ETH_PASSWORD=~/.foundry/samana-owner.pwd   # keystore password file
export RPC_URL=https://...                        # Sepolia RPC
export ETH_PRIORITY_GAS_PRICE=2000000000          # 2 gwei tip so txs land next block
```

The broadcaster wallet needs:
- Enough Sepolia ETH for gas
- At least 15 test USDC. Act 1's claims, the protocol fee, and the Act 2 refund all return
  to the owner wallet before Act 3, so the same 15 USDC funds both bounties (20 gives margin).

**Pool age requirement:** `createBounty` reverts with `PoolTooYoung` if the pool has less
observation history than the TWAP window (30 seconds, set by Demo1). On a fresh pool, Demo1
runs in two phases: the first run only initializes the pool and exits with
`Pool initialized. Bounty NOT created yet.` Wait ~30 seconds, then run Demo1 again to create
the bounty.

---

## Act 1 - Basic lifecycle (trust the lockup)

### Step 1 - Create bounty

Sets the bounty token to USDC and creates a bounty on the DALPHA/DBETA pool.
- Reward: 5 USDC per qualifying LP
- Budget: 15 USDC deposited (13.5 USDC net after 10% protocol fee)
- Lockup: 10 seconds
- IL coverage: 100% - but only full-range positions snapshot an entry price, so the
  narrow LPs of Acts 1-2 receive the flat reward only

```bash
forge script script/demo/Demo1BountyCreation.s.sol:Demo1BountyCreation --broadcast
```

Expected output:
```
>> Bounty created: 5.000000 USDC per qualifying LP, 13.500000 USDC net budget, room for 2 LPs.
```

### Step 2 - Qualify an LP

Deploys a fresh `LPActor`, mints demo tokens into it, and adds liquidity - triggering qualification on the hook.

```bash
forge script script/demo/Demo2Qualify.s.sol:Demo2Qualify --broadcast
```

Expected output:
```
LPActor: 0x...

>> LP added liquidity and qualified: 5.000000 USDC reserved, lockup started.
Lockup ends at: <unix timestamp>

export LP_ACTOR=0x...
```

Copy and run the printed `export` line:

```bash
export LP_ACTOR=0x...
```

### Step 3 - Attempt early claim (expected revert)

Run immediately after Step 2, before the 10-second lockup expires.

```bash
forge script script/demo/Demo3Claim.s.sol:Demo3Claim --broadcast
```

Expected on-chain revert (not a local check):
```
[FAIL] LiquidityStillLocked(<unlock timestamp>)
```

### Step 4 - Claim after lockup

**Wait at least 10 seconds after Step 2**, then run:

```bash
forge script script/demo/Demo3Claim.s.sol:Demo3Claim --broadcast
```

Expected output:
```
>> Lockup over: LP claimed its reward, 5.000000 USDC received.
```

---

## Act 2 - Budget rules

Continue from Act 1 (bounty still active, one slot remaining).

### Step 5 - Second LP qualifies

```bash
forge script script/demo/Demo2Qualify.s.sol:Demo2Qualify --broadcast
```

Expected: `>> LP added liquidity and qualified: 5.000000 USDC reserved, lockup started.`
Budget now exhausted.

Copy and run the printed `export` line:

```bash
export LP_ACTOR=0x...
```

### Step 6 - Third LP: budget exhausted

```bash
forge script script/demo/Demo2Qualify.s.sol:Demo2Qualify --broadcast
```

Expected output:
```
>> LP added liquidity and qualified, but the budget is depleted:
>> no reward, no lockup. The LP can withdraw its liquidity anytime.
```

The LP is marked as qualified (no further accumulation) but receives no reward and no lockup.
Budget exhaustion is silent - no error, no penalty.

Do not re-export the printed `LP_ACTOR`; Step 7 claims for the second LP from Step 5.

### Step 7 - Claim second LP's reward

**Wait at least 10 seconds after Step 5**, then run:

```bash
forge script script/demo/Demo3Claim.s.sol:Demo3Claim --broadcast
```

Expected output:
```
>> Lockup over: LP claimed its reward, 5.000000 USDC received.
```

### Step 8 - Deactivate and recover unspent budget

```bash
forge script script/demo/Demo4Deactivate.s.sol:Demo4Deactivate --broadcast
```

Expected output:
```
>> Bounty deactivated: 3.500000 USDC of uncommitted budget refunded to the creator.
>> Already-credited LP rewards remain claimable.
```

3.5 USDC returned: 13.5 USDC net budget minus 2 × 5 USDC paid out.

---

## Act 3 - IL insurance

### Step 9 - Create bounty with IL coverage

Requires the bounty from Act 2 to be deactivated (Step 8). Reverts with `ActiveBountiesPresent`
if run while a bounty is still active.

```bash
forge script script/demo/Demo1BountyCreation.s.sol:Demo1BountyCreation --broadcast
```

Same parameters as Act 1; this run replenishes the budget that Act 2 drained. The IL
coverage (100%) finally matters in this act because the next LP is full-range.

### Step 10 - Wide-range LP qualifies, price moves

Adds full-range liquidity (entry price snapshotted), then executes a limit-driven swap that
moves the price exactly 10^6 toward 1:1 - creating near-total IL for the LP regardless of how
much liquidity previous demo runs left in the pool.

```bash
forge script script/demo/Demo5ILInsurance.s.sol:Demo5ILInsurance --broadcast
```

Expected output:
```
>> Wide-range LP qualified: 5.000000 USDC base reserved, entry price snapshotted.
>> A large swap then moved the price: the LP is now deep in IL.
>> After the lockup, the claim pays base + IL insurance.

Entry sqrtPrice (X96): <pool TWAP at qualification>
Lockup ends at:        <unix timestamp>

export LP_ACTOR=0x...
export SWAPPER=0x...
```

Copy and run the printed `export` lines. `LP_ACTOR` is required for Step 11; exporting
`SWAPPER` lets later Demo5 runs reuse the swapper contract instead of deploying a new one
(one tx less per run).

```bash
export LP_ACTOR=0x...
export SWAPPER=0x...
```

### Step 11 - Claim base reward + IL insurance

**Wait at least 10 seconds after Step 10** (the lockup), then run. The exit price is a
30-second TWAP; the longer the post-swap price sits in the window, the higher the measured
IL: ~80% if the claim lands right at the 10-second lockup, ~98% by 20 seconds
(~4.0-4.9 USDC IL payout on top of the 5 USDC base).

```bash
forge script script/demo/Demo3Claim.s.sol:Demo3Claim --broadcast
```

Expected output (payout exceeds base reward):
```
>> Lockup over: LP claimed its reward, 9.4-9.9 USDC received.
```

The excess above 5 USDC is the IL insurance payout, proportional to the price move
(10^6 price ratio -> ~99.8% IL -> ~5 USDC on the 5 USDC base).

---

## Notes

- Steps 1, 8, and 9 require the broadcaster to be the SamanaHook owner.
- `LP_ACTOR` must be exported before running Demo3Claim (Steps 4, 7, 11).
- Demo2Qualify can be run from any wallet; each run creates a distinct `LPActor`.
- The on-chain revert in Step 3 is a real rejected transaction, not a local simulation failure.
- Running Demo1BountyCreation while a bounty is active reverts with `ActiveBountiesPresent` - run Demo4Deactivate first.
