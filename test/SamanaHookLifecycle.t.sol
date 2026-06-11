// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SamanaHookTestBase} from "./SamanaHookTestBase.sol";
import {console2} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SamanaHook} from "../src/SamanaHook.sol";

/// @notice End-to-end narrative test of the SamanaHook IL insurance lifecycle.
///         Run: forge test --match-test test_lifecycle -vv
contract SamanaHookLifecycle is SamanaHookTestBase {
    using StateLibrary for *;

    address constant CREATOR = address(0xC0FFEE);
    address constant TREASURY = address(0x7EA5);
    uint16 constant FEE_BPS = 100; // 1%

    PoolModifyLiquidityTest lpRouter;

    function setUp() public override {
        super.setUp();

        // spot price for demo (no block history needed); production uses 30-min TWAP
        hook.setTwapWindow(0);
        hook.setTreasury(TREASURY);
        hook.setProtocolFeeBps(FEE_BPS);

        bountyToken.mint(CREATOR, BOUNTY_BUDGET * 2);
        vm.startPrank(CREATOR);
        bountyToken.approve(address(hook), type(uint256).max);
        vm.stopPrank();

        // Separate router = separate LP identity (sender caveat: hook tracks router address)
        lpRouter = new PoolModifyLiquidityTest(manager);
        MockERC20(Currency.unwrap(currency0)).approve(address(lpRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(lpRouter), type(uint256).max);

        // Deep background liquidity so the price-crash swap has room to move
        modifyLiquidityRouter.modifyLiquidity(poolKey, _fullRangeParams(100e18), ZERO_BYTES);
    }

    function test_lifecycle() public {
        uint256 t0 = block.timestamp;

        console2.log("");
        console2.log("================================================================");
        console2.log("  SAMANA HOOK -- IL INSURANCE DEMO");
        console2.log("================================================================");
        console2.log("  Scenario: cold-start pool launch.");
        console2.log("  Protocol funds IL insurance to attract LPs during volatile");
        console2.log("  price discovery. LPs who commit capital and bear IL are");
        console2.log("  compensated beyond swap fees.");
        console2.log("");

        // ── ACT 1: PROTOCOL CREATES BOUNTY ───────────────────────────────────────
        console2.log("----------------------------------------------------------------");
        console2.log("  ACT 1: PROTOCOL CREATES BOUNTY");
        console2.log("----------------------------------------------------------------");

        vm.startPrank(CREATOR);
        hook.createBounty(poolKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 10000, BOUNTY_BUDGET);
        vm.stopPrank();

        (,,,,,, uint256 budget) = hook.bounties(poolId);
        uint256 protocolFee = BOUNTY_BUDGET - budget;

        console2.log("  Deposit          : 1000 USDC");
        console2.log("  Protocol fee 1%  :", protocolFee / 1e18, "USDC -> treasury");
        console2.log("  Net budget       :", budget / 1e18, "USDC");
        console2.log("  Reward per LP    :", REWARD_AMOUNT / 1e18, "USDC (flat base)");
        console2.log("  IL coverage      : 100% (1:1 full coverage)");
        console2.log("  Lockup           : 7 days");
        console2.log("");

        // ── ACT 2: LP ADDS LIQUIDITY ──────────────────────────────────────────────
        console2.log("----------------------------------------------------------------");
        console2.log("  ACT 2: LP ADDS LIQUIDITY");
        console2.log("----------------------------------------------------------------");

        address lp = address(lpRouter);

        lpRouter.modifyLiquidity(poolKey, _fullRangeParams(int256(MIN_LIQUIDITY)), ZERO_BYTES);

        uint256 lockupEnd = _lp(lp).lockupEnd;
        (,,,,,, uint256 budgetAfterQual) = hook.bounties(poolId);

        console2.log("  LP qualified     :", _lp(lp).qualified);
        console2.log("  Reward credited  :", _lp(lp).pending / 1e18, "USDC (pending)");
        console2.log(string.concat("  Locked until     : ", _elapsed(lockupEnd - t0)));
        console2.log(
            string.concat(
                "  Entry price      : ",
                _formatPrice(_lp(lp).entryPrice),
                " token1/token0 (spot; 30-min TWAP in production)"
            )
        );
        console2.log("  Budget remaining :", budgetAfterQual / 1e18, "USDC");
        console2.log("");

        // ── ACT 3: PRICE CRASHES ──────────────────────────────────────────────────
        console2.log("----------------------------------------------------------------");
        console2.log("  ACT 3: PRICE CRASHES");
        console2.log("----------------------------------------------------------------");
        console2.log("  Token dump: large sell into pool ...");

        swap(poolKey, true, -1000e18, ZERO_BYTES);

        (uint160 postSwapSqrt,,,) = StateLibrary.getSlot0(manager, poolId);
        console2.log(string.concat("  Pool price now   : ", _formatPrice(postSwapSqrt), " token1/token0 (was 1.000)"));
        console2.log("  LP position is in IL. Insurance will pay out at claim.");
        console2.log("");

        // ── ACT 4: LOCKUP EXPIRES ─────────────────────────────────────────────────
        console2.log("----------------------------------------------------------------");
        console2.log("  ACT 4: 7-DAY LOCKUP EXPIRES");
        console2.log("----------------------------------------------------------------");

        vm.warp(lockupEnd);

        console2.log(string.concat("  Time             : ", _elapsed(block.timestamp - t0)), "after");
        console2.log("  LP can now remove liquidity and claim reward.");
        console2.log("");

        // ── ACT 5: LP CLAIMS ──────────────────────────────────────────────────────
        console2.log("----------------------------------------------------------------");
        console2.log("  ACT 5: LP CLAIMS REWARD + IL INSURANCE");
        console2.log("----------------------------------------------------------------");

        (uint160 exitSqrt,,,) = StateLibrary.getSlot0(manager, poolId);
        console2.log(
            string.concat("  Exit price       : ", _formatPrice(exitSqrt), " token1/token0 (30-min TWAP in production)")
        );

        uint256 lpBalBefore = bountyToken.balanceOf(lp);

        vm.prank(lp);
        hook.claimReward(poolKey);

        uint256 received = bountyToken.balanceOf(lp) - lpBalBefore;
        uint256 ilPayout = received > REWARD_AMOUNT ? received - REWARD_AMOUNT : 0;
        (,,,,,, uint256 budgetAfterClaim) = hook.bounties(poolId);

        console2.log("  Base reward      :", REWARD_AMOUNT / 1e18, "USDC");
        console2.log("  IL insurance     :", ilPayout / 1e18, "USDC");
        console2.log("  Total received   :", received / 1e18, "USDC");
        console2.log("  Budget remaining :", budgetAfterClaim / 1e18, "USDC");
        console2.log("");

        // ── ACT 6: CREATOR DEACTIVATES ────────────────────────────────────────────
        console2.log("----------------------------------------------------------------");
        console2.log("  ACT 6: CREATOR DEACTIVATES BOUNTY");
        console2.log("----------------------------------------------------------------");

        uint256 creatorBalBefore = bountyToken.balanceOf(CREATOR);

        vm.prank(CREATOR);
        hook.deactivateBounty(poolKey, CREATOR);

        uint256 refunded = bountyToken.balanceOf(CREATOR) - creatorBalBefore;

        console2.log("  Refunded         :", refunded / 1e18, "USDC -> creator");
        console2.log("  Treasury         :", protocolFee / 1e18, "USDC (protocol fee)");
        console2.log("");

        // ── SUMMARY ───────────────────────────────────────────────────────────────
        console2.log("================================================================");
        console2.log("  SUMMARY");
        console2.log("================================================================");
        console2.log("  Creator deposited:", BOUNTY_BUDGET / 1e18, "USDC");
        console2.log("  Creator refunded :", refunded / 1e18, "USDC");
        console2.log("  Creator net cost :", (BOUNTY_BUDGET - refunded) / 1e18, "USDC");
        console2.log("  LP earned        :", received / 1e18, "USDC (base + IL insurance)");
        console2.log("  Protocol earned  :", protocolFee / 1e18, "USDC");
        console2.log("================================================================");
        console2.log("");

        assertGt(received, REWARD_AMOUNT, "LP must receive more than base reward");
        assertEq(bountyToken.balanceOf(TREASURY), protocolFee, "treasury must have received protocol fee");
    }

    // ── Helpers ───────────────────────────────────────────────────────────────────

    /// Converts a sqrtPriceX96 value to a "X.XXX" decimal string (3 decimal places).
    function _formatPrice(uint160 sqrtPriceX96) internal pure returns (string memory) {
        uint256 sqrtE9 = uint256(sqrtPriceX96) * 1e9 / (2 ** 96);
        uint256 priceE18 = sqrtE9 * sqrtE9;
        uint256 intPart = priceE18 / 1e18;
        uint256 frac3 = (priceE18 % 1e18) / 1e15;
        string memory fracStr = frac3 < 10
            ? string.concat("00", vm.toString(frac3))
            : frac3 < 100 ? string.concat("0", vm.toString(frac3)) : vm.toString(frac3);
        return string.concat(vm.toString(intPart), ".", fracStr);
    }

    /// Converts elapsed seconds to a human-readable "Xd Yh" string.
    function _elapsed(uint256 secs) internal pure returns (string memory) {
        uint256 d = secs / 1 days;
        uint256 h = (secs % 1 days) / 1 hours;
        uint256 m = (secs % 1 hours) / 1 minutes;
        if (d > 0 && h == 0 && m == 0) return string.concat(vm.toString(d), "d");
        if (d > 0 && m == 0) return string.concat(vm.toString(d), "d ", vm.toString(h), "h");
        if (d > 0) return string.concat(vm.toString(d), "d ", vm.toString(h), "h ", vm.toString(m), "m");
        if (h > 0) return string.concat(vm.toString(h), "h ", vm.toString(m), "m");
        return string.concat(vm.toString(m), "m");
    }
}
