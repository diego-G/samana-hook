// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseHook} from "uniswap-hooks/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Oracle} from "uniswap-hooks/oracles/panoptic/libraries/Oracle.sol";

/// @title SamanaHook
/// @author diegog.eth
/// @notice Uniswap v4 hook that provides IL insurance and base rewards to LPs who commit liquidity during high-volatility windows.
///
/// @dev Net liquidity is tracked (adds minus removes); cycling adds/removes cannot reach
///      `minLiquidity`. IL insurance uses the pool's own TWAP ring buffer - no external oracle.
///      All amounts in `bountyToken`; protocol fee deducted at deposit.
///
/// @dev Sender caveat: `sender` in hook callbacks is the router, not the end-user LP.
///      Production deployments should encode the real LP address in hookData.
contract SamanaHook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    /// @notice Maximum allowed lockup duration prevents accidental permanent lockups.
    uint256 public constant MAX_LOCKUP = 365 days;

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice Configuration for a single pool's bounty program.
    struct Bounty {
        address creator; // address that created the bounty; can deactivate it
        bool active; // false after deactivation; allows a new bounty on the same pool
        uint256 rewardAmount; // flat base reward per qualifying LP (in bountyToken)
        uint256 minLiquidity; // net liquidity (Uniswap units) an LP must hold to qualify
        uint256 lockupDuration; // seconds the LP's position is locked after qualifying
        uint256 ilCoverageBps; // IL insurance coverage in bps (0 = flat, 10000 = 1:1 IL coverage)
        uint256 budget; // uncommitted reward budget held by this contract (in bountyToken)
    }

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice Bounty configuration per pool.
    mapping(PoolId => Bounty) public bounties;

    /// @notice Per-LP state per pool.
    // forge-lint: disable-next-line(pascal-case-struct)
    struct LPState {
        uint128 liquidity; // net liquidity (adds minus removes); floors at 0; uint128 matches Uniswap's type
        bool qualified; // gates further accumulation
        uint160 entryPrice; // sqrtPriceX96 at qualification; used for IL insurance at claim time
        uint256 lockupEnd; // unix timestamp after which LP may remove; 0 = unlocked
        uint256 pending; // pending reward balance; pull-payment pattern
    }

    mapping(PoolId => mapping(address => LPState)) public lpState;

    /// @notice Single ERC20 token used for all bounty rewards and protocol fees (e.g. USDC).
    address public bountyToken;

    /// @notice Treasury address that receives the protocol fee from bounty funding.
    address public treasury;

    /// @notice Fee charged on bounty funding, in basis points (max 1000 = 10%).
    uint16 public protocolFeeBps;

    /// @notice Number of active bounties (used to prevent owner changes mid-program).
    uint256 public activeBountyCount;

    /// @notice Per-pool tick observation ring buffer for TWAP price computation.
    mapping(PoolId => Oracle.Observation[65535]) private _observations;

    uint16 private constant OBS_CARDINALITY_NEXT = 500; // ring grows to 500 observations (~100 min at 12s blocks)

    struct ObsState {
        uint16 index;
        uint16 cardinality;
    }

    mapping(PoolId => ObsState) private _obsState;

    /// @notice Time window in seconds used for TWAP price at entry and claim.
    ///         0 = use spot price (manipulation-resistant TWAP disabled).
    ///         Default 1800 (30 min). Degrades to all available history if pool is newer.
    uint32 public twapWindow = 1800;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event BountyCreated(
        PoolId indexed poolId,
        address indexed creator,
        uint256 rewardAmount,
        uint256 minLiquidity,
        uint256 lockupDuration,
        uint256 ilCoverageBps,
        uint256 budget
    );
    event BountyDeactivated(PoolId indexed poolId);
    event BountyFunded(PoolId indexed poolId, uint256 amount);
    event RewardAccrued(PoolId indexed poolId, address indexed lp, uint256 amount);
    event RewardClaimed(PoolId indexed poolId, address indexed lp, uint256 total);
    event ILInsurancePaid(PoolId indexed poolId, address indexed lp, uint256 ilBps, uint256 payout);
    event LiquidityLocked(PoolId indexed poolId, address indexed lp, uint256 unlockTime);
    event ProtocolFeeUpdated(uint16 feeBps);
    event TreasuryUpdated(address indexed treasury);
    event BountyTokenUpdated(address indexed bountyToken);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error BountyAlreadyExists();
    error BountyNotActive();
    error ZeroRewardAmount();
    error ZeroFundAmount();
    error LiquidityStillLocked(uint256 unlockTime);
    error InsufficientBudget();
    error LockupTooLong();
    error InvalidPoolKey();
    error InvalidFeeBps();
    error ZeroTreasury();
    error ZeroBountyToken();
    error ActiveBountiesPresent();
    error Unauthorized();
    error PoolTooYoung();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(IPoolManager _poolManager, address initialOwner) BaseHook(_poolManager) Ownable(initialOwner) {}

    // -------------------------------------------------------------------------
    // Owner configuration
    // -------------------------------------------------------------------------

    /// @notice Set the single ERC20 token used for all bounty rewards and fees (e.g. USDC).
    function setBountyToken(address token) external onlyOwner {
        if (activeBountyCount > 0) revert ActiveBountiesPresent();
        bountyToken = token;
        emit BountyTokenUpdated(token);
    }

    /// @notice Set the treasury address that receives protocol fee revenue.
    function setTreasury(address newTreasury) external onlyOwner {
        if (activeBountyCount > 0) revert ActiveBountiesPresent();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    /// @notice Set the TWAP window used for IL price measurement (seconds).
    ///         Set to 0 to use spot price. Longer window = more manipulation-resistant.
    ///         Frozen while any bounty is active: changing the window mid-bounty could
    ///         alter the IL calculation for LPs already locked in.
    function setTwapWindow(uint32 window) external onlyOwner {
        if (activeBountyCount > 0) revert ActiveBountiesPresent();
        twapWindow = window;
    }

    /// @notice Set the protocol fee in basis points (max 10%).
    function setProtocolFeeBps(uint16 feeBps) external onlyOwner {
        if (activeBountyCount > 0) revert ActiveBountiesPresent();
        if (feeBps > 1000) revert InvalidFeeBps();
        protocolFeeBps = feeBps;
        emit ProtocolFeeUpdated(feeBps);
    }

    // -------------------------------------------------------------------------
    // Hook permissions
    // -------------------------------------------------------------------------

    /// @notice Declares which hook callbacks this contract implements.
    /// @dev    Hook address lower bits must match this bitmask (enforced by Uniswap's Hooks library).
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true, // initialises tick observation ring buffer
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: true, // enforces lockup and decrements net liquidity
            afterAddLiquidity: true, // credits rewards
            afterRemoveLiquidity: false,
            beforeSwap: true, // writes tick observation (one per block) for TWAP
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -------------------------------------------------------------------------
    // Bounty management
    // -------------------------------------------------------------------------

    /// @notice Create a bounty for a pool. Only one active bounty per pool is allowed.
    ///
    /// @dev    `key.hooks` must equal `address(this)` so the PoolId matches the pool
    ///         this hook governs. Without this check a creator could fund a bounty for
    ///         a pool with a different hook, locking funds in an unreachable state.
    ///
    ///         Protocol fee deducted from transferred funds before crediting as budget.
    ///
    /// @param key            Uniswap v4 pool key identifying the target pool.
    /// @param rewardAmount   Flat base reward credited to each qualifying LP address (in bountyToken).
    /// @param minLiquidity   Net liquidity (Uniswap units) an LP must hold simultaneously.
    /// @param lockupDuration Seconds the position is locked after qualifying. Capped at MAX_LOCKUP.
    /// @param ilCoverageBps  IL insurance coverage in bps. 0 = flat payout. 10000 = 1:1 IL coverage.
    ///                       Fund extra budget to cover potential IL insurance payouts.
    /// @param amount         bountyToken amount to deposit (fee deducted; remainder becomes budget).
    function createBounty(
        PoolKey calldata key,
        uint256 rewardAmount,
        uint256 minLiquidity,
        uint256 lockupDuration,
        uint256 ilCoverageBps,
        uint256 amount
    ) external {
        if (key.hooks != IHooks(address(this))) revert InvalidPoolKey();

        PoolId poolId = key.toId();
        if (bounties[poolId].active) revert BountyAlreadyExists();
        if (rewardAmount == 0) revert ZeroRewardAmount();
        if (lockupDuration > MAX_LOCKUP) revert LockupTooLong();

        // Require the pool to have at least twapWindow seconds of observation history.
        // Young pools fall back to spot price for IL, making them manipulable; block
        // bounties until a reliable TWAP can be computed. Skipped when twapWindow=0.
        if (twapWindow > 0) {
            ObsState memory obs = _obsState[poolId];
            if (obs.cardinality == 0) revert PoolTooYoung();
            uint16 oldestIdx = uint16((uint256(obs.index) + 1) % obs.cardinality);
            uint32 oldestTs = _observations[poolId][oldestIdx].initialized
                ? _observations[poolId][oldestIdx].blockTimestamp
                : _observations[poolId][0].blockTimestamp;
            if (uint32(block.timestamp) - oldestTs < twapWindow) revert PoolTooYoung();
        }

        _receiveFunds(amount);
        uint256 budget = amount - _collectProtocolFee(amount);

        // Require at least one full reward in the initial budget prevents a creator
        // from opening a slot, locking LPs, and never paying out (ghost bounty attack).
        if (budget < rewardAmount) revert InsufficientBudget();

        bounties[poolId] = Bounty({
            creator: msg.sender,
            rewardAmount: rewardAmount,
            minLiquidity: minLiquidity,
            lockupDuration: lockupDuration,
            ilCoverageBps: ilCoverageBps,
            budget: budget,
            active: true
        });

        unchecked {
            activeBountyCount += 1;
        }

        emit BountyCreated(poolId, msg.sender, rewardAmount, minLiquidity, lockupDuration, ilCoverageBps, budget);
    }

    /// @notice Add more funds to an existing bounty.
    ///
    /// @param key    Pool key identifying which bounty to fund.
    /// @param amount bountyToken amount to deposit (fee deducted; remainder added to budget).
    function fundBounty(PoolKey calldata key, uint256 amount) external {
        PoolId poolId = key.toId();
        Bounty storage bounty = bounties[poolId];
        if (!bounty.active) revert BountyNotActive();
        if (amount == 0) revert ZeroFundAmount();

        _receiveFunds(amount);
        uint256 added = amount - _collectProtocolFee(amount);
        bounty.budget += added;

        emit BountyFunded(poolId, added);
    }

    /// @notice Deactivate a bounty and refund remaining uncommitted budget.
    ///         Callable by the bounty creator or the contract owner.
    ///
    /// @dev    Only uncommitted `budget` is refunded; credited LP rewards and lockups are unchanged.
    ///         Owner may deactivate for emergency/governance; refund always goes to `bounty.creator`.
    ///
    /// @param key Pool key.
    /// @param to  Address that receives the refunded budget (ignored when caller is owner).
    function deactivateBounty(PoolKey calldata key, address to) external {
        PoolId poolId = key.toId();
        Bounty storage bounty = bounties[poolId];
        if (!bounty.active) revert BountyNotActive();

        address refundTo;
        if (msg.sender == bounty.creator) {
            refundTo = to;
        } else if (msg.sender == owner()) {
            refundTo = bounty.creator;
        } else {
            revert Unauthorized();
        }

        uint256 remaining = bounty.budget;
        bounty.budget = 0;
        bounty.active = false;
        if (activeBountyCount > 0) {
            unchecked {
                activeBountyCount -= 1;
            }
        }

        emit BountyDeactivated(poolId);

        // CEI: state updated before external call.
        if (remaining > 0) IERC20(bountyToken).safeTransfer(refundTo, remaining);
    }

    /// @notice Claim any pending reward for the caller in the given pool.
    ///
    /// @dev    IL payout = base × (ilBps / 10000) × (ilCoverageBps / 10000), capped at budget.
    ///         Both prices are TWAP - resistant to single-block manipulation. Zero IL → base only.
    ///         CEI: lp.pending zeroed before transfer (ERC777 defense).
    function claimReward(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        LPState storage lp = lpState[poolId][msg.sender];
        uint256 unlock = lp.lockupEnd;
        if (unlock != 0 && block.timestamp < unlock) revert LiquidityStillLocked(unlock);

        uint256 base = lp.pending;
        if (base == 0) return;

        lp.pending = 0; // CEI: zero before external call

        uint256 total = base;
        Bounty storage bounty = bounties[poolId];

        if (bounty.ilCoverageBps > 0) {
            uint160 entry = lp.entryPrice;
            // entry is 0 for concentrated positions (IL formula inapplicable); skip payout.
            if (entry > 0) {
                (uint160 spotSqrt, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
                uint160 currentSqrt = _getTwapSqrtPrice(poolId, currentTick, spotSqrt);
                if (currentSqrt > 0) {
                    uint256 ilBps = _computeILBps(entry, currentSqrt);
                    if (ilBps > 0) {
                        // payout = base * (ilBps / 10000) * (ilCoverageBps / 10000)
                        uint256 payout =
                            FullMath.mulDiv(FullMath.mulDiv(base, ilBps, 10000), bounty.ilCoverageBps, 10000);
                        uint256 available = bounty.budget;
                        if (payout > available) payout = available;
                        if (payout > 0) {
                            unchecked {
                                bounty.budget -= payout;
                            }
                            total += payout;
                            emit ILInsurancePaid(poolId, msg.sender, ilBps, payout);
                        }
                    }
                }
            }
        }

        IERC20(bountyToken).safeTransfer(msg.sender, total);
        emit RewardClaimed(poolId, msg.sender, total);
    }

    // -------------------------------------------------------------------------
    // Hook implementations
    // -------------------------------------------------------------------------

    /// @dev Seeds the tick observation ring buffer when a pool is first initialised.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        (uint16 card,) = Oracle.initialize(_observations[poolId], uint32(block.timestamp), tick);
        _obsState[poolId] = ObsState({index: 0, cardinality: card});
        return BaseHook.afterInitialize.selector;
    }

    /// @dev Records one tick observation per block for TWAP computation.
    ///      Oracle.write deduplicates within a block, so multiple swaps in the same
    ///      block only write one entry (with the tick at the start of the block).
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        (, int24 tick,,) = StateLibrary.getSlot0(poolManager, poolId);
        ObsState memory obs = _obsState[poolId];
        (uint16 idx, uint16 card) = Oracle.write(
            _observations[poolId],
            obs.index,
            uint32(block.timestamp),
            tick,
            obs.cardinality,
            OBS_CARDINALITY_NEXT,
            type(int24).max // disable panoptic tick-truncation; use full tick range
        );
        _obsState[poolId] = ObsState({index: idx, cardinality: card});
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Accumulates net liquidity; qualifies LP on first crossing `minLiquidity`.
    ///      Reward credited via pull-payment so a failed payout cannot revert liquidity adds.
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        Bounty storage bounty = bounties[poolId];
        LPState storage lp = lpState[poolId][sender];

        if (!bounty.active || params.liquidityDelta <= 0 || lp.qualified) {
            return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }

        lp.liquidity += uint128(uint256(params.liquidityDelta));

        if (lp.liquidity >= bounty.minLiquidity) {
            lp.qualified = true;

            if (bounty.budget >= bounty.rewardAmount) {
                unchecked {
                    bounty.budget -= bounty.rewardAmount; // checked above
                }
                lp.pending += bounty.rewardAmount;
                emit RewardAccrued(poolId, sender, bounty.rewardAmount);

                uint256 unlockTime = block.timestamp + bounty.lockupDuration;
                lp.lockupEnd = unlockTime;
                emit LiquidityLocked(poolId, sender, unlockTime);

                // Snapshot TWAP entry price only for full-range positions; the IL formula
                // is only accurate for full-range (x*y=k). Concentrated LPs receive the
                // base reward only (entryPrice stays 0, claimReward skips IL payout).
                // Usable min/max ticks are the largest multiples of tickSpacing within
                // [MIN_TICK, MAX_TICK]; Solidity division truncates toward zero.
                if (bounty.ilCoverageBps > 0) {
                    int24 ts = key.tickSpacing;
                    // forge-lint: disable-next-line(divide-before-multiply)
                    int24 minUsable = (TickMath.MIN_TICK / ts) * ts;
                    // forge-lint: disable-next-line(divide-before-multiply)
                    int24 maxUsable = (TickMath.MAX_TICK / ts) * ts;
                    if (params.tickLower == minUsable && params.tickUpper == maxUsable) {
                        _snapshotEntryPrice(poolId, lp);
                    }
                }
            }
            // Budget exhausted: LP is qualified (no further accumulation) but gets
            // no reward and no lockup - they may remove freely.
        }

        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @dev Enforces lockup, then decrements net liquidity for unqualified LPs.
    ///      Qualified LPs skip the decrement: post-lockup their liquidity no longer affects qualification.
    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        LPState storage lp = lpState[poolId][sender];
        uint256 unlock = lp.lockupEnd;

        if (unlock != 0 && block.timestamp < unlock) revert LiquidityStillLocked(unlock);

        if (!lp.qualified) {
            uint128 removed = uint128(uint256(-params.liquidityDelta));
            lp.liquidity = removed < lp.liquidity ? lp.liquidity - removed : 0;
        }

        return BaseHook.beforeRemoveLiquidity.selector;
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @dev Reads current pool price and snapshots the TWAP as LP entry price.
    ///      Extracted into its own function to stay within the stack-depth budget of _afterAddLiquidity.
    function _snapshotEntryPrice(PoolId poolId, LPState storage lp) internal {
        (uint160 spotSqrt, int24 tick,,) = StateLibrary.getSlot0(poolManager, poolId);
        lp.entryPrice = _getTwapSqrtPrice(poolId, tick, spotSqrt);
    }

    /// @dev Returns a TWAP sqrtPriceX96 using the pool's own tick observation ring buffer.
    ///      Falls back to `spotSqrt` when no observations exist or pool has less than
    ///      `twapWindow` seconds of history (manipulation risk on young pools).
    function _getTwapSqrtPrice(PoolId poolId, int24 currentTick, uint160 spotSqrt) internal view returns (uint160) {
        if (twapWindow == 0) return spotSqrt;

        ObsState memory obs = _obsState[poolId];
        if (obs.cardinality == 0) return spotSqrt;

        // Mirror Oracle.getSurroundingObservations: oldest is (index+1)%cardinality if initialized,
        // else slot 0. Using the same logic prevents the window from undershooting the Oracle's oldest.
        uint16 oracleOldestIdx = uint16((uint256(obs.index) + 1) % obs.cardinality);
        uint32 oracleOldestTs = _observations[poolId][oracleOldestIdx].initialized
            ? _observations[poolId][oracleOldestIdx].blockTimestamp
            : _observations[poolId][0].blockTimestamp;

        uint32 elapsed = uint32(block.timestamp) - oracleOldestTs;

        // Pool younger than twapWindow: insufficient history for a reliable TWAP; use spot.
        if (elapsed < twapWindow) return spotSqrt;

        uint32 window = twapWindow;

        uint32[] memory ago = new uint32[](2);
        ago[0] = window;
        ago[1] = 0;

        (int56[] memory cumulatives,) = Oracle.observe(
            _observations[poolId],
            uint32(block.timestamp),
            ago,
            currentTick,
            obs.index,
            obs.cardinality,
            type(int24).max
        );

        // forge-lint: disable-next-line(unsafe-typecast)
        int24 avgTick = int24((cumulatives[1] - cumulatives[0]) / int56(uint56(window)));
        return TickMath.getSqrtPriceAtTick(avgTick);
    }

    /// @dev Computes impermanent loss in basis points given two sqrtPriceX96 values.
    ///
    ///      IL = 1 - 2√r / (1 + r), where r = (exitSqrt / entrySqrt)²
    ///
    ///      All arithmetic in Q96 fixed-point via FullMath (512-bit intermediates).
    ///      Returns 0 when price is unchanged or moved in LP's favour (no IL).
    function _computeILBps(uint160 entrySqrt, uint160 exitSqrt) internal pure returns (uint256) {
        uint256 q = FixedPoint96.Q96;
        // sqrtR = exitSqrt / entrySqrt  (Q96)
        uint256 sqrtR = FullMath.mulDiv(exitSqrt, q, entrySqrt);
        // r = sqrtR²  (Q96)
        uint256 r = FullMath.mulDiv(sqrtR, sqrtR, q);
        // holdFrac = 2·sqrtR / (1 + r)  (Q96) - LP value relative to HODL
        uint256 holdFrac = FullMath.mulDiv(2 * sqrtR, q, q + r);
        if (holdFrac >= q) return 0;
        return FullMath.mulDiv(q - holdFrac, 10000, q);
    }

    /// @dev Pulls `amount` of `bountyToken` from msg.sender into this contract.
    function _receiveFunds(uint256 amount) internal {
        if (bountyToken == address(0)) revert ZeroBountyToken();
        IERC20(bountyToken).safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @dev Deducts protocol fee from `amount` (funds already in contract) and sends to treasury.
    ///      Returns the fee deducted so callers can compute net budget.
    function _collectProtocolFee(uint256 amount) internal returns (uint256 fee) {
        if (protocolFeeBps == 0 || amount == 0) return 0;
        if (treasury == address(0)) revert ZeroTreasury();
        fee = FullMath.mulDiv(amount, protocolFeeBps, 10000);
        if (fee == 0) return 0;
        IERC20(bountyToken).safeTransfer(treasury, fee);
    }
}
