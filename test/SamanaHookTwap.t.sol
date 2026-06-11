// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SamanaHookTestBase} from "./SamanaHookTestBase.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Adversarial tests for the TWAP-based IL price calculation.
///         Verifies that flash-loan price manipulation at claim/entry time does not
///         inflate IL payouts, and that disabling TWAP (twapWindow=0) restores
///         the vulnerability as a proof that the protection is real.
contract SamanaHookTwapTest is SamanaHookTestBase {
    // Wide LP providing deep liquidity so swaps have room to move price.
    PoolModifyLiquidityTest wideRouter;

    function setUp() public override {
        super.setUp();
        wideRouter = new PoolModifyLiquidityTest(manager);
        MockERC20(Currency.unwrap(currency0)).approve(address(wideRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(wideRouter), type(uint256).max);
        wideRouter.modifyLiquidity(poolKey, _fullRangeParams(100e18), ZERO_BYTES);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _createILBounty() internal {
        hook.createBounty(poolKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 10000, BOUNTY_BUDGET * 6);
    }

    /// @dev Write `n` observations spread evenly across `totalSeconds` using tiny alternating
    ///      swaps so price stays near SQRT_PRICE_1_1 but a new block is recorded each time.
    function _buildTwapHistory(uint256 totalSeconds, uint256 n) internal {
        uint256 t0 = block.timestamp;
        for (uint256 i = 1; i <= n; i++) {
            vm.warp(t0 + (totalSeconds * i) / n);
            // Alternating direction keeps price near 1:1; tiny amount = negligible tick drift.
            if (i % 2 == 1) swap(poolKey, true, -1e14, ZERO_BYTES);
            else swap(poolKey, false, -1e14, ZERO_BYTES);
        }
    }

    // -------------------------------------------------------------------------
    // Flash-loan resistance at claim time
    // -------------------------------------------------------------------------

    /// Core adversarial test.
    /// Attacker builds a TWAP history of stable prices, waits out the lockup, then
    /// in the same block does a large swap (which beforeSwap records at the pre-swap
    /// tick) and immediately claims. The TWAP averages stable ticks → IL ≈ 0 →
    /// payout = base reward only; the spot price is irrelevant.
    function test_claimReward_flashLoan_sameBlock_doesNotInflatePayout() public {
        _createILBounty();
        modifyLiquidityRouter.modifyLiquidity(poolKey, _fullRangeParams(int256(MIN_LIQUIDITY)), ZERO_BYTES);

        // Build > twapWindow (1800s) of stable price observations.
        _buildTwapHistory(2000, 12);

        vm.warp(block.timestamp + LOCKUP_DURATION + 1);

        address lp = address(modifyLiquidityRouter);
        uint256 balBefore = bountyToken.balanceOf(lp);

        // Attack: massive swap + claim in the same block.
        // beforeSwap records pre-swap tick (≈ 0 / SQRT_PRICE_1_1); claim sees TWAP of stable history.
        swap(poolKey, true, -1000e18, ZERO_BYTES);
        vm.prank(lp);
        hook.claimReward(poolKey);

        uint256 received = bountyToken.balanceOf(lp) - balBefore;
        assertEq(received, REWARD_AMOUNT, "flash loan in claim block must not inflate IL payout");
    }

    /// Proof that the protection is real: disabling TWAP (twapWindow=0) makes
    /// the same attack succeed - payout is inflated by the spot manipulation.
    function test_claimReward_twapDisabled_sameBlockSwap_inflatesPayout() public {
        hook.setTwapWindow(0); // spot price used instead of TWAP

        _createILBounty();
        modifyLiquidityRouter.modifyLiquidity(poolKey, _fullRangeParams(int256(MIN_LIQUIDITY)), ZERO_BYTES);

        _buildTwapHistory(2000, 12);

        vm.warp(block.timestamp + LOCKUP_DURATION + 1);

        address lp = address(modifyLiquidityRouter);
        uint256 balBefore = bountyToken.balanceOf(lp);

        // Same attack: spot is now manipulatable → IL inflated.
        swap(poolKey, true, -1000e18, ZERO_BYTES);
        vm.prank(lp);
        hook.claimReward(poolKey);

        uint256 received = bountyToken.balanceOf(lp) - balBefore;
        assertGt(received, REWARD_AMOUNT, "spot mode: same-block manipulation must inflate payout");
    }

    // -------------------------------------------------------------------------
    // Flash-loan resistance at entry time
    // -------------------------------------------------------------------------

    /// Attacker manipulates spot price just before adding liquidity (qualifying),
    /// hoping to record a skewed entry price that maximises IL at claim time.
    /// Entry price is TWAP → skewed spot is ignored → IL measured correctly.
    function test_entryPrice_flashLoan_doesNotSkewEntryPrice() public {
        _createILBounty();

        // Build stable price history before entry.
        _buildTwapHistory(2000, 12);

        // Attack: move spot far from TWAP before qualifying.
        swap(poolKey, true, -500e18, ZERO_BYTES);

        // Record TWAP entry price.
        modifyLiquidityRouter.modifyLiquidity(poolKey, _fullRangeParams(int256(MIN_LIQUIDITY)), ZERO_BYTES);
        uint160 recordedEntry = _lp(address(modifyLiquidityRouter)).entryPrice;

        // TWAP entry should be near SQRT_PRICE_1_1, not the manipulated spot.
        // Verify it is closer to SQRT_PRICE_1_1 than to the post-swap spot.
        uint256 distFromStable =
            recordedEntry > SQRT_PRICE_1_1 ? recordedEntry - SQRT_PRICE_1_1 : SQRT_PRICE_1_1 - recordedEntry;

        // After a 500e18 swap the spot has moved significantly; TWAP should be within 5% of 1:1.
        uint256 fivePercent = SQRT_PRICE_1_1 / 20;
        assertLt(distFromStable, fivePercent, "entry price must reflect TWAP, not manipulated spot");
    }

    /// Counterpart: with TWAP disabled (spot), the same entry manipulation skews
    /// the recorded entry price far from 1:1.
    function test_entryPrice_twapDisabled_spotManipulatable() public {
        hook.setTwapWindow(0);
        _createILBounty();

        _buildTwapHistory(2000, 12);

        // Move spot far before qualifying.
        swap(poolKey, true, -500e18, ZERO_BYTES);

        modifyLiquidityRouter.modifyLiquidity(poolKey, _fullRangeParams(int256(MIN_LIQUIDITY)), ZERO_BYTES);
        uint160 recordedEntry = _lp(address(modifyLiquidityRouter)).entryPrice;

        uint256 distFromStable =
            recordedEntry > SQRT_PRICE_1_1 ? recordedEntry - SQRT_PRICE_1_1 : SQRT_PRICE_1_1 - recordedEntry;

        uint256 fivePercent = SQRT_PRICE_1_1 / 20;
        assertGt(distFromStable, fivePercent, "spot mode: entry price must reflect manipulated spot");
    }

    // -------------------------------------------------------------------------
    // Cardinality-zero fallback (no observations yet)
    // -------------------------------------------------------------------------

    /// Covers the `cardinality == 0` branch in `_getTwapSqrtPrice`.
    /// Forces cardinality to zero via vm.store (slot 7 of `_obsState` mapping),
    /// then adds liquidity. With no observations the function must fall back to spot.
    function test_getTwapSqrtPrice_cardinalityZero_fallsBackToSpot() public {
        _createILBounty();

        // Zero out _obsState[poolId] (index=0, cardinality=0). Slot 7 is the _obsState mapping.
        bytes32 cardSlot = keccak256(abi.encode(poolId, uint256(7)));
        vm.store(address(hook), cardSlot, bytes32(0));

        modifyLiquidityRouter.modifyLiquidity(poolKey, _fullRangeParams(int256(MIN_LIQUIDITY)), ZERO_BYTES);

        uint160 recorded = _lp(address(modifyLiquidityRouter)).entryPrice;
        assertEq(recorded, SQRT_PRICE_1_1, "cardinality=0: entry price must equal spot");
    }

    /// Covers the `elapsed < twapWindow` fallback in `_getTwapSqrtPrice`.
    /// 500 one-second-apart swaps wrap the 500-slot observation ring buffer, leaving the
    /// oldest surviving observation only ~499s old (< twapWindow=1800). With insufficient
    /// history the entry price must fall back to spot; a large swap right before
    /// qualifying moves spot far from the stable TWAP so the two outcomes are distinguishable.
    function test_getTwapSqrtPrice_bufferWrapped_fallsBackToSpot() public {
        _createILBounty();

        // Wrap the ring buffer: one observation per second for 500 seconds.
        _buildTwapHistory(500, 500);

        // Move spot far from the (stable) history. Same block as the last observation,
        // so Oracle.write dedupes and the wrapped buffer state is preserved.
        swap(poolKey, true, -500e18, ZERO_BYTES);
        (uint160 spotAfterSwap,,,) = StateLibrary.getSlot0(manager, poolId);

        modifyLiquidityRouter.modifyLiquidity(poolKey, _fullRangeParams(int256(MIN_LIQUIDITY)), ZERO_BYTES);
        uint160 recorded = _lp(address(modifyLiquidityRouter)).entryPrice;

        assertEq(recorded, spotAfterSwap, "wrapped buffer: entry price must equal spot, not TWAP");
    }

    // -------------------------------------------------------------------------
    // Sustained price move is correctly captured
    // -------------------------------------------------------------------------

    /// A price move that PERSISTS across many blocks IS real IL and should be paid.
    /// Verifies TWAP does not suppress genuine, time-weighted IL.
    function test_claimReward_sustainedPriceMove_paidAsIL() public {
        _createILBounty();
        modifyLiquidityRouter.modifyLiquidity(poolKey, _fullRangeParams(int256(MIN_LIQUIDITY)), ZERO_BYTES);

        // Price moves significantly and STAYS there for > twapWindow.
        swap(poolKey, true, -1000e18, ZERO_BYTES);
        _buildTwapHistory(2000, 12); // history built at the new (moved) price

        vm.warp(block.timestamp + LOCKUP_DURATION + 1);

        address lp = address(modifyLiquidityRouter);
        uint256 balBefore = bountyToken.balanceOf(lp);
        vm.prank(lp);
        hook.claimReward(poolKey);

        uint256 received = bountyToken.balanceOf(lp) - balBefore;
        assertGt(received, REWARD_AMOUNT, "sustained price move must be paid as genuine IL");
    }
}
