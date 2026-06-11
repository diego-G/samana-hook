// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {DemoBase} from "./DemoCommon.s.sol";

/// @notice Initializes the demo pool (if needed) and creates a USDC bounty on SamanaHook.
///         Assumes CURRENCY0/CURRENCY1 (DALPHA/DBETA) are already deployed.
///
/// On a fresh pool this runs in two phases: the first run only initializes the pool and
/// exits, because createBounty requires twapWindow seconds of observation history and
/// would revert the whole simulation (so the initialize would never broadcast). Wait
/// twapWindow seconds after the first run, then run again to create the bounty.
///
/// Required env vars: ETH_KEYSTORE_ACCOUNT, ETH_PASSWORD, RPC_URL
///
/// Usage:
///   forge script script/demo/Demo1BountyCreation.s.sol:Demo1BountyCreation \
///     --broadcast
contract Demo1BountyCreation is DemoBase {
    using StateLibrary for IPoolManager;

    function run() external {
        // Check pool state before broadcast to avoid broadcasting a reverting initialize tx.
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(_buildKey().toId());
        bool needsInit = sqrtPriceX96 == 0;

        vm.startBroadcast();

        if (HOOK.bountyToken() != USDC) {
            HOOK.setBountyToken(USDC);
        }

        if (HOOK.twapWindow() != TWAP_WINDOW) {
            HOOK.setTwapWindow(TWAP_WINDOW);
            console2.log("TWAP window set to:        ", TWAP_WINDOW);
        }

        if (needsInit) {
            // Phase 1: initialize only. createBounty needs the pool's oldest observation
            // to be at least twapWindow seconds old, so it cannot succeed in this block.
            POOL_MANAGER.initialize(_buildKey(), SQRT_PRICE_1_1);
            vm.stopBroadcast();

            console2.log("Pool initialized. Bounty NOT created yet.");
            console2.log("Wait at least this many seconds, then run this script again:", TWAP_WINDOW);
            return;
        }

        console2.log("Pool already initialized, skipping");

        (, address broadcaster,) = vm.readCallers();
        if (IERC20(USDC).allowance(broadcaster, address(HOOK)) < BOUNTY_BUDGET) {
            IERC20(USDC).approve(address(HOOK), BOUNTY_BUDGET);
        }
        HOOK.createBounty(_buildKey(), REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, IL_COVERAGE_BPS, BOUNTY_BUDGET);

        (,, uint256 reward,,,, uint256 budget) = HOOK.bounties(_buildKey().toId());
        console2.log("");
        console2.log(
            string.concat(
                ">> Bounty created: ",
                _green(string.concat(_formatUsdc(reward), " USDC")),
                " per qualifying LP, ",
                _green(string.concat(_formatUsdc(budget), " USDC")),
                " net budget, room for ",
                _yellow(string.concat(vm.toString(budget / reward), " LPs")),
                "."
            )
        );

        vm.stopBroadcast();
    }
}
