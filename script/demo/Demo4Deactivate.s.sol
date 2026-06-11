// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DemoBase} from "./DemoCommon.s.sol";

/// @notice Deactivates the active bounty and refunds uncommitted budget to the broadcaster.
///         Already-credited LP rewards remain claimable after deactivation.
///
/// Required env vars: ETH_KEYSTORE_ACCOUNT, ETH_PASSWORD, RPC_URL
///
/// Usage:
///   forge script script/demo/Demo4Deactivate.s.sol:Demo4Deactivate \
///     --broadcast
contract Demo4Deactivate is DemoBase {
    function run() external {
        vm.startBroadcast();
        // msg.sender in the script frame is Foundry's DEFAULT_SENDER, not the
        // broadcaster; readCallers returns the actual broadcast signer.
        (, address broadcaster,) = vm.readCallers();
        uint256 balBefore = IERC20(USDC).balanceOf(broadcaster);

        HOOK.deactivateBounty(_buildKey(), broadcaster);
        vm.stopBroadcast();

        uint256 refunded = IERC20(USDC).balanceOf(broadcaster) - balBefore;
        console2.log("");
        console2.log(
            string.concat(
                ">> Bounty ",
                _yellow("deactivated"),
                ": ",
                _green(string.concat(_formatUsdc(refunded), " USDC")),
                " of uncommitted budget refunded to the creator."
            )
        );
        console2.log(string.concat(">> Already-credited LP rewards ", _green("remain claimable"), "."));
    }
}
