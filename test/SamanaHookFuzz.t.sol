// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SamanaHookTestBase} from "./SamanaHookTestBase.sol";
import {SamanaHookHarness} from "./SamanaHook.t.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract SamanaHookFuzzTest is SamanaHookTestBase {
    SamanaHookHarness harness;

    function setUp() public override {
        super.setUp();
        address harnessAddr = address(FLAGS | (uint160(1) << 15));
        deployCodeTo("SamanaHook.t.sol:SamanaHookHarness", abi.encode(address(manager), address(this)), harnessAddr);
        harness = SamanaHookHarness(harnessAddr);
    }

    // IL is symmetric: IL(a→b) ≈ IL(b→a) within 1 bps from integer division.
    // Capped at ±500_000 ticks: beyond that sqrtR² / Q96 overflows uint256
    // (unreachable in any real market — requires a ~2^79× price move).
    function test_computeILBps_symmetric(int256 tickA, int256 tickB) public view {
        tickA = bound(tickA, -500_000, 500_000);
        tickB = bound(tickB, -500_000, 500_000);
        uint160 a = TickMath.getSqrtPriceAtTick(int24(tickA));
        uint160 b = TickMath.getSqrtPriceAtTick(int24(tickB));
        assertApproxEqAbs(harness.computeILBps(a, b), harness.computeILBps(b, a), 1);
    }

    // After one LP qualifies, budget decreases by exactly rewardAmount for any
    // reward size — unit tests only cover the fixed REWARD_AMOUNT = 100e18.
    function test_budget_deductsExactlyOnQualification(uint256 rewardAmount, uint256 extraBudget) public {
        rewardAmount = bound(rewardAmount, 1e15, 1e21);
        extraBudget = bound(extraBudget, 0, 1e22);
        uint256 amount = rewardAmount + extraBudget;
        bountyToken.mint(address(this), amount);

        hook.createBounty(poolKey, rewardAmount, MIN_LIQUIDITY, LOCKUP_DURATION, 0, amount);
        (,,,,,, uint256 budgetBefore) = hook.bounties(poolId);

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: int256(MIN_LIQUIDITY), salt: 0}),
            ZERO_BYTES
        );

        (,,,,,, uint256 budgetAfter) = hook.bounties(poolId);
        assertEq(budgetBefore - budgetAfter, rewardAmount);
    }
}
