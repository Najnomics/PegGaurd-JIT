// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BaseOverrideFee} from "@openzeppelin/uniswap-hooks/src/fee/BaseOverrideFee.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {PythOracleAdapter} from "./oracle/PythOracleAdapter.sol";

contract PegGuardHook is BaseOverrideFee, AccessControl {
    using PoolIdLibrary for PoolKey;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint256 public constant VOLATILITY_THRESHOLD_BPS = 100; // 1%
    uint256 public constant DEPEG_THRESHOLD_BPS = 50; // 0.5%
    uint256 public constant MIN_RESERVE_CUT_BPS = 2000; // 20%
    uint256 public constant MAX_RESERVE_CUT_BPS = 5000; // 50%
    uint256 public constant MIN_REBATE_BPS = 500; // 0.05%
    uint256 public constant REBATE_SCALE_BPS = 10; // 0.001% per 10 bps reduction

    uint24 public constant DEFAULT_BASE_FEE = 3000; // 0.3%
    uint24 public constant DEFAULT_MAX_FEE = 50_000; // 5%
    uint24 public constant DEFAULT_MIN_FEE = 500; // 0.05%
    uint24 public constant ALERT_FEE_PREMIUM = 200; // 0.02%
    uint24 public constant CRISIS_FEE_PREMIUM = 600; // 0.06%
    uint24 public constant JIT_ACTIVE_PREMIUM = 100; // 0.01%

    enum PoolMode {
        Calm,
        Alert,
        Crisis
    }

    struct PoolConfig {
        bytes32 priceFeedId0;
        bytes32 priceFeedId1;
        uint24 baseFee;
        uint24 maxFee;
        uint24 minFee;
        uint256 reserveCutBps;
        uint256 volatilityThresholdBps;
        uint256 depegThresholdBps;
        int24 targetTickLower;
        int24 targetTickUpper;
        bool targetRangeSet;
        bool enforceAllowlist;
    }

    struct PoolState {
        PoolMode mode;
        bool jitLiquidityActive;
        bool enforceAllowlist;
        uint256 lastDepegBps;
        uint256 lastConfidenceBps;
        uint24 lastOverrideFee;
        uint256 reserveBalance;
        uint256 totalPenaltyFees;
        uint256 totalRebates;
    }

    struct ConfigurePoolParams {
        bytes32 priceFeedId0;
        bytes32 priceFeedId1;
        uint24 baseFee;
        uint24 maxFee;
        uint24 minFee;
        uint256 reserveCutBps;
        uint256 volatilityThresholdBps;
        uint256 depegThresholdBps;
    }

    struct FeeContext {
        uint24 baseFee;
        uint24 maxFee;
        uint24 minFee;
        uint24 feeFloor;
        uint256 reserveCutBps;
        uint256 volatilityThresholdBps;
        uint256 depegThresholdBps;
    }

    mapping(PoolId => PoolConfig) public poolConfigs;
    mapping(PoolId => PoolState) public poolStates;
    
    // Separate mappings for reliable storage reads
    // These track the actual values set, independent of struct storage
    mapping(PoolId => bool) private _enforceAllowlistFlags;
    mapping(PoolId => bool) private _jitActiveFlags;

    PythOracleAdapter public immutable pythAdapter;
    address public immutable reserveToken;

    bool public paused;

    error MissingPriceFeeds();
    error InvalidAmount();
    error InsufficientReserve();
    error UnauthorizedLiquidityProvider();
    error TargetRangeViolation();
    error InvalidTargetRange();
    error ReserveTokenNotSet();

    event PoolConfigured(PoolId indexed poolId, bytes32 feed0, bytes32 feed1, uint24 baseFee);
    event PoolModeUpdated(PoolId indexed poolId, PoolMode mode);
    event JITWindowUpdated(PoolId indexed poolId, bool active);
    event ReserveSynced(PoolId indexed poolId, uint256 newBalance);
    event FeeOverrideApplied(PoolId indexed poolId, uint24 fee, bool penalty);
    event Paused(address indexed account, bool value);
    event TargetRangeUpdated(PoolId indexed poolId, int24 tickLower, int24 tickUpper);
    event LiquidityPolicyUpdated(PoolId indexed poolId, bool enforceAllowlist);
    event LiquidityAllowlistUpdated(PoolId indexed poolId, address indexed account, bool allowed);
    event TargetRange(PoolId indexed poolId, int24 tickLower, int24 tickUpper);
    event DepegPenaltyApplied(PoolId indexed poolId, bool zeroForOne, uint24 fee, uint256 reserveAmount);
    event DepegRebateIssued(PoolId indexed poolId, address trader, uint256 amount);
    event DebugAllowlist(PoolId indexed poolId, bool stateEnforce, bool configEnforce, bool enforceAllowlist, bool jitActive, address sender);
    mapping(PoolId => mapping(address => bool)) private poolAllowlist;

    constructor(IPoolManager _poolManager, address _pythAdapter, address _reserveToken, address admin)
        BaseOverrideFee(_poolManager)
    {
        pythAdapter = PythOracleAdapter(_pythAdapter);
        reserveToken = _reserveToken;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(CONFIG_ROLE, admin);
        _grantRole(KEEPER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    modifier whenNotPaused() {
        require(!paused, "PegGuardHook: paused");
        _;
    }

    function setPaused(bool value) external onlyRole(PAUSER_ROLE) {
        paused = value;
        emit Paused(msg.sender, value);
    }

    function configurePool(PoolKey calldata key, ConfigurePoolParams calldata params) external onlyRole(CONFIG_ROLE) {
        PoolId poolId = key.toId();
        PoolConfig storage config = poolConfigs[poolId];

        if (params.priceFeedId0 != bytes32(0)) config.priceFeedId0 = params.priceFeedId0;
        if (params.priceFeedId1 != bytes32(0)) config.priceFeedId1 = params.priceFeedId1;
        if (params.baseFee != 0) config.baseFee = params.baseFee;
        if (params.maxFee != 0) config.maxFee = params.maxFee;
        if (params.minFee != 0) config.minFee = params.minFee;
        if (params.reserveCutBps != 0) config.reserveCutBps = _clampReserveCut(params.reserveCutBps);
        if (params.volatilityThresholdBps != 0) config.volatilityThresholdBps = params.volatilityThresholdBps;
        if (params.depegThresholdBps != 0) config.depegThresholdBps = params.depegThresholdBps;

        if (config.baseFee == 0) config.baseFee = DEFAULT_BASE_FEE;
        if (config.maxFee == 0) config.maxFee = DEFAULT_MAX_FEE;
        if (config.minFee == 0) config.minFee = DEFAULT_MIN_FEE;
        if (config.reserveCutBps == 0) config.reserveCutBps = MIN_RESERVE_CUT_BPS;
        if (config.volatilityThresholdBps == 0) config.volatilityThresholdBps = VOLATILITY_THRESHOLD_BPS;
        if (config.depegThresholdBps == 0) config.depegThresholdBps = DEPEG_THRESHOLD_BPS;

        if (config.priceFeedId0 == bytes32(0) || config.priceFeedId1 == bytes32(0)) {
            revert MissingPriceFeeds();
        }

        emit PoolConfigured(poolId, config.priceFeedId0, config.priceFeedId1, config.baseFee);
    }

    function setPoolMode(PoolKey calldata key, PoolMode mode) external onlyRole(KEEPER_ROLE) whenNotPaused {
        PoolId poolId = key.toId();
        poolStates[poolId].mode = mode;
        emit PoolModeUpdated(poolId, mode);
    }

    function setJITWindow(PoolKey calldata key, bool active) external onlyRole(KEEPER_ROLE) whenNotPaused {
        PoolId poolId = key.toId();
        PoolState storage state = poolStates[poolId];
        if (state.jitLiquidityActive == active && _jitActiveFlags[poolId] == active) return;
        state.jitLiquidityActive = active;
        _jitActiveFlags[poolId] = active; // Track in separate mapping
        emit JITWindowUpdated(poolId, active);
    }

    function reportReserveDelta(PoolKey calldata key, int256 delta) external onlyRole(KEEPER_ROLE) whenNotPaused {
        if (delta == 0) revert InvalidAmount();
        PoolId poolId = key.toId();
        PoolState storage state = poolStates[poolId];

        if (delta > 0) {
            state.reserveBalance += uint256(delta);
        } else {
            uint256 amount = uint256(-delta);
            if (state.reserveBalance < amount) revert InsufficientReserve();
            state.reserveBalance -= amount;
        }

        emit ReserveSynced(poolId, state.reserveBalance);
    }

    function fundReserve(PoolKey calldata key, uint256 amount) external onlyRole(ADMIN_ROLE) whenNotPaused {
        _transferReserveIn(amount);
        PoolId poolId = key.toId();
        poolStates[poolId].reserveBalance += amount;
        emit ReserveSynced(poolId, poolStates[poolId].reserveBalance);
    }

    function withdrawReserve(PoolKey calldata key, address recipient, uint256 amount)
        external
        onlyRole(ADMIN_ROLE)
        whenNotPaused
    {
        _decreaseReserve(key.toId(), amount);
        IERC20(reserveToken).transfer(recipient, amount);
        emit ReserveSynced(key.toId(), poolStates[key.toId()].reserveBalance);
    }

    function issueRebate(PoolKey calldata key, address trader, uint256 amount)
        external
        onlyRole(KEEPER_ROLE)
        whenNotPaused
    {
        _decreaseReserve(key.toId(), amount);
        PoolState storage state = poolStates[key.toId()];
        state.totalRebates += amount;
        IERC20(reserveToken).transfer(trader, amount);
        emit DepegRebateIssued(key.toId(), trader, amount);
    }

    /// @notice Calculate rebate amount from reserve balance using Sentinel's logic
    /// @param poolId The pool ID
    /// @param depegReductionBps The reduction in depeg (in basis points) achieved by the trade
    /// @return rebateAmount The calculated rebate amount in reserve token
    function calculateRebateFromReserve(PoolId poolId, uint256 depegReductionBps)
        external
        view
        returns (uint256 rebateAmount)
    {
        PoolState storage state = poolStates[poolId];
        if (state.reserveBalance == 0) return 0;
        
        // Sentinel's rebate formula: MIN_REBATE_BPS + (depeg reduction * REBATE_SCALE_BPS)
        uint256 rebateBps = MIN_REBATE_BPS;
        if (depegReductionBps > 0) {
            rebateBps += (depegReductionBps / 10) * REBATE_SCALE_BPS;
        }
        
        // Calculate rebate amount from reserve balance
        rebateAmount = (state.reserveBalance * rebateBps) / 10_000;
        
        // Cap rebate at available reserve
        if (rebateAmount > state.reserveBalance) {
            rebateAmount = state.reserveBalance;
        }
    }

    function getPoolSnapshot(PoolKey calldata key)
        external
        view
        returns (PoolConfig memory config, PoolState memory state)
    {
        PoolId poolId = key.toId();
        config = poolConfigs[poolId];
        PoolState storage storedState = poolStates[poolId];
        config.enforceAllowlist = storedState.enforceAllowlist;
        state = storedState;
    }

    function setTargetRange(PoolKey calldata key, int24 tickLower, int24 tickUpper) external onlyRole(CONFIG_ROLE) {
        if (tickLower >= tickUpper) revert InvalidTargetRange();
        PoolId poolId = key.toId();
        PoolConfig storage config = poolConfigs[poolId];
        config.targetTickLower = tickLower;
        config.targetTickUpper = tickUpper;
        config.targetRangeSet = true;
        emit TargetRangeUpdated(poolId, tickLower, tickUpper);
        emit TargetRange(poolId, tickLower, tickUpper);
    }

    function clearTargetRange(PoolKey calldata key) external onlyRole(CONFIG_ROLE) {
        PoolId poolId = key.toId();
        PoolConfig storage config = poolConfigs[poolId];
        config.targetRangeSet = false;
        config.targetTickLower = 0;
        config.targetTickUpper = 0;
        emit TargetRangeUpdated(poolId, 0, 0);
        emit TargetRange(poolId, 0, 0);
    }

    function setLiquidityPolicy(PoolKey calldata key, bool enforceAllowlist) external onlyRole(CONFIG_ROLE) {
        PoolId poolId = key.toId();
        poolConfigs[poolId].enforceAllowlist = enforceAllowlist;
        poolStates[poolId].enforceAllowlist = enforceAllowlist;
        _enforceAllowlistFlags[poolId] = enforceAllowlist; // Track in separate mapping
        emit LiquidityPolicyUpdated(poolId, enforceAllowlist);
    }

    function updateLiquidityAllowlist(PoolKey calldata key, address account, bool allowed)
        external
        onlyRole(CONFIG_ROLE)
    {
        PoolId poolId = key.toId();
        poolAllowlist[poolId][account] = allowed;
        emit LiquidityAllowlistUpdated(poolId, account, allowed);
    }

    function isAllowlisted(PoolKey calldata key, address account) external view returns (bool) {
        return poolAllowlist[key.toId()][account];
    }

    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        super._afterInitialize(sender, key, sqrtPriceX96, tick);
        PoolId poolId = key.toId();
        PoolConfig storage config = poolConfigs[poolId];
        if (config.baseFee == 0) config.baseFee = DEFAULT_BASE_FEE;
        return this.afterInitialize.selector;
    }

    function _getFee(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (uint24)
    {
        PoolId poolId = key.toId();
        PoolConfig storage config = poolConfigs[poolId];
        PoolState storage state = poolStates[poolId];
        bool zeroForOne = params.zeroForOne;

        FeeContext memory ctx;
        ctx.baseFee = config.baseFee == 0 ? DEFAULT_BASE_FEE : config.baseFee;
        ctx.maxFee = config.maxFee == 0 ? DEFAULT_MAX_FEE : config.maxFee;
        ctx.minFee = config.minFee == 0 ? DEFAULT_MIN_FEE : config.minFee;
        ctx.feeFloor = ctx.baseFee + _modePremium(state.mode);
        if (state.jitLiquidityActive) ctx.feeFloor += JIT_ACTIVE_PREMIUM;
        if (ctx.feeFloor > ctx.maxFee) ctx.feeFloor = ctx.maxFee;
        ctx.reserveCutBps = config.reserveCutBps == 0 ? MIN_RESERVE_CUT_BPS : config.reserveCutBps;
        ctx.volatilityThresholdBps =
            config.volatilityThresholdBps == 0 ? VOLATILITY_THRESHOLD_BPS : config.volatilityThresholdBps;
        ctx.depegThresholdBps = config.depegThresholdBps == 0 ? DEPEG_THRESHOLD_BPS : config.depegThresholdBps;

        if (paused || config.priceFeedId0 == bytes32(0) || config.priceFeedId1 == bytes32(0)) {
            state.lastOverrideFee = ctx.feeFloor;
            return ctx.feeFloor;
        }

        // Try to get prices, but handle stale feeds gracefully
        bool staleFeed = false;
        int64 price0;
        int64 price1;
        uint64 conf0;
        uint64 conf1;
        
        try pythAdapter.getPriceWithConfidence(config.priceFeedId0) returns (int64 _price0, uint64 _conf0, uint256) {
            price0 = _price0;
            conf0 = _conf0;
        } catch {
            staleFeed = true;
        }
        
        try pythAdapter.getPriceWithConfidence(config.priceFeedId1) returns (int64 _price1, uint64 _conf1, uint256) {
            price1 = _price1;
            conf1 = _conf1;
        } catch {
            staleFeed = true;
        }

        // Fall back to base fee if feeds are stale
        if (staleFeed) {
            state.lastOverrideFee = ctx.feeFloor;
            return ctx.feeFloor;
        }

        uint256 confRatioBps =
            (pythAdapter.computeConfRatioBps(price0, conf0) + pythAdapter.computeConfRatioBps(price1, conf1)) / 2;
        state.lastConfidenceBps = confRatioBps;

        if (confRatioBps > ctx.volatilityThresholdBps) {
            state.lastOverrideFee = ctx.feeFloor;
            return ctx.feeFloor;
        }

        uint256 depegBps = _computeDepegBps(price0, price1);
        state.lastDepegBps = depegBps;

        if (depegBps <= ctx.depegThresholdBps) {
            state.lastOverrideFee = ctx.feeFloor;
            return ctx.feeFloor;
        }

        bool worsensDepeg = (price0 < price1 && zeroForOne) || (price0 > price1 && !zeroForOne);
        uint24 dynamicFee;

        if (worsensDepeg) {
            dynamicFee = _applyPenalty(poolId, state, ctx, depegBps, zeroForOne);
        } else {
            dynamicFee = _applyRebate(poolId, state, ctx, depegBps);
        }

        state.lastOverrideFee = dynamicFee;
        return dynamicFee;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions = super.getHookPermissions();
        permissions.beforeAddLiquidity = true;
        permissions.beforeRemoveLiquidity = true;
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        // Read directly from storage mappings (same approach as getPoolSnapshot)
        PoolConfig storage config = poolConfigs[poolId];
        PoolState storage storedState = poolStates[poolId];
        
        // Check if allowlist enforcement is needed
        // Use separate mappings first, then fall back to struct storage (same as getPoolSnapshot)
        bool enforceAllowlist = _enforceAllowlistFlags[poolId];
        if (!enforceAllowlist) {
            // Fall back to struct storage (same pattern as getPoolSnapshot)
            enforceAllowlist = storedState.enforceAllowlist || config.enforceAllowlist;
        }
        bool jitActive = _jitActiveFlags[poolId] || storedState.jitLiquidityActive;
        bool mustBeAllowlisted = jitActive || enforceAllowlist;
        
        // In Uniswap v4, the sender is the caller (e.g., PositionManager)
        // We need to check if the sender is allowlisted
        address liquidityProvider = sender;
        
        // Try to get the actual owner if sender is a PositionManager/router
        // For now, we check the sender directly (PositionManager should be allowlisted)
        emit DebugAllowlist(poolId, storedState.enforceAllowlist, config.enforceAllowlist, enforceAllowlist, jitActive, liquidityProvider);
        _enforceAddPolicy(poolId, liquidityProvider, mustBeAllowlisted);

        // Enforce target range when JIT is active (regardless of allowlist state)
        // Also check config.targetRangeSet to ensure range is configured
        if (jitActive && config.targetRangeSet) {
            if (params.tickLower < config.targetTickLower || params.tickUpper > config.targetTickUpper) {
                revert TargetRangeViolation();
            }
        }
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        PoolState storage state = poolStates[poolId];
        // During JIT crisis mode, only allowlisted providers can remove liquidity
        if (state.jitLiquidityActive) {
            address liquidityProvider = sender;
            _enforceAddPolicy(poolId, liquidityProvider, true);
        }
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _computeDepegBps(int64 price0, int64 price1) internal pure returns (uint256) {
        int256 diff = int256(price0) - int256(price1);
        if (diff < 0) diff = -diff;
        int256 denomSigned = int256(price1);
        uint256 denom = uint256(denomSigned >= 0 ? denomSigned : -denomSigned);
        if (denom == 0) denom = 1;
        return (uint256(diff) * 10_000) / denom;
    }

    function _modePremium(PoolMode mode) internal pure returns (uint24) {
        if (mode == PoolMode.Alert) return ALERT_FEE_PREMIUM;
        if (mode == PoolMode.Crisis) return CRISIS_FEE_PREMIUM;
        return 0;
    }

    function _applyPenalty(
        PoolId poolId,
        PoolState storage state,
        FeeContext memory ctx,
        uint256 depegBps,
        bool zeroForOne
    ) internal returns (uint24 dynamicFee) {
        uint24 penalty = uint24((depegBps / 10) * 100);
        dynamicFee = ctx.feeFloor + penalty;
        if (dynamicFee > ctx.maxFee) dynamicFee = ctx.maxFee;
        
        uint24 penaltyAmount = dynamicFee > ctx.feeFloor ? dynamicFee - ctx.feeFloor : 0;
        state.totalPenaltyFees += penaltyAmount;
        
        // Calculate reserve amount based on penalty and reserve cut
        // Note: In Uniswap v4, fees are collected by the pool and distributed to LPs.
        // The reserve cut represents the portion that should be allocated to the reserve.
        // Actual sweeping would need to happen via a separate mechanism (keeper calling sweepPenaltyFees).
        // For now, we track the amount and emit it in the event.
        uint256 reserveAmount = 0; // Will be calculated when fees are actually swept
        if (penaltyAmount > 0 && reserveToken != address(0)) {
            // The reserve amount would be calculated from actual fee collection
            // This is a placeholder - actual implementation would need fee accounting
            reserveAmount = (uint256(penaltyAmount) * ctx.reserveCutBps) / 10_000;
        }
        
        emit DepegPenaltyApplied(poolId, zeroForOne, dynamicFee, reserveAmount);
        emit FeeOverrideApplied(poolId, dynamicFee, true);
    }

    function _applyRebate(PoolId poolId, PoolState storage state, FeeContext memory ctx, uint256 depegBps)
        internal
        returns (uint24 dynamicFee)
    {
        uint24 rebate = uint24((depegBps / 20) * 50);
        if (rebate >= ctx.feeFloor || ctx.feeFloor - rebate < ctx.minFee) {
            dynamicFee = ctx.minFee;
        } else {
            dynamicFee = ctx.feeFloor - rebate;
        }
        if (dynamicFee < ctx.minFee) dynamicFee = ctx.minFee;
        
        uint24 rebateAmount = ctx.feeFloor > dynamicFee ? ctx.feeFloor - dynamicFee : 0;
        // Track rebate fee reduction (actual token rebate is issued separately via issueRebate)
        state.totalRebates += rebateAmount;
        
        emit FeeOverrideApplied(poolId, dynamicFee, false);
    }

    function _enforceAddPolicy(PoolId poolId, address sender, bool mustBeAllowlisted) internal view {
        if (!mustBeAllowlisted) return;
        if (poolAllowlist[poolId][sender]) return;
        revert UnauthorizedLiquidityProvider();
    }

    function _transferReserveIn(uint256 amount) internal {
        if (reserveToken == address(0)) revert ReserveTokenNotSet();
        if (amount == 0) revert InvalidAmount();
        IERC20(reserveToken).transferFrom(msg.sender, address(this), amount);
    }

    function _decreaseReserve(PoolId poolId, uint256 amount) internal {
        if (reserveToken == address(0)) revert ReserveTokenNotSet();
        if (amount == 0) revert InvalidAmount();
        PoolState storage state = poolStates[poolId];
        if (state.reserveBalance < amount) revert InsufficientReserve();
        state.reserveBalance -= amount;
    }

    function _clampReserveCut(uint256 cutBps) internal pure returns (uint256) {
        if (cutBps < MIN_RESERVE_CUT_BPS) return MIN_RESERVE_CUT_BPS;
        if (cutBps > MAX_RESERVE_CUT_BPS) return MAX_RESERVE_CUT_BPS;
        return cutBps;
    }
}
