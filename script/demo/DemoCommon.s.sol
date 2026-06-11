// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SamanaHook} from "../../src/SamanaHook.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Shared token interface (demo tokens have open mint)
// ─────────────────────────────────────────────────────────────────────────────

interface IDemoToken {
    function mint(address to, uint256 amount) external;
}

// ─────────────────────────────────────────────────────────────────────────────
// ILPActor — minimal interface for interacting with deployed LPActors
// ─────────────────────────────────────────────────────────────────────────────

interface ILPActor {
    function claimReward(PoolKey calldata key) external;
    function withdrawToken(address token) external;
    function claimAndWithdraw(PoolKey calldata key, address token) external;
}

// ─────────────────────────────────────────────────────────────────────────────
// LPActor
//
// Acts as both the Uniswap v4 router and the LP. Because SamanaHook records
// msg.sender from within the PoolManager unlock callback, the qualifying
// identity is the router address. Using the same contract for both roles
// lets claimReward be called from address(lpActor) — matching the recorded LP.
// ─────────────────────────────────────────────────────────────────────────────

contract LPActor is IUnlockCallback {
    using SafeERC20 for IERC20;

    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IPoolManager immutable manager;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    SamanaHook immutable hook;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address immutable owner;

    constructor(IPoolManager _manager, SamanaHook _hook) {
        manager = _manager;
        hook = _hook;
        owner = msg.sender;
    }

    function addLiquidity(PoolKey calldata key, ModifyLiquidityParams calldata params) external {
        require(msg.sender == owner, "only owner");
        manager.unlock(abi.encode(key, params));
    }

    /// @notice Mints both pool tokens to itself, then adds liquidity - a single tx
    ///         instead of two mints plus an add. Demo tokens clamp mints to 10,000e18
    ///         per call, so minting loops internally.
    function mintAndAddLiquidity(
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        uint256 amount0,
        uint256 amount1
    ) external {
        require(msg.sender == owner, "only owner");
        _mintChunked(Currency.unwrap(key.currency0), amount0);
        _mintChunked(Currency.unwrap(key.currency1), amount1);
        manager.unlock(abi.encode(key, params));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (PoolKey memory key, ModifyLiquidityParams memory params) = abi.decode(data, (PoolKey, ModifyLiquidityParams));

        (BalanceDelta delta,) = manager.modifyLiquidity(key, params, "");

        int256 raw = BalanceDelta.unwrap(delta);
        // forge-lint: disable-next-line(unsafe-typecast)
        int128 a0 = int128(raw >> 128);
        // forge-lint: disable-next-line(unsafe-typecast)
        int128 a1 = int128(raw);

        // forge-lint: disable-next-line(unsafe-typecast)
        if (a0 < 0) _settle(key.currency0, uint128(-a0));
        // forge-lint: disable-next-line(unsafe-typecast)
        if (a1 < 0) _settle(key.currency1, uint128(-a1));
        // forge-lint: disable-next-line(unsafe-typecast)
        if (a0 > 0) manager.take(key.currency0, address(this), uint128(a0));
        // forge-lint: disable-next-line(unsafe-typecast)
        if (a1 > 0) manager.take(key.currency1, address(this), uint128(a1));

        return abi.encode(delta);
    }

    function claimReward(PoolKey calldata key) external {
        require(msg.sender == owner, "only owner");
        hook.claimReward(key);
    }

    function withdrawToken(address token) external {
        require(msg.sender == owner, "only owner");
        IERC20(token).safeTransfer(owner, IERC20(token).balanceOf(address(this)));
    }

    /// @notice Claim the pending reward and forward it to the owner in one tx.
    function claimAndWithdraw(PoolKey calldata key, address token) external {
        require(msg.sender == owner, "only owner");
        hook.claimReward(key);
        IERC20(token).safeTransfer(owner, IERC20(token).balanceOf(address(this)));
    }

    function _settle(Currency currency, uint128 amount) internal {
        manager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(manager), amount);
        manager.settle();
    }

    function _mintChunked(address token, uint256 amount) internal {
        while (amount > 0) {
            uint256 chunk = amount > 10_000e18 ? 10_000e18 : amount;
            IDemoToken(token).mint(address(this), chunk);
            amount -= chunk;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// DemoBase — shared constants and helpers for all demo scripts.
// Update HOOK here when redeploying; everything else follows.
// ─────────────────────────────────────────────────────────────────────────────

abstract contract DemoBase is Script {
    using PoolIdLibrary for PoolKey;

    IPoolManager constant POOL_MANAGER = IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
    SamanaHook constant HOOK = SamanaHook(0x597cb94f36f8ECA3a450c7f13C237e4D667E9680);
    address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant CURRENCY0 = 0xe24Df7dd2ea0Ed4258EE295dc663F57a2198ed7F; // DALPHA
    address constant CURRENCY1 = 0xeda8fb2a4b1f00d05bA5aa898562D92Eb18cfdCA; // DBETA

    // Pool parameters
    uint24 constant POOL_FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    // Bounty parameters
    uint256 constant REWARD_AMOUNT = 5e6; // 5 USDC per qualifying LP
    uint128 constant MIN_LIQUIDITY = 1e18;
    uint256 constant LOCKUP_DURATION = 10 seconds;
    uint32 constant TWAP_WINDOW = 30; // short demo window so the post-swap price dominates the exit TWAP
    uint16 constant IL_COVERAGE_BPS = 10000; // 100% IL coverage
    uint256 constant BOUNTY_BUDGET = 15e6; // 15 USDC (10% fee deducted on deposit)

    function _liquidityParams() internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0});
    }

    // Wide full-range params — needed for IL to be recorded (entryPrice requires broad exposure)
    function _wideLiquidityParams() internal pure returns (ModifyLiquidityParams memory) {
        int24 ts = TICK_SPACING;
        return ModifyLiquidityParams({
            tickLower: (TickMath.MIN_TICK / ts) * ts,
            tickUpper: (TickMath.MAX_TICK / ts) * ts,
            liquidityDelta: 100e18,
            salt: 0
        });
    }

    // Format a 6-decimal USDC amount as a human-readable string, e.g. 5000000 -> "5.000000"
    function _formatUsdc(uint256 amount) internal pure returns (string memory) {
        // frac + 1e6 always renders as 7 digits; drop the leading "1" to get the zero-padded fraction
        bytes memory padded = bytes(vm.toString(amount % 1e6 + 1e6));
        bytes memory frac = new bytes(6);
        for (uint256 i = 0; i < 6; i++) {
            frac[i] = padded[i + 1];
        }
        return string.concat(vm.toString(amount / 1e6), ".", string(frac));
    }

    // ANSI helpers for demo logs: green for values, yellow for key concepts.
    // Colors render when forge writes to a terminal; forge strips them when piped.
    function _green(string memory s) internal pure returns (string memory) {
        return string.concat("\x1b[32m", s, "\x1b[0m");
    }

    function _yellow(string memory s) internal pure returns (string memory) {
        return string.concat("\x1b[33m", s, "\x1b[0m");
    }

    function _buildKey() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(CURRENCY0),
            currency1: Currency.wrap(CURRENCY1),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(HOOK))
        });
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Swapper — executes a single swap via the PoolManager unlock/callback pattern
// ─────────────────────────────────────────────────────────────────────────────

contract Swapper is IUnlockCallback {
    using SafeERC20 for IERC20;

    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IPoolManager immutable manager;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address immutable owner;

    // TickMath boundary constants
    uint160 constant MIN_SQRT_PRICE = 4295128739;
    uint160 constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    constructor(IPoolManager _manager) {
        manager = _manager;
        owner = msg.sender;
    }

    /// @param sqrtPriceLimitX96 Price at which the swap stops; pass 0 for the tick boundary.
    function swap(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) external {
        require(msg.sender == owner, "only owner");
        _swap(key, zeroForOne, amountSpecified, sqrtPriceLimitX96);
    }

    /// @notice Mints the input token to itself (chunked; demo tokens clamp mints to
    ///         10,000e18 per call), then swaps - a single tx instead of N mints plus a swap.
    function mintAndSwap(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        uint256 mintAmount
    ) external {
        require(msg.sender == owner, "only owner");
        address tokenIn = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        while (mintAmount > 0) {
            uint256 chunk = mintAmount > 10_000e18 ? 10_000e18 : mintAmount;
            IDemoToken(tokenIn).mint(address(this), chunk);
            mintAmount -= chunk;
        }
        _swap(key, zeroForOne, amountSpecified, sqrtPriceLimitX96);
    }

    function _swap(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) internal {
        if (sqrtPriceLimitX96 == 0) {
            sqrtPriceLimitX96 = zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1;
        }
        manager.unlock(abi.encode(key, zeroForOne, amountSpecified, sqrtPriceLimitX96));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) =
            abi.decode(data, (PoolKey, bool, int256, uint160));

        BalanceDelta delta = manager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            ""
        );

        int256 raw = BalanceDelta.unwrap(delta);
        // forge-lint: disable-next-line(unsafe-typecast)
        int128 a0 = int128(raw >> 128);
        // forge-lint: disable-next-line(unsafe-typecast)
        int128 a1 = int128(raw);

        // forge-lint: disable-next-line(unsafe-typecast)
        if (a0 < 0) _settle(key.currency0, uint128(-a0));
        // forge-lint: disable-next-line(unsafe-typecast)
        if (a1 < 0) _settle(key.currency1, uint128(-a1));
        // forge-lint: disable-next-line(unsafe-typecast)
        if (a0 > 0) manager.take(key.currency0, address(this), uint128(a0));
        // forge-lint: disable-next-line(unsafe-typecast)
        if (a1 > 0) manager.take(key.currency1, address(this), uint128(a1));

        return abi.encode(delta);
    }

    function _settle(Currency currency, uint128 amount) internal {
        manager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(manager), amount);
        manager.settle();
    }
}
