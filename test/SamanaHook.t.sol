// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SamanaHookTestBase} from "./SamanaHookTestBase.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SamanaHook} from "../src/SamanaHook.sol";

// Exposes internal IL math for unit testing without touching the pool.
contract SamanaHookHarness is SamanaHook {
    constructor(IPoolManager pm, address owner) SamanaHook(pm, owner) {}

    function computeILBps(uint160 entry, uint160 exit_) external pure returns (uint256) {
        return _computeILBps(entry, exit_);
    }
}

contract SamanaHookTest is SamanaHookTestBase {
    // -------------------------------------------------------------------------
    // createBounty
    // -------------------------------------------------------------------------

    function test_createBounty() public {
        hook.createBounty(poolKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 0, BOUNTY_BUDGET);

        (address creator, bool active, uint256 ra, uint256 ml, uint256 ld,, uint256 budget) = hook.bounties(poolId);
        assertEq(creator, address(this));
        assertEq(ra, REWARD_AMOUNT);
        assertEq(ml, MIN_LIQUIDITY);
        assertEq(ld, LOCKUP_DURATION);
        assertEq(budget, BOUNTY_BUDGET);
        assertTrue(active);
        assertEq(bountyToken.balanceOf(address(hook)), BOUNTY_BUDGET);
    }

    function test_createBounty_emitsBountyCreated() public {
        vm.expectEmit(true, true, false, true, address(hook));
        emit SamanaHook.BountyCreated(
            poolId, address(this), REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 0, BOUNTY_BUDGET
        );
        hook.createBounty(poolKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 0, BOUNTY_BUDGET);
    }

    function test_createBounty_storesIlCoverageBps() public {
        hook.createBounty(poolKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 7500, BOUNTY_BUDGET);
        (,,,,, uint256 ilCoverageBps,) = hook.bounties(poolId);
        assertEq(ilCoverageBps, 7500);
    }

    function test_createBounty_maxLockup_succeeds() public {
        hook.createBounty(poolKey, REWARD_AMOUNT, MIN_LIQUIDITY, hook.MAX_LOCKUP(), 0, BOUNTY_BUDGET);
        (,,, uint256 ml, uint256 ld,,) = hook.bounties(poolId);
        assertEq(ml, MIN_LIQUIDITY);
        assertEq(ld, hook.MAX_LOCKUP());
    }

    function test_createBounty_reverts_alreadyExists() public {
        _createBounty();
        vm.expectRevert(SamanaHook.BountyAlreadyExists.selector);
        hook.createBounty(poolKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 0, BOUNTY_BUDGET);
    }

    function test_createBounty_reverts_zeroReward() public {
        vm.expectRevert(SamanaHook.ZeroRewardAmount.selector);
        hook.createBounty(poolKey, 0, MIN_LIQUIDITY, LOCKUP_DURATION, 0, BOUNTY_BUDGET);
    }

    function test_createBounty_reverts_insufficientBudget() public {
        vm.expectRevert(SamanaHook.InsufficientBudget.selector);
        hook.createBounty(poolKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 0, REWARD_AMOUNT - 1);
    }

    // Exact boundary: MAX_LOCKUP passes (tested above); MAX_LOCKUP + 1 is the first rejected value.
    function test_createBounty_reverts_lockupTooLong() public {
        // Cache before arming expectRevert - an inline hook.MAX_LOCKUP() would be the next
        // (non-reverting) call and consume the expectRevert.
        uint256 tooLong = hook.MAX_LOCKUP() + 1;
        vm.expectRevert(SamanaHook.LockupTooLong.selector);
        hook.createBounty(poolKey, REWARD_AMOUNT, MIN_LIQUIDITY, tooLong, 0, BOUNTY_BUDGET);
    }

    function test_createBounty_reverts_invalidPoolKey() public {
        PoolKey memory badKey = poolKey;
        badKey.hooks = IHooks(address(0xDEAD));
        vm.expectRevert(SamanaHook.InvalidPoolKey.selector);
        hook.createBounty(badKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 0, BOUNTY_BUDGET);
    }

    // Pool initialized in this test at the current timestamp (after setUp warp); elapsed=0 < twapWindow.
    function test_createBounty_reverts_poolTooYoung() public {
        PoolKey memory freshKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 500, tickSpacing: 10, hooks: IHooks(address(hook))
        });
        manager.initialize(freshKey, SQRT_PRICE_1_1);

        vm.expectRevert(SamanaHook.PoolTooYoung.selector);
        hook.createBounty(freshKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 0, BOUNTY_BUDGET);
    }

    // Pool never initialized: afterInitialize never ran, so the observation ring buffer
    // is empty (cardinality=0) and bounty creation is blocked before any funds move.
    function test_createBounty_reverts_poolTooYoung_uninitializedPool() public {
        PoolKey memory freshKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 500, tickSpacing: 10, hooks: IHooks(address(hook))
        });

        vm.expectRevert(SamanaHook.PoolTooYoung.selector);
        hook.createBounty(freshKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 0, BOUNTY_BUDGET);
    }

    // Exactly twapWindow seconds after initialization the check passes (boundary: elapsed == twapWindow).
    function test_createBounty_passesAtTwapWindowBoundary() public {
        PoolKey memory freshKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 500, tickSpacing: 10, hooks: IHooks(address(hook))
        });
        manager.initialize(freshKey, SQRT_PRICE_1_1);

        vm.warp(block.timestamp + hook.twapWindow());
        hook.createBounty(freshKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 0, BOUNTY_BUDGET);

        (, bool active,,,,,) = hook.bounties(freshKey.toId());
        assertTrue(active);
    }

    // twapWindow=0 disables both the age gate and TWAP; bounty creation on a brand-new pool succeeds.
    function test_createBounty_poolAgeCheck_skippedWhenTwapWindowZero() public {
        hook.setTwapWindow(0);

        PoolKey memory freshKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 500, tickSpacing: 10, hooks: IHooks(address(hook))
        });
        manager.initialize(freshKey, SQRT_PRICE_1_1);

        hook.createBounty(freshKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 0, BOUNTY_BUDGET);

        (, bool active,,,,,) = hook.bounties(freshKey.toId());
        assertTrue(active);
    }

    function test_createBounty_reverts_whenBountyTokenUnset() public {
        // Fresh hook instance with bountyToken never set - avoids brittle storage-slot poking.
        // Same low bits as FLAGS (so permissions match); high bit differs to get a distinct address.
        address freshAddr = address(uint160(FLAGS) | (uint160(1) << 15));
        deployCodeTo("SamanaHook.sol:SamanaHook", abi.encode(address(manager), address(this)), freshAddr);
        SamanaHook freshHook = SamanaHook(freshAddr);

        PoolKey memory freshKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(freshAddr)});

        // Initialize the pool and age it past twapWindow so the pool-age gate is cleared
        // before the ZeroBountyToken check fires (from _receiveFunds).
        manager.initialize(freshKey, SQRT_PRICE_1_1);
        vm.warp(block.timestamp + freshHook.twapWindow());

        vm.expectRevert(SamanaHook.ZeroBountyToken.selector);
        freshHook.createBounty(freshKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 0, BOUNTY_BUDGET);
    }

    function test_createBounty_reverts_whenTreasuryUnset() public {
        hook.setProtocolFeeBps(100);

        vm.expectRevert(SamanaHook.ZeroTreasury.selector);
        hook.createBounty(poolKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 0, BOUNTY_BUDGET);
    }

    function test_createBounty_doesNotCollectFee_whenFeeRoundsToZero() public {
        hook.setTreasury(address(0xBEEF));
        hook.setProtocolFeeBps(1);
        // amount=1, feeBps=1 → mulDiv(1,1,10000)=0
        bountyToken.mint(address(this), 1);
        hook.createBounty(poolKey, 1, MIN_LIQUIDITY, LOCKUP_DURATION, 0, 1);

        assertEq(bountyToken.balanceOf(address(0xBEEF)), 0);
        (,,,,,, uint256 budget) = hook.bounties(poolId);
        assertEq(budget, 1);
    }

    function test_createBounty_feeTakenToTreasury() public {
        address treasury = address(0xBEEF);
        hook.setTreasury(treasury);
        hook.setProtocolFeeBps(100); // 1%

        hook.createBounty(poolKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 0, BOUNTY_BUDGET);

        uint256 fee = BOUNTY_BUDGET / 100;
        uint256 budget = BOUNTY_BUDGET - fee;
        (,,,,,, uint256 storedBudget) = hook.bounties(poolId);
        assertEq(storedBudget, budget);
        assertEq(bountyToken.balanceOf(treasury), fee);
        assertEq(bountyToken.balanceOf(address(hook)), budget);
    }

    // -------------------------------------------------------------------------
    // fundBounty
    // -------------------------------------------------------------------------

    function test_fundBounty() public {
        _createBounty();
        uint256 extra = 50e18;
        hook.fundBounty(poolKey, extra);

        (,,,,,, uint256 budget) = hook.bounties(poolId);
        assertEq(budget, BOUNTY_BUDGET + extra);
    }

    function test_fundBounty_feeTakenToTreasury() public {
        address treasury = address(0xBEEF);
        hook.setTreasury(treasury);
        hook.setProtocolFeeBps(100); // 1%

        hook.createBounty(poolKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 0, BOUNTY_BUDGET);

        uint256 extra = 50e18;
        hook.fundBounty(poolKey, extra);

        uint256 fee1 = BOUNTY_BUDGET / 100;
        uint256 fee2 = extra / 100;
        (,,,,,, uint256 budget) = hook.bounties(poolId);
        assertEq(budget, (BOUNTY_BUDGET - fee1) + (extra - fee2));
        assertEq(bountyToken.balanceOf(treasury), fee1 + fee2);
    }

    function test_fundBounty_reverts_noBounty() public {
        vm.expectRevert(SamanaHook.BountyNotActive.selector);
        hook.fundBounty(poolKey, 100e18);
    }

    function test_fundBounty_reverts_zeroAmount() public {
        _createBounty();
        vm.expectRevert(SamanaHook.ZeroFundAmount.selector);
        hook.fundBounty(poolKey, 0);
    }

    // -------------------------------------------------------------------------
    // deactivateBounty
    // -------------------------------------------------------------------------

    function test_deactivateBounty_byCreator() public {
        _createBounty();
        uint256 balBefore = bountyToken.balanceOf(address(this));

        hook.deactivateBounty(poolKey, address(this));

        assertEq(bountyToken.balanceOf(address(this)), balBefore + BOUNTY_BUDGET);
        (, bool active,,,,,) = hook.bounties(poolId);
        assertFalse(active);
    }

    function test_deactivateBounty_byOwner_refundsToCreator() public {
        address creator = address(0xCAFE);
        bountyToken.mint(creator, BOUNTY_BUDGET);
        vm.startPrank(creator);
        bountyToken.approve(address(hook), type(uint256).max);
        hook.createBounty(poolKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 0, BOUNTY_BUDGET);
        vm.stopPrank();

        uint256 creatorBalBefore = bountyToken.balanceOf(creator);
        uint256 ownerBalBefore = bountyToken.balanceOf(address(this));
        // `to` param is ignored when owner calls - refund always goes to creator
        hook.deactivateBounty(poolKey, address(this));
        assertEq(bountyToken.balanceOf(creator), creatorBalBefore + BOUNTY_BUDGET);
        assertEq(bountyToken.balanceOf(address(this)), ownerBalBefore);
    }

    // budget=0 when all rewards have been paid out - deactivate must not transfer.
    function test_deactivateBounty_zeroBudget_noTransfer() public {
        hook.createBounty(poolKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 0, REWARD_AMOUNT);
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);

        (,,,,,, uint256 budget) = hook.bounties(poolId);
        assertEq(budget, 0, "budget exhausted");

        uint256 balBefore = bountyToken.balanceOf(address(this));
        hook.deactivateBounty(poolKey, address(this));
        assertEq(bountyToken.balanceOf(address(this)), balBefore, "no transfer when budget=0");

        (, bool active,,,,,) = hook.bounties(poolId);
        assertFalse(active);
    }

    function test_deactivateBounty_allowsNewBounty() public {
        _createBounty();
        hook.deactivateBounty(poolKey, address(this));

        hook.createBounty(poolKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 0, BOUNTY_BUDGET);
        (, bool active,,,,,) = hook.bounties(poolId);
        assertTrue(active);
    }

    function test_deactivateBounty_reverts_unauthorized() public {
        address creator = address(0xCAFE);
        bountyToken.mint(creator, BOUNTY_BUDGET);
        vm.startPrank(creator);
        bountyToken.approve(address(hook), type(uint256).max);
        hook.createBounty(poolKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 0, BOUNTY_BUDGET);
        vm.stopPrank();

        vm.prank(address(0xBEEF));
        vm.expectRevert(SamanaHook.Unauthorized.selector);
        hook.deactivateBounty(poolKey, address(0xBEEF));
    }

    function test_deactivateBounty_reverts_alreadyInactive() public {
        _createBounty();
        hook.deactivateBounty(poolKey, address(this));

        vm.expectRevert(SamanaHook.BountyNotActive.selector);
        hook.deactivateBounty(poolKey, address(this));
    }

    // -------------------------------------------------------------------------
    // Owner setters
    // -------------------------------------------------------------------------

    function test_setProtocolFeeBps_reverts_whenFeeTooHigh() public {
        vm.expectRevert(SamanaHook.InvalidFeeBps.selector);
        hook.setProtocolFeeBps(1001);
    }

    // Owner-gated setters touch funds routing - non-owner must be rejected.
    function test_setBountyToken_reverts_whenNotOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        hook.setBountyToken(address(0xDEAD));
    }

    function test_setTreasury_reverts_whenNotOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        hook.setTreasury(address(0xBEEF));
    }

    function test_setProtocolFeeBps_reverts_whenNotOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        hook.setProtocolFeeBps(100);
    }

    function test_setTwapWindow_updatesValue() public {
        hook.setTwapWindow(3600);
        assertEq(hook.twapWindow(), 3600);
    }

    function test_setTwapWindow_zero_disablesTwap() public {
        hook.setTwapWindow(0);
        assertEq(hook.twapWindow(), 0);
    }

    function test_setTwapWindow_reverts_whenNotOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        hook.setTwapWindow(0);
    }

    function test_setTwapWindow_reverts_whenBountyActive() public {
        _createBounty();
        vm.expectRevert(SamanaHook.ActiveBountiesPresent.selector);
        hook.setTwapWindow(0);
    }

    function test_setters_revertWhenBountyActive() public {
        hook.setTreasury(address(0xBEEF));
        hook.setProtocolFeeBps(100);
        // bountyToken already set in setUp

        hook.createBounty(poolKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 0, BOUNTY_BUDGET);

        vm.expectRevert(SamanaHook.ActiveBountiesPresent.selector);
        hook.setProtocolFeeBps(50);

        vm.expectRevert(SamanaHook.ActiveBountiesPresent.selector);
        hook.setTreasury(address(0xCAFE));

        vm.expectRevert(SamanaHook.ActiveBountiesPresent.selector);
        hook.setBountyToken(address(0xDEAD));

        vm.expectRevert(SamanaHook.ActiveBountiesPresent.selector);
        hook.setTwapWindow(0);
    }

    function test_setters_succeedAfterDeactivation() public {
        _createBounty();
        hook.deactivateBounty(poolKey, address(this));

        // All setters should succeed once no bounties are active.
        hook.setTwapWindow(3600);
        hook.setProtocolFeeBps(50);
        hook.setTreasury(address(0xCAFE));
        hook.setBountyToken(address(0xDEAD));
    }

    // -------------------------------------------------------------------------
    // afterAddLiquidity - reward and lockup
    // -------------------------------------------------------------------------

    function test_addLiquidity_noBounty_noRewardNoLockup() public {
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);

        assertEq(_lp(address(modifyLiquidityRouter)).pending, 0);
        assertEq(_lp(address(modifyLiquidityRouter)).lockupEnd, 0);
    }

    function test_addLiquidity_belowThreshold_noReward() public {
        _createBounty();

        ModifyLiquidityParams memory small = ModifyLiquidityParams({
            tickLower: -120, tickUpper: 120, liquidityDelta: int256(MIN_LIQUIDITY / 2), salt: 0
        });
        modifyLiquidityRouter.modifyLiquidity(poolKey, small, ZERO_BYTES);

        assertEq(_lp(address(modifyLiquidityRouter)).pending, 0, "no reward below threshold");
        assertFalse(_lp(address(modifyLiquidityRouter)).qualified);
    }

    // Adds in two chunks - net liquidity accumulates across calls.
    function test_addLiquidity_cumulativeTracking() public {
        _createBounty();

        ModifyLiquidityParams memory half = ModifyLiquidityParams({
            tickLower: -120, tickUpper: 120, liquidityDelta: int256(MIN_LIQUIDITY / 2), salt: 0
        });

        modifyLiquidityRouter.modifyLiquidity(poolKey, half, ZERO_BYTES);
        assertFalse(_lp(address(modifyLiquidityRouter)).qualified);

        modifyLiquidityRouter.modifyLiquidity(poolKey, half, ZERO_BYTES);
        assertTrue(_lp(address(modifyLiquidityRouter)).qualified);
    }

    function test_addLiquidity_aboveThreshold_rewardAccrued() public {
        _createBounty();
        uint256 hookBalBefore = bountyToken.balanceOf(address(hook));

        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);

        (,,,,,, uint256 budget) = hook.bounties(poolId);
        assertEq(budget, BOUNTY_BUDGET - REWARD_AMOUNT);
        assertEq(_lp(address(modifyLiquidityRouter)).pending, REWARD_AMOUNT);
        assertEq(bountyToken.balanceOf(address(hook)), hookBalBefore, "tokens stay in hook until claimed");
        assertTrue(_lp(address(modifyLiquidityRouter)).qualified);
    }

    function test_addLiquidity_emitsRewardAccruedAndLocked() public {
        _createBounty();
        address lp = address(modifyLiquidityRouter);
        uint256 unlockTime = block.timestamp + LOCKUP_DURATION;

        // Emitted in order: RewardAccrued, then LiquidityLocked.
        vm.expectEmit(true, true, false, true, address(hook));
        emit SamanaHook.RewardAccrued(poolId, lp, REWARD_AMOUNT);
        vm.expectEmit(true, true, false, true, address(hook));
        emit SamanaHook.LiquidityLocked(poolId, lp, unlockTime);

        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function test_addLiquidity_setsLockup() public {
        _createBounty();
        uint256 before = block.timestamp;

        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);

        assertEq(_lp(address(modifyLiquidityRouter)).lockupEnd, before + LOCKUP_DURATION);
    }

    // Qualifying a second time must not credit another reward.
    function test_addLiquidity_noDoubleReward() public {
        _createBounty();
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);

        uint256 pendingAfterFirst = _lp(address(modifyLiquidityRouter)).pending;

        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);

        assertEq(_lp(address(modifyLiquidityRouter)).pending, pendingAfterFirst, "no second reward");
    }

    // -------------------------------------------------------------------------
    // claimReward - flat (ilCoverageBps=0)
    // -------------------------------------------------------------------------

    function test_claimReward_transfersTokens() public {
        _createBounty();
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);

        vm.warp(block.timestamp + LOCKUP_DURATION + 1);
        uint256 routerBalBefore = bountyToken.balanceOf(address(modifyLiquidityRouter));
        vm.prank(address(modifyLiquidityRouter));
        hook.claimReward(poolKey);

        assertEq(bountyToken.balanceOf(address(modifyLiquidityRouter)), routerBalBefore + REWARD_AMOUNT);
        assertEq(_lp(address(modifyLiquidityRouter)).pending, 0);
    }

    function test_claimReward_emitsRewardClaimed() public {
        _createBounty();
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);

        vm.warp(block.timestamp + LOCKUP_DURATION + 1);
        vm.expectEmit(true, true, false, true, address(hook));
        emit SamanaHook.RewardClaimed(poolId, address(modifyLiquidityRouter), REWARD_AMOUNT);

        vm.prank(address(modifyLiquidityRouter));
        hook.claimReward(poolKey);
    }

    // No pending balance → silent no-op, no transfer.
    function test_claimReward_noPending_noOp() public {
        _createBounty();
        uint256 balBefore = bountyToken.balanceOf(address(this));
        hook.claimReward(poolKey);
        assertEq(bountyToken.balanceOf(address(this)), balBefore);
    }

    // -------------------------------------------------------------------------
    // claimReward - IL insurance (ilCoverageBps>0)
    // -------------------------------------------------------------------------

    // IL formula: same price at claim as at entry → IL = 0 → no insurance payout even with ilCoverageBps set.
    function test_claimReward_ilInsurance_noPayoutWhenNoPriceMove() public {
        hook.createBounty(poolKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 10000, BOUNTY_BUDGET);

        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);
        // No swap - price stays at SQRT_PRICE_1_1.

        vm.warp(block.timestamp + LOCKUP_DURATION + 1);

        uint256 balBefore = bountyToken.balanceOf(address(modifyLiquidityRouter));
        vm.prank(address(modifyLiquidityRouter));
        hook.claimReward(poolKey);

        assertEq(
            bountyToken.balanceOf(address(modifyLiquidityRouter)) - balBefore,
            REWARD_AMOUNT,
            "no insurance payout at same price"
        );
    }

    // -------------------------------------------------------------------------
    // IL math - unit tests via harness
    // -------------------------------------------------------------------------

    // Same price → IL = 0.
    function test_computeILBps_samePriceReturnsZero() public {
        SamanaHookHarness h = _deployHarness();
        assertEq(h.computeILBps(SQRT_PRICE_1_1, SQRT_PRICE_1_1), 0);
    }

    // Price 4x (sqrt doubles): IL = 1 - 2*2/(1+4) = 20% = 2000 bps.
    function test_computeILBps_priceQuadrupled_returns2000bps() public {
        SamanaHookHarness h = _deployHarness();
        uint256 ilBps = h.computeILBps(SQRT_PRICE_1_1, SQRT_PRICE_4_1);
        assertApproxEqAbs(ilBps, 2000, 2);
    }

    // IL is symmetric: price halved gives same IL as price quadrupled.
    function test_computeILBps_symmetric() public {
        SamanaHookHarness h = _deployHarness();
        uint256 ilUp = h.computeILBps(SQRT_PRICE_1_1, SQRT_PRICE_4_1);
        uint256 ilDown = h.computeILBps(SQRT_PRICE_4_1, SQRT_PRICE_1_1);
        assertApproxEqAbs(ilUp, ilDown, 2);
    }

    // -------------------------------------------------------------------------
    // beforeRemoveLiquidity - net liquidity tracking
    // -------------------------------------------------------------------------

    function test_removeLiquidity_noBounty_noLockup() public {
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);
        modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    // Remove cancels prior add for unqualified LPs - net tracking, not cumulative.
    function test_removeLiquidity_belowThreshold_noLockup() public {
        _createBounty();

        int256 smallDelta = int256(MIN_LIQUIDITY / 2);
        ModifyLiquidityParams memory addSmall =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: smallDelta, salt: 0});
        ModifyLiquidityParams memory removeSmall =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: -smallDelta, salt: 0});

        modifyLiquidityRouter.modifyLiquidity(poolKey, addSmall, ZERO_BYTES);
        assertEq(_lp(address(modifyLiquidityRouter)).lockupEnd, 0);

        modifyLiquidityRouter.modifyLiquidity(poolKey, removeSmall, ZERO_BYTES);
        assertEq(_lp(address(modifyLiquidityRouter)).liquidity, 0);
    }

    // Exploit attempt: add 60%, remove 60%, add 40% - LP never holds minLiquidity simultaneously.
    function test_removeAndReadd_doesNotQualify() public {
        _createBounty();

        uint256 sixty = (MIN_LIQUIDITY * 60) / 100;
        uint256 forty = MIN_LIQUIDITY - sixty;

        ModifyLiquidityParams memory add60 =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: int256(sixty), salt: 0});
        ModifyLiquidityParams memory remove60 =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: -int256(sixty), salt: 0});
        ModifyLiquidityParams memory add40 =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: int256(forty), salt: 0});

        modifyLiquidityRouter.modifyLiquidity(poolKey, add60, ZERO_BYTES);
        assertEq(_lp(address(modifyLiquidityRouter)).liquidity, sixty);

        modifyLiquidityRouter.modifyLiquidity(poolKey, remove60, ZERO_BYTES);
        assertEq(_lp(address(modifyLiquidityRouter)).liquidity, 0, "removal resets tracked liquidity");

        modifyLiquidityRouter.modifyLiquidity(poolKey, add40, ZERO_BYTES);
        assertEq(_lp(address(modifyLiquidityRouter)).liquidity, forty, "only 40% counted");

        assertFalse(_lp(address(modifyLiquidityRouter)).qualified);
        assertEq(_lp(address(modifyLiquidityRouter)).pending, 0);
        assertEq(_lp(address(modifyLiquidityRouter)).lockupEnd, 0);
    }

    // When remove exceeds tracked (e.g. after bounty deactivation while position grew),
    // lpLiquidity floors to 0 rather than underflowing.
    function test_removeExceedsTracked_floorsToZero() public {
        _createBounty();

        int256 halfDelta = int256(MIN_LIQUIDITY / 2);
        ModifyLiquidityParams memory addHalf =
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: halfDelta, salt: 0});

        modifyLiquidityRouter.modifyLiquidity(poolKey, addHalf, ZERO_BYTES);
        assertEq(_lp(address(modifyLiquidityRouter)).liquidity, uint256(halfDelta));

        hook.deactivateBounty(poolKey, address(this));

        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);
        assertEq(_lp(address(modifyLiquidityRouter)).liquidity, uint256(halfDelta), "no update while inactive");

        modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
        assertEq(_lp(address(modifyLiquidityRouter)).liquidity, 0, "floored to 0");
    }

    // Qualified LP removes after lockup - lpLiquidity decrement branch is skipped.
    function test_qualifiedLP_remove_skipsLiquidityDecrement() public {
        _createBounty();
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);

        uint256 trackedBefore = _lp(address(modifyLiquidityRouter)).liquidity;
        assertGt(trackedBefore, 0);

        vm.warp(block.timestamp + LOCKUP_DURATION + 1);
        modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);

        assertEq(_lp(address(modifyLiquidityRouter)).liquidity, trackedBefore);
    }

    // -------------------------------------------------------------------------
    // beforeRemoveLiquidity - lockup enforcement
    // -------------------------------------------------------------------------

    function test_removeLiquidity_lockedReverts() public {
        _createBounty();
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);

        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    // block.timestamp == unlock - 1: still within lockup.
    function test_removeLiquidity_oneSecondBefore_reverts() public {
        _createBounty();
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);

        uint256 unlock = _lp(address(modifyLiquidityRouter)).lockupEnd;
        vm.warp(unlock - 1);

        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    // block.timestamp == unlock: check is strict (<), so exact boundary succeeds.
    function test_removeLiquidity_atExactUnlock_succeeds() public {
        _createBounty();
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);

        uint256 unlock = _lp(address(modifyLiquidityRouter)).lockupEnd;
        vm.warp(unlock);

        modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function test_removeLiquidity_afterLockup_succeeds() public {
        _createBounty();
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);

        vm.warp(block.timestamp + LOCKUP_DURATION + 1);

        modifyLiquidityRouter.modifyLiquidity(poolKey, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    // Direct hook call bypasses PoolManager's WrappedError so the exact selector is visible.
    function test_removeLiquidity_lockedReverts_directHookCall() public {
        _createBounty();
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, ZERO_BYTES);

        uint256 unlock = _lp(address(modifyLiquidityRouter)).lockupEnd;

        vm.prank(address(manager));
        vm.expectRevert(abi.encodeWithSelector(SamanaHook.LiquidityStillLocked.selector, unlock));
        hook.beforeRemoveLiquidity(address(modifyLiquidityRouter), poolKey, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    // Deploys a harness at a valid hook address for pure-function testing.
    // FLAGS | (1<<15): matching permissions, bit 15 is not a hook flag (flags are bits 0-13).
    function _deployHarness() internal returns (SamanaHookHarness h) {
        address harnessAddr = address(FLAGS | (uint160(1) << 15));
        deployCodeTo("SamanaHook.t.sol:SamanaHookHarness", abi.encode(address(manager), address(this)), harnessAddr);
        h = SamanaHookHarness(harnessAddr);
    }
}
