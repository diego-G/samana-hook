// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {SamanaHook} from "../src/SamanaHook.sol";

/// @notice Mines and deploys SamanaHook via CREATE2.
///
/// Required env vars:
///   POOL_MANAGER   - Uniswap v4 PoolManager address on the target chain
///   INITIAL_OWNER  - Address that becomes the hook owner
///
/// Optional post-deploy configuration env vars (applied when set):
///   BOUNTY_TOKEN       - ERC20 used for bounty rewards and fees (e.g. USDC)
///   TREASURY           - Address that receives protocol fee revenue
///   PROTOCOL_FEE_BPS   - Protocol fee in bps, max 1000 (default: 0)
///
/// Usage:
///   forge script script/DeploySamanaHook.s.sol \
///     --rpc-url $RPC_URL --broadcast --verify
contract DeploySamanaHook is Script {
    // Deterministic CREATE2 deployer proxy, same address on all EVM chains.
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address initialOwner = vm.envAddress("INITIAL_OWNER");

        // SamanaHook implements: afterInitialize | afterAddLiquidity | beforeRemoveLiquidity | beforeSwap
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
        );

        bytes memory constructorArgs = abi.encode(IPoolManager(poolManager), initialOwner);

        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(SamanaHook).creationCode, constructorArgs);

        console2.log("Deploying SamanaHook...");
        console2.log("  Predicted address:", hookAddress);
        console2.log("  Salt:             ", uint256(salt));

        vm.startBroadcast();

        SamanaHook hook = new SamanaHook{salt: salt}(IPoolManager(poolManager), initialOwner);
        require(address(hook) == hookAddress, "DeploySamanaHook: address mismatch");

        // --- Optional post-deploy configuration ---

        address bountyToken = vm.envOr("BOUNTY_TOKEN", address(0));
        if (bountyToken != address(0)) {
            hook.setBountyToken(bountyToken);
            console2.log("  BountyToken set:", bountyToken);
        }

        address treasury = vm.envOr("TREASURY", address(0));
        if (treasury != address(0)) {
            hook.setTreasury(treasury);
            console2.log("  Treasury set:   ", treasury);
        }

        uint256 feeBps = vm.envOr("PROTOCOL_FEE_BPS", uint256(0));
        if (feeBps > 0) {
            require(feeBps <= 1000, "DeploySamanaHook: PROTOCOL_FEE_BPS exceeds max 1000");
            // forge-lint: disable-next-line(unsafe-typecast)
            hook.setProtocolFeeBps(uint16(feeBps));
            console2.log("  ProtocolFeeBps: ", feeBps);
        }

        vm.stopBroadcast();

        console2.log("SamanaHook deployed at:", address(hook));
    }
}
