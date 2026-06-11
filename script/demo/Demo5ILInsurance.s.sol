// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {DemoBase, LPActor, Swapper} from "./DemoCommon.s.sol";

/// @notice Demonstrates IL insurance payout on top of the base reward.
///
/// Flow:
///   1. LP adds full-range liquidity → qualifies, entry price snapshotted
///   2. Large swap moves price → LP suffers IL
///   3. After the lockup, Demo3Claim pays base reward + IL insurance
///
/// Assumes a bounty is already active (run Demo1BountyCreation first).
/// After this script, set LP_ACTOR=<printed address> and run Demo3Claim.
///
/// Required env vars: ETH_KEYSTORE_ACCOUNT, ETH_PASSWORD, RPC_URL
///
/// Usage:
///   forge script script/demo/Demo5ILInsurance.s.sol:Demo5ILInsurance \
///     --broadcast -vvv
contract Demo5ILInsurance is DemoBase {
    using StateLibrary for IPoolManager;

    function run() external {
        vm.startBroadcast();

        // 1. Deploy LPActor with WIDE liquidity so entryPrice is snapshotted.
        //    Always fresh: the hook keys qualification to the LP address, so a
        //    reused actor would already be qualified and earn nothing.
        LPActor lpActor = new LPActor(POOL_MANAGER, HOOK);
        _fundAndAddLiquidity(lpActor);

        // 2. Move price by a fixed 10^6 toward (and past) 1:1, regardless of pool depth.
        //    The Swapper is stateless and reused across runs via the SWAPPER env var.
        Swapper swapper = _getOrDeploySwapper();
        _movePriceTowardOne(swapper);

        vm.stopBroadcast();

        // 3. Print LP state
        (,, uint160 entryPrice, uint256 lockupEnd, uint256 pending) = HOOK.lpState(_buildKey().toId(), address(lpActor));
        console2.log("");
        console2.log(
            string.concat(
                ">> Wide-range LP ",
                _yellow("qualified"),
                ": ",
                _green(string.concat(_formatUsdc(pending), " USDC")),
                " base reserved, ",
                _yellow("entry price snapshotted"),
                "."
            )
        );
        console2.log(string.concat(">> A large swap then moved the price: the LP is now ", _yellow("deep in IL"), "."));
        console2.log(string.concat(">> After the lockup, the claim pays ", _green("base + IL insurance"), "."));
        console2.log("");
        console2.log("Entry sqrtPrice (X96):", entryPrice);
        console2.log("Lockup ends at:       ", lockupEnd);
        console2.log("");
        console2.log(string.concat("export LP_ACTOR=", vm.toString(address(lpActor))));
        console2.log(string.concat("export SWAPPER=", vm.toString(address(swapper))));
    }

    /// @dev Reuses the Swapper at $SWAPPER when it exists (it is stateless and
    ///      owner-bound), deploying a new one only on the first run.
    function _getOrDeploySwapper() internal returns (Swapper) {
        address existing = vm.envOr("SWAPPER", address(0));
        if (existing.code.length > 0) {
            return Swapper(existing);
        }
        return new Swapper(POOL_MANAGER);
    }

    /// @dev Mints the token amounts the full-range position needs at the current price
    ///      (token0 ~ L/sqrt, token1 ~ L*sqrt, which drift across demo runs), then adds
    ///      the liquidity to qualify the LP.
    function _fundAndAddLiquidity(LPActor lpActor) internal {
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(_buildKey().toId());
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 lpLiquidity = uint128(uint256(_wideLiquidityParams().liquidityDelta));
        uint256 amount0 = FullMath.mulDiv(lpLiquidity, FixedPoint96.Q96, sqrtPriceX96);
        uint256 amount1 = FullMath.mulDiv(lpLiquidity, sqrtPriceX96, FixedPoint96.Q96);
        lpActor.mintAndAddLiquidity(
            _buildKey(), _wideLiquidityParams(), amount0 + amount0 / 50 + 1e18, amount1 + amount1 / 50 + 1e18
        );
    }

    /// @dev Limit-driven swap: an exact input sized above what the move requires, with a
    ///      sqrtPriceLimit at 1000x the current sqrtPrice (price = sqrt^2, so 10^6), so the
    ///      limit is what stops the swap. The exit price is a TWAP of ticks over twapWindow,
    ///      so the measured ratio is the move raised to the post-swap fraction of the window;
    ///      10^6 keeps IL high even when the claim lands early in the window: with a 30s
    ///      window, claiming 10-20s into the window -> ratio 10^2-10^4 -> IL ~80-98%.
    ///      Swapping toward 1:1 keeps the input amount small no matter how far previous
    ///      demo runs have pushed the price.
    function _movePriceTowardOne(Swapper swapper) internal {
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(_buildKey().toId());
        uint128 poolLiquidity = POOL_MANAGER.getLiquidity(_buildKey().toId());
        bool priceBelowOne = sqrtPriceX96 < SQRT_PRICE_1_1;
        bool zeroForOne = !priceBelowOne; // selling token0 pushes price down
        uint160 sqrtLimit = priceBelowOne ? sqrtPriceX96 * 1000 : sqrtPriceX96 / 1000;

        // Input required to push in-range liquidity from sqrtPriceX96 to sqrtLimit:
        //   token0: L/sqrt' - L/sqrt    token1: L * (sqrt' - sqrt)
        uint256 needed = zeroForOne
            ? FullMath.mulDiv(poolLiquidity, FixedPoint96.Q96, sqrtLimit)
                - FullMath.mulDiv(poolLiquidity, FixedPoint96.Q96, sqrtPriceX96)
            : FullMath.mulDiv(poolLiquidity, sqrtLimit - sqrtPriceX96, FixedPoint96.Q96);
        needed += needed / 50 + 1e18; // margin for the 0.3% swap fee and out-of-range ticks

        // forge-lint: disable-next-line(unsafe-typecast)
        swapper.mintAndSwap(_buildKey(), zeroForOne, -int256(needed), sqrtLimit, needed);
    }
}
