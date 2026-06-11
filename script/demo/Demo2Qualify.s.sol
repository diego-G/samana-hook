// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {DemoBase, LPActor} from "./DemoCommon.s.sol";

/// @notice Deploys an LPActor, mints demo tokens into it, and adds liquidity
///         so the LP qualifies for the active bounty.
///
/// Required env vars: ETH_KEYSTORE_ACCOUNT, ETH_PASSWORD, RPC_URL
/// Assumes: bounty already active (run Demo1BountyCreation first).
///
/// Usage:
///   forge script script/demo/Demo2Qualify.s.sol:Demo2Qualify \
///     --broadcast
///
/// After running: set LP_ACTOR=<printed address>, then run Demo3Claim after lockup.
contract Demo2Qualify is DemoBase {
    function run() external {
        vm.startBroadcast();

        LPActor lpActor = new LPActor(POOL_MANAGER, HOOK);
        console2.log("LPActor:", address(lpActor));

        lpActor.mintAndAddLiquidity(_buildKey(), _liquidityParams(), 1_000e18, 1_000e18);

        vm.stopBroadcast();

        (, bool qualified,, uint256 lockupEnd, uint256 pending) = HOOK.lpState(_buildKey().toId(), address(lpActor));
        console2.log("");
        if (pending > 0) {
            console2.log(
                string.concat(
                    ">> LP added liquidity and ",
                    _yellow("qualified"),
                    ": ",
                    _green(string.concat(_formatUsdc(pending), " USDC")),
                    " reserved, ",
                    _yellow("lockup started"),
                    "."
                )
            );
            console2.log("Lockup ends at:", lockupEnd);
        } else if (qualified) {
            console2.log(
                string.concat(">> LP added liquidity and qualified, but the ", _yellow("budget is depleted"), ":")
            );
            console2.log(
                string.concat(
                    ">> ",
                    _yellow("no reward, no lockup"),
                    ". The LP can ",
                    _green("withdraw its liquidity anytime"),
                    "."
                )
            );
        } else {
            console2.log(
                string.concat(">> LP added liquidity but did ", _yellow("NOT qualify"), " (below minimum liquidity).")
            );
        }
        console2.log("");
        console2.log(string.concat("export LP_ACTOR=", vm.toString(address(lpActor))));
    }
}
