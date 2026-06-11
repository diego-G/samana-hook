// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DemoBase, ILPActor} from "./DemoCommon.s.sol";

/// @notice Claims the pending bounty reward via an LPActor and withdraws USDC to the caller.
///         Run at least LOCKUP_DURATION after Demo2Qualify; earlier calls revert with LiquidityStillLocked.
///
/// Required env vars: ETH_KEYSTORE_ACCOUNT, ETH_PASSWORD, RPC_URL, LP_ACTOR
///
/// Usage (after lockup expires):
///   forge script script/demo/Demo3Claim.s.sol:Demo3Claim \
///     --broadcast
contract Demo3Claim is DemoBase {
    function run() external {
        ILPActor lpActor = ILPActor(vm.envAddress("LP_ACTOR"));

        vm.startBroadcast();
        // msg.sender in the script frame is Foundry's DEFAULT_SENDER, not the
        // broadcaster; readCallers returns the actual broadcast signer.
        (, address broadcaster,) = vm.readCallers();
        uint256 balBefore = IERC20(USDC).balanceOf(broadcaster);

        lpActor.claimAndWithdraw(_buildKey(), USDC);
        vm.stopBroadcast();

        uint256 received = IERC20(USDC).balanceOf(broadcaster) - balBefore;
        console2.log("");
        console2.log(
            string.concat(
                ">> ",
                _yellow("Lockup over"),
                ": LP claimed its reward, ",
                _green(string.concat(_formatUsdc(received), " USDC")),
                " received."
            )
        );
    }
}
