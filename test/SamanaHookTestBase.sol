// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SamanaHook} from "../src/SamanaHook.sol";

abstract contract SamanaHookTestBase is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint160 constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
    );

    SamanaHook hook;
    MockERC20 bountyToken;
    PoolKey poolKey;
    PoolId poolId;

    uint256 constant REWARD_AMOUNT = 100e18;
    uint256 constant MIN_LIQUIDITY = 1e18;
    uint256 constant LOCKUP_DURATION = 7 days;
    uint256 constant BOUNTY_BUDGET = 10 * REWARD_AMOUNT;

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        address hookAddr = address(FLAGS);
        deployCodeTo("SamanaHook.sol:SamanaHook", abi.encode(address(manager), address(this)), hookAddr);
        hook = SamanaHook(hookAddr);

        poolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        bountyToken = new MockERC20("BountyToken", "BTK", 18);
        bountyToken.mint(address(this), BOUNTY_BUDGET * 100);
        bountyToken.approve(address(hook), type(uint256).max);
        hook.setBountyToken(address(bountyToken));

        // Advance past twapWindow so createBounty calls in tests don't hit PoolTooYoung.
        vm.warp(block.timestamp + hook.twapWindow());
    }

    function _lp(address addr) internal view returns (SamanaHook.LPState memory s) {
        (s.liquidity, s.qualified, s.entryPrice, s.lockupEnd, s.pending) = hook.lpState(poolId, addr);
    }

    function _createBounty() internal {
        hook.createBounty(poolKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 0, BOUNTY_BUDGET);
    }

    function _fullRangeParams(int256 liquidityDelta) internal view returns (ModifyLiquidityParams memory) {
        int24 ts = poolKey.tickSpacing;
        return ModifyLiquidityParams({
            tickLower: (TickMath.MIN_TICK / ts) * ts,
            tickUpper: (TickMath.MAX_TICK / ts) * ts,
            liquidityDelta: liquidityDelta,
            salt: 0
        });
    }

    function _wideLiquidityParams() internal view returns (ModifyLiquidityParams memory) {
        return _fullRangeParams(100e18);
    }
}
