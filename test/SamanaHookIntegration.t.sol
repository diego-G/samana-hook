// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SamanaHookTestBase} from "./SamanaHookTestBase.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SamanaHook} from "../src/SamanaHook.sol";

/// @notice End-to-end flows covering multi-actor scenarios and the full
///         qualify → lockup → claim lifecycle, including IL insurance paths.
contract SamanaHookIntegrationTest is SamanaHookTestBase {
    function _newRouter() internal returns (PoolModifyLiquidityTest r) {
        r = new PoolModifyLiquidityTest(manager);
        MockERC20(Currency.unwrap(currency0)).approve(address(r), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(r), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // Budget exhaustion with two LPs
    // -------------------------------------------------------------------------

    // First LP claims the only reward; second LP qualifies but budget is gone and
    // receives no reward and no lockup, so can remove immediately.
    function test_budgetExhausted_secondLP_noRewardNoLockup() public {
        hook.createBounty(poolKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 0, REWARD_AMOUNT);

        address lp1 = address(modifyLiquidityRouter);
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);
        assertTrue(_lp(lp1).qualified);
        assertEq(_lp(lp1).pending, REWARD_AMOUNT);
        assertGt(_lp(lp1).lockupEnd, 0, "LP1 locked");

        PoolModifyLiquidityTest router2 = _newRouter();
        router2.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);
        address lp2 = address(router2);
        assertTrue(_lp(lp2).qualified, "LP2 qualified");
        assertEq(_lp(lp2).pending, 0, "no reward: budget exhausted");
        assertEq(_lp(lp2).lockupEnd, 0, "no lockup: budget exhausted");

        // LP2 can remove immediately.
        router2.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    // -------------------------------------------------------------------------
    // Two LPs - full lifecycle
    // -------------------------------------------------------------------------

    // Both LPs qualify, both wait lockup, both claim successfully.
    function test_twoLPs_bothQualify_bothClaim() public {
        _createBounty();

        PoolModifyLiquidityTest router2 = _newRouter();
        address lp1 = address(modifyLiquidityRouter);
        address lp2 = address(router2);

        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);
        router2.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);

        assertEq(_lp(lp1).pending, REWARD_AMOUNT);
        assertEq(_lp(lp2).pending, REWARD_AMOUNT);
        assertGt(_lp(lp1).lockupEnd, 0);
        assertGt(_lp(lp2).lockupEnd, 0);
        (,,,,,, uint256 budget) = hook.bounties(poolId);
        assertEq(budget, BOUNTY_BUDGET - 2 * REWARD_AMOUNT);

        vm.warp(block.timestamp + LOCKUP_DURATION + 1);

        uint256 lp1Before = bountyToken.balanceOf(lp1);
        vm.prank(lp1);
        hook.claimReward(poolKey);
        assertEq(bountyToken.balanceOf(lp1), lp1Before + REWARD_AMOUNT);
        assertEq(_lp(lp1).pending, 0);

        uint256 lp2Before = bountyToken.balanceOf(lp2);
        vm.prank(lp2);
        hook.claimReward(poolKey);
        assertEq(bountyToken.balanceOf(lp2), lp2Before + REWARD_AMOUNT);
        assertEq(_lp(lp2).pending, 0);
    }

    // -------------------------------------------------------------------------
    // Deactivation → claim lifecycle
    // -------------------------------------------------------------------------

    // Creator deactivates after LP qualifies; LP can still claim after lockup expires.
    function test_deactivateBounty_lpCanClaimAfterDeactivation() public {
        _createBounty();
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);
        assertEq(_lp(address(modifyLiquidityRouter)).pending, REWARD_AMOUNT);

        hook.deactivateBounty(poolKey, address(this));
        (, bool active,,,,,) = hook.bounties(poolId);
        assertFalse(active);

        vm.warp(block.timestamp + LOCKUP_DURATION + 1);

        address lp = address(modifyLiquidityRouter);
        uint256 balBefore = bountyToken.balanceOf(lp);
        vm.prank(lp);
        hook.claimReward(poolKey);
        assertEq(bountyToken.balanceOf(lp), balBefore + REWARD_AMOUNT);
        assertEq(_lp(lp).pending, 0);
    }

    // -------------------------------------------------------------------------
    // IL insurance - full lifecycle
    // -------------------------------------------------------------------------

    // Price moves after qualification → LP suffers IL → claimReward pays base + payout.
    function test_ilInsurance_paidWhenPriceMoves() public {
        hook.createBounty(poolKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 10000, BOUNTY_BUDGET * 2);

        // Wide liquidity gives the swap room to move the price.
        _newRouter().modifyLiquidity(poolKey, _wideLiquidityParams(), ZERO_BYTES);

        modifyLiquidityRouter.modifyLiquidity(poolKey, _wideLiquidityParams(), ZERO_BYTES);

        swap(poolKey, true, -1000e18, ZERO_BYTES);

        vm.warp(block.timestamp + LOCKUP_DURATION + 1);

        uint256 balBefore = bountyToken.balanceOf(address(modifyLiquidityRouter));
        vm.expectEmit(true, true, false, false, address(hook));
        emit SamanaHook.ILInsurancePaid(poolId, address(modifyLiquidityRouter), 0, 0);
        vm.prank(address(modifyLiquidityRouter));
        hook.claimReward(poolKey);

        assertGt(
            bountyToken.balanceOf(address(modifyLiquidityRouter)) - balBefore,
            REWARD_AMOUNT,
            "IL insurance must increase payout when price moved"
        );
    }

    // Budget covers exactly the base reward; IL insurance draw is capped to zero.
    function test_ilInsurance_cappedByBudget() public {
        _newRouter().modifyLiquidity(poolKey, _wideLiquidityParams(), ZERO_BYTES);

        hook.createBounty(poolKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 10000, REWARD_AMOUNT);
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);

        swap(poolKey, true, -1000e18, ZERO_BYTES);

        vm.warp(block.timestamp + LOCKUP_DURATION + 1);

        uint256 balBefore = bountyToken.balanceOf(address(modifyLiquidityRouter));
        vm.prank(address(modifyLiquidityRouter));
        hook.claimReward(poolKey);

        assertEq(
            bountyToken.balanceOf(address(modifyLiquidityRouter)) - balBefore,
            REWARD_AMOUNT,
            "payout capped at base when budget exhausted"
        );
    }

    // After base reward deduction, only 1 wei remains in budget. Computed IL payout >> 1 wei
    // so the payout cap triggers: payout = available. LP receives base + 1.
    function test_ilInsurance_payoutCappedToRemainingBudget() public {
        uint256 budgetRemainder = 1;
        _newRouter().modifyLiquidity(poolKey, _wideLiquidityParams(), ZERO_BYTES);

        hook.createBounty(
            poolKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 10000, REWARD_AMOUNT + budgetRemainder
        );
        modifyLiquidityRouter.modifyLiquidity(poolKey, _wideLiquidityParams(), ZERO_BYTES);

        swap(poolKey, true, -1000e18, ZERO_BYTES);

        vm.warp(block.timestamp + LOCKUP_DURATION + 1);

        uint256 balBefore = bountyToken.balanceOf(address(modifyLiquidityRouter));
        vm.expectEmit(true, true, false, false, address(hook));
        emit SamanaHook.ILInsurancePaid(poolId, address(modifyLiquidityRouter), 0, 0);
        vm.prank(address(modifyLiquidityRouter));
        hook.claimReward(poolKey);

        assertEq(
            bountyToken.balanceOf(address(modifyLiquidityRouter)) - balBefore,
            REWARD_AMOUNT + budgetRemainder,
            "IL payout capped to remaining budget remainder"
        );
    }

    function test_claimReward_revertBeforeLockup() public {
        _createBounty();
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);
        assertGt(_lp(address(modifyLiquidityRouter)).lockupEnd, 0, "LP qualified and locked");

        vm.expectRevert(
            abi.encodeWithSelector(
                SamanaHook.LiquidityStillLocked.selector, _lp(address(modifyLiquidityRouter)).lockupEnd
            )
        );
        vm.prank(address(modifyLiquidityRouter));
        hook.claimReward(poolKey);
    }
}
