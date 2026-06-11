// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SamanaHook} from "../src/SamanaHook.sol";

/// @notice Fork tests against the live Sepolia PoolManager.
/// Requires SEPOLIA_RPC_URL env var; skipped automatically when absent.
contract SamanaHookForkTest is Test {
    using PoolIdLibrary for PoolKey;

    receive() external payable {}

    IPoolManager constant SEPOLIA_POOL_MANAGER = IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);

    uint160 constant FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
    );

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    ModifyLiquidityParams LIQUIDITY_PARAMS =
        ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0});

    SamanaHook hook;
    MockERC20 bountyToken;
    Currency currency0;
    Currency currency1;
    PoolModifyLiquidityTest modifyLiquidityRouter;
    PoolKey poolKey;
    PoolId poolId;

    uint256 constant REWARD_AMOUNT = 100e18;
    uint256 constant MIN_LIQUIDITY = 1e18;
    uint256 constant LOCKUP_DURATION = 7 days;
    uint256 constant BOUNTY_BUDGET = 10 * REWARD_AMOUNT;

    function setUp() public {
        string memory rpcUrl = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl);

        // Deploy and sort pool tokens so currency0 < currency1
        MockERC20 tokenA = new MockERC20("TokenA", "TKA", 18);
        MockERC20 tokenB = new MockERC20("TokenB", "TKB", 18);
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);
        currency0 = Currency.wrap(address(tokenA));
        currency1 = Currency.wrap(address(tokenB));

        // Deploy hook at the FLAGS address against the real Sepolia PoolManager
        deployCodeTo(
            "SamanaHook.sol:SamanaHook", abi.encode(address(SEPOLIA_POOL_MANAGER), address(this)), address(FLAGS)
        );
        hook = SamanaHook(address(FLAGS));

        // Router deployed against the forked manager; approvals go to the router
        // (router calls ERC20.transferFrom(testContract, manager, amount) in callback)
        modifyLiquidityRouter = new PoolModifyLiquidityTest(SEPOLIA_POOL_MANAGER);
        tokenA.mint(address(this), 1_000_000e18);
        tokenB.mint(address(this), 1_000_000e18);
        tokenA.approve(address(modifyLiquidityRouter), type(uint256).max);
        tokenB.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Initialize the pool
        poolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();
        SEPOLIA_POOL_MANAGER.initialize(poolKey, SQRT_PRICE_1_1);

        // Set up bounty token
        bountyToken = new MockERC20("BountyToken", "BTK", 18);
        bountyToken.mint(address(this), BOUNTY_BUDGET * 20);
        bountyToken.approve(address(hook), type(uint256).max);
        hook.setBountyToken(address(bountyToken));

        // Advance past twapWindow so createBounty calls don't hit PoolTooYoung.
        vm.warp(block.timestamp + hook.twapWindow());
    }

    // Full lifecycle: bounty creation → LP qualifies → lockup expires → claim reward.
    function test_fork_fullLifecycle() public {
        hook.createBounty(poolKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 0, BOUNTY_BUDGET);

        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, "");

        address lp = address(modifyLiquidityRouter);
        (, bool qualified,,, uint256 pending) = hook.lpState(poolId, lp);
        assertTrue(qualified, "LP should qualify after crossing minLiquidity");
        assertEq(pending, REWARD_AMOUNT, "pending reward should equal rewardAmount");

        vm.warp(block.timestamp + LOCKUP_DURATION + 1);

        uint256 balBefore = bountyToken.balanceOf(lp);
        vm.prank(lp);
        hook.claimReward(poolKey);

        assertEq(bountyToken.balanceOf(lp) - balBefore, REWARD_AMOUNT, "LP should receive full reward after lockup");
        (, bool qualifiedAfter,,, uint256 pendingAfter) = hook.lpState(poolId, lp);
        assertTrue(qualifiedAfter, "qualified flag persists after claim");
        assertEq(pendingAfter, 0, "pending cleared after claim");
    }

    // Bounty deactivated mid-flight; LP can still claim after lockup.
    function test_fork_claimAfterDeactivation() public {
        hook.createBounty(poolKey, REWARD_AMOUNT, MIN_LIQUIDITY, LOCKUP_DURATION, 0, BOUNTY_BUDGET);
        modifyLiquidityRouter.modifyLiquidity(poolKey, LIQUIDITY_PARAMS, "");

        hook.deactivateBounty(poolKey, address(this));
        (, bool active,,,,,) = hook.bounties(poolId);
        assertFalse(active, "bounty should be inactive");

        vm.warp(block.timestamp + LOCKUP_DURATION + 1);

        address lp = address(modifyLiquidityRouter);
        uint256 balBefore = bountyToken.balanceOf(lp);
        vm.prank(lp);
        hook.claimReward(poolKey);
        assertEq(bountyToken.balanceOf(lp) - balBefore, REWARD_AMOUNT, "LP claims after deactivation");
    }
}
