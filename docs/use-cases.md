# SamanaHook - Use Cases

`budget` rows below are the target reward budget; to land on budget `B` deposit `amount = B / (1 − protocolFeeBps/10000)`.

> **Claim-timing budget principle.** IL is measured at the moment the LP calls `claimReward()`, not at the moment the lockup expires. Because exit price is a TWAP, the LP needs a sustained price deviation (longer than `twapWindow`) to increase their payout after lockup ends. Creators should size the budget for the worst-case sustained IL at any point within a reasonable post-lockup window, not just at lockup expiry.

---

## New pool cold-start

A protocol launches TOKEN/USDC. Price discovery is violent - early trades move the price 30-50%. Fee revenue is near zero. Rational LPs wait for the pool to stabilise, which means thin depth during the most important window.

**Creator:** the protocol or its DAO treasury.

| Parameter | Suggested value | Reasoning |
|---|---|---|
| `rewardAmount` | 200-500 USDC per LP | Enough to offset expected IL at 30-50% price move |
| `minLiquidity` | Target depth / expected LP count | Each LP must contribute a meaningful share |
| `lockupDuration` | 7-30 days | Covers the illiquid discovery window |
| `ilCoverageBps` | 5000-10000 | High IL expected; partial-to-full 1:1 coverage |
| `budget` | `rewardAmount × expected_lp_count × 2` | 2× buffer absorbs IL insurance payout on top of flat rewards |

Expected IL at a 2× price move: ~5.7%. At 3×: ~13.4%. Budget should cover flat rewards plus IL insurance payout at the 90th-percentile price scenario.

---

## Stablecoin / LST depeg defence

A stablecoin or liquid staking token temporarily depegs. The issuer needs depth in the ASSET/USDC pool to absorb arbitrage and accelerate repeg. IL risk is asymmetric: price can spike down sharply and recover slowly.

**Creator:** the issuer's treasury or a DAO emergency multisig.

| Parameter | Suggested value | Reasoning |
|---|---|---|
| `rewardAmount` | 100-300 USDC per LP | Compensates for committing during a high-fear event |
| `minLiquidity` | Depth needed to absorb arbitrage / expected LP count | Each LP must contribute a meaningful share |
| `lockupDuration` | 3-14 days | Short enough to attract LPs who doubt full recovery |
| `ilCoverageBps` | 10000 | Depeg IL can be severe; full 1:1 coverage signals issuer confidence in repeg |
| `budget` | `rewardAmount × n × 3` | IL insurance payout can dominate if depeg is deep; over-fund |

---

## Token unlock event

A large token unlock creates selling pressure on a TOKEN/ETH pool. Depth is needed to prevent a crash. The unlock window is known in advance, so timing is precise.

**Creator:** the foundation, a whale with a large position, or existing LPs who want co-liquidity.

| Parameter | Suggested value | Reasoning |
|---|---|---|
| `rewardAmount` | 150-400 USDC | Unlock IL is moderate but predictable |
| `minLiquidity` | Target depth / expected LP count | Each LP must contribute a meaningful share |
| `lockupDuration` | 1-7 days | Aligned with the unlock distribution schedule |
| `ilCoverageBps` | 0-5000 | Low coverage if unlock is small; higher if supply shock is large |
| `budget` | `rewardAmount × n × 1.5` | IL likely contained; modest buffer sufficient |

A flat bounty (`ilCoverageBps = 0`) works here if the creator wants a fixed cost. IL insurance makes sense only if the unlock size is uncertain.