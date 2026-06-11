# SamanaHook - Lifecycle

End-to-end IL insurance lifecycle in a self-contained Foundry test: bounty creation, LP qualification, price crash, lockup expiry, claim with IL payout, and budget refund.

## Run

```bash
forge test --match-test test_lifecycle -vv
```

Source: [test/SamanaHookLifecycle.t.sol](../test/SamanaHookLifecycle.t.sol)

## Expected output

Numbers reflect a large simulated price dump; actual IL varies with swap depth.

```
================================================================
  SAMANA HOOK -- IL INSURANCE DEMO
================================================================
  Scenario: cold-start pool launch.
  Protocol funds IL insurance to attract LPs during volatile
  price discovery. LPs who commit capital and bear IL are
  compensated beyond swap fees.

----------------------------------------------------------------
  ACT 1: PROTOCOL CREATES BOUNTY
----------------------------------------------------------------
  Deposit          : 1000 USDC
  Protocol fee 1%  : 10 USDC -> treasury
  Net budget       : 990 USDC
  Reward per LP    : 100 USDC (flat base)
  IL coverage      : 100% (1:1 full coverage)
  Lockup           : 7 days

----------------------------------------------------------------
  ACT 2: LP ADDS LIQUIDITY
----------------------------------------------------------------
  LP qualified     : true
  Reward credited  : 100 USDC (pending)
  Locked until     : 7d
  Entry price      : 1.000 token1/token0 (spot; 30-min TWAP in production)
  Budget remaining : 890 USDC

----------------------------------------------------------------
  ACT 3: PRICE CRASHES
----------------------------------------------------------------
  Token dump: large sell into pool ...
  Pool price now   : 0.008 token1/token0 (was 1.000)
  LP position is in IL. Insurance will pay out at claim.

----------------------------------------------------------------
  ACT 4: 7-DAY LOCKUP EXPIRES
----------------------------------------------------------------
  Time             : 7d after
  LP can now remove liquidity and claim reward.

----------------------------------------------------------------
  ACT 5: LP CLAIMS REWARD + IL INSURANCE
----------------------------------------------------------------
  Exit price       : 0.008 token1/token0 (30-min TWAP in production)
  Base reward      : 100 USDC
  IL insurance     : 81 USDC
  Total received   : 181 USDC
  Budget remaining : 808 USDC

----------------------------------------------------------------
  ACT 6: CREATOR DEACTIVATES BOUNTY
----------------------------------------------------------------
  Refunded         : 808 USDC -> creator
  Treasury         : 10 USDC (protocol fee)

================================================================
  SUMMARY
================================================================
  Creator deposited: 1000 USDC
  Creator refunded : 808 USDC
  Creator net cost : 191 USDC
  LP earned        : 181 USDC (base + IL insurance)
  Protocol earned  : 10 USDC
================================================================
```

> [!NOTE]
> The demo uses spot price (`twapWindow=0`) so no block history is needed. In production the default 30-minute TWAP is manipulation-resistant: a flash loan or single-block swap cannot skew either the entry or exit price measurement.
