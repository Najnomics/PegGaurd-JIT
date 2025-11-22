// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BaseOverrideFee} from "@openzeppelin/uniswap-hooks/src/fee/BaseOverrideFee.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {PythOracleAdapter} from "./oracle/PythOracleAdapter.sol";
import {PegGuardFeeHelper} from "./helpers/PegGuardFeeHelper.sol";
import {PegGuardReserveLib} from "./libraries/PegGuardReserveLib.sol";
import {PegGuardFeeLib} from "./libraries/PegGuardFeeLib.sol";
import {PegGuardLiquidityLib} from "./libraries/PegGuardLiquidityLib.sol";

contract PegGuardHook is BaseOverrideFee {
    using PoolIdLibrary for PoolKey;

    uint256 public constant VOLATILITY_THRESHOLD_BPS = 100; // 1%
    uint256 public constant DEPEG_THRESHOLD_BPS = 50; // 0.5%
    uint256 public constant MIN_RESERVE_CUT_BPS = PegGuardReserveLib.MIN_RESERVE_CUT_BPS;
    uint256 public constant MAX_RESERVE_CUT_BPS = PegGuardReserveLib.MAX_RESERVE_CUT_BPS;

    uint24 public constant DEFAULT_BASE_FEE = 3000; // 0.3%
    uint24 public constant DEFAULT_MAX_FEE = 50_000; // 5%
    uint24 public constant DEFAULT_MIN_FEE = 500; // 0.05%
    uint24 public constant ALERT_FEE_PREMIUM = PegGuardFeeLib.ALERT_FEE_PREMIUM;
    uint24 public constant CRISIS_FEE_PREMIUM = PegGuardFeeLib.CRISIS_FEE_PREMIUM;
    uint24 public constant JIT_ACTIVE_PREMIUM = PegGuardFeeLib.JIT_ACTIVE_PREMIUM;

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
    PegGuardFeeHelper public immutable feeHelper;
    address public admin;

    mapping(address => bool) private _configRole;
    mapping(address => bool) private _keeperRole;
    mapping(address => bool) private _pauserRole;

    bytes32 private constant _ROLE_CONFIG = keccak256("CONFIG_ROLE");
    bytes32 private constant _ROLE_KEEPER = keccak256("KEEPER_ROLE");
    bytes32 private constant _ROLE_PAUSER = keccak256("PAUSER_ROLE");

    error MissingPriceFeeds();
    error InvalidAmount();
    error InsufficientReserve();
    error TargetRangeViolation();
    error InvalidTargetRange();
    error ReserveTokenNotSet();
    error Unauthorized();

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
    event DebugAllowlist(
        PoolId indexed poolId,
        bool stateEnforce,
        bool configEnforce,
        bool enforceAllowlist,
        bool jitActive,
        address sender
    );
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    event RoleUpdated(bytes32 indexed role, address indexed account, bool enabled);
    mapping(PoolId => mapping(address => bool)) private poolAllowlist;

    constructor(IPoolManager _poolManager, address _pythAdapter, address _reserveToken, address admin_)
        BaseOverrideFee(_poolManager)
    {
        if (admin_ == address(0)) revert Unauthorized();
        pythAdapter = PythOracleAdapter(_pythAdapter);
        reserveToken = _reserveToken;
        feeHelper = new PegGuardFeeHelper();
        admin = admin_;

        _setRole(_configRole, _ROLE_CONFIG, admin_, true);
        _setRole(_keeperRole, _ROLE_KEEPER, admin_, true);
        _setRole(_pauserRole, _ROLE_PAUSER, admin_, true);
    }

    modifier whenNotPaused() {
        require(!paused, "PegGuardHook: paused");
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }

    modifier onlyConfig() {
        if (!_hasRole(_configRole, msg.sender)) revert Unauthorized();
        _;
    }

    modifier onlyKeeper() {
        if (!_hasRole(_keeperRole, msg.sender)) revert Unauthorized();
        _;
    }

    modifier onlyPauser() {
        if (!_hasRole(_pauserRole, msg.sender)) revert Unauthorized();
        _;
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert Unauthorized();
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    function setConfigRole(address account, bool enabled) external onlyAdmin {
        _setRole(_configRole, _ROLE_CONFIG, account, enabled);
    }

    function setKeeperRole(address account, bool enabled) external onlyAdmin {
        _setRole(_keeperRole, _ROLE_KEEPER, account, enabled);
    }

    function setPauserRole(address account, bool enabled) external onlyAdmin {
        _setRole(_pauserRole, _ROLE_PAUSER, account, enabled);
    }

    function setPaused(bool value) external onlyPauser {
        paused = value;
        emit Paused(msg.sender, value);
    }

    function configurePool(PoolKey calldata key, ConfigurePoolParams calldata params) external onlyConfig {
        PoolId poolId = key.toId();
        PoolConfig storage config = poolConfigs[poolId];

        if (params.priceFeedId0 != bytes32(0)) config.priceFeedId0 = params.priceFeedId0;
        if (params.priceFeedId1 != bytes32(0)) config.priceFeedId1 = params.priceFeedId1;
        if (params.baseFee != 0) config.baseFee = params.baseFee;
        if (params.maxFee != 0) config.maxFee = params.maxFee;
        if (params.minFee != 0) config.minFee = params.minFee;
        if (params.reserveCutBps != 0) config.reserveCutBps = PegGuardReserveLib.clampReserveCut(params.reserveCutBps);
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

    function setPoolMode(PoolKey calldata key, PoolMode mode) external onlyKeeper whenNotPaused {
        PoolId poolId = key.toId();
        poolStates[poolId].mode = mode;
        emit PoolModeUpdated(poolId, mode);
    }

    function setJITWindow(PoolKey calldata key, bool active) external onlyKeeper whenNotPaused {
        PoolId poolId = key.toId();
        PoolState storage state = poolStates[poolId];
        if (state.jitLiquidityActive == active && _jitActiveFlags[poolId] == active) return;
        state.jitLiquidityActive = active;
        _jitActiveFlags[poolId] = active; // Track in separate mapping
        emit JITWindowUpdated(poolId, active);
    }

    function reportReserveDelta(PoolKey calldata key, int256 delta) external onlyKeeper whenNotPaused {
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

    function fundReserve(PoolKey calldata key, uint256 amount) external onlyAdmin whenNotPaused {
        _transferReserveIn(amount);
        PoolId poolId = key.toId();
        poolStates[poolId].reserveBalance += amount;
        emit ReserveSynced(poolId, poolStates[poolId].reserveBalance);
    }

    function withdrawReserve(PoolKey calldata key, address recipient, uint256 amount) external onlyAdmin whenNotPaused {
        _decreaseReserve(key.toId(), amount);
        IERC20(reserveToken).transfer(recipient, amount);
        emit ReserveSynced(key.toId(), poolStates[key.toId()].reserveBalance);
    }

    function issueRebate(PoolKey calldata key, address trader, uint256 amount) external onlyKeeper whenNotPaused {
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
        return PegGuardReserveLib.calculateRebate(state.reserveBalance, depegReductionBps);
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

    function setTargetRange(PoolKey calldata key, int24 tickLower, int24 tickUpper) external onlyConfig {
        if (tickLower >= tickUpper) revert InvalidTargetRange();
        PoolId poolId = key.toId();
        PoolConfig storage config = poolConfigs[poolId];
        config.targetTickLower = tickLower;
        config.targetTickUpper = tickUpper;
        config.targetRangeSet = true;
        emit TargetRangeUpdated(poolId, tickLower, tickUpper);
        emit TargetRange(poolId, tickLower, tickUpper);
    }

    function clearTargetRange(PoolKey calldata key) external onlyConfig {
        PoolId poolId = key.toId();
        PoolConfig storage config = poolConfigs[poolId];
        config.targetRangeSet = false;
        config.targetTickLower = 0;
        config.targetTickUpper = 0;
        emit TargetRangeUpdated(poolId, 0, 0);
        emit TargetRange(poolId, 0, 0);
    }

    function setLiquidityPolicy(PoolKey calldata key, bool enforceAllowlist) external onlyConfig {
        PoolId poolId = key.toId();
        poolConfigs[poolId].enforceAllowlist = enforceAllowlist;
        poolStates[poolId].enforceAllowlist = enforceAllowlist;
        _enforceAllowlistFlags[poolId] = enforceAllowlist; // Track in separate mapping
        emit LiquidityPolicyUpdated(poolId, enforceAllowlist);
    }

    function updateLiquidityAllowlist(PoolKey calldata key, address account, bool allowed) external onlyConfig {
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
        ctx.feeFloor = ctx.baseFee + PegGuardFeeLib.modePremium(uint8(state.mode));
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

        uint256 depegBps = PegGuardFeeLib.computeDepegBps(price0, price1);
        state.lastDepegBps = depegBps;

        if (depegBps <= ctx.depegThresholdBps) {
            state.lastOverrideFee = ctx.feeFloor;
            return ctx.feeFloor;
        }

        bool worsensDepeg = (price0 < price1 && zeroForOne) || (price0 > price1 && !zeroForOne);
        PegGuardFeeHelper.FeeComputation memory feeInput = PegGuardFeeHelper.FeeComputation({
            feeFloor: ctx.feeFloor,
            maxFee: ctx.maxFee,
            minFee: ctx.minFee,
            reserveCutBps: ctx.reserveCutBps,
            depegBps: depegBps,
            worsensDepeg: worsensDepeg
        });
        PegGuardFeeHelper.FeeResult memory feeOutput = feeHelper.compute(feeInput);
        uint24 dynamicFee = feeOutput.dynamicFee;

        if (feeOutput.isPenalty) {
            state.totalPenaltyFees += feeOutput.feeDelta;
            emit DepegPenaltyApplied(poolId, zeroForOne, dynamicFee, feeOutput.reserveAmount);
            emit FeeOverrideApplied(poolId, dynamicFee, true);
        } else {
            state.totalRebates += feeOutput.feeDelta;
            emit FeeOverrideApplied(poolId, dynamicFee, false);
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
        // Read directly from storage mappings (exact same approach as getPoolSnapshot)
        PoolConfig storage config = poolConfigs[poolId];
        PoolState storage storedState = poolStates[poolId];

        // Check if allowlist enforcement is needed
        // Mirror getPoolSnapshot semantics: stored state is source of truth, then config/mappings
        bool enforceAllowlist = storedState.enforceAllowlist;
        if (!enforceAllowlist) {
            enforceAllowlist = config.enforceAllowlist || _enforceAllowlistFlags[poolId];
        }
        bool jitActive = storedState.jitLiquidityActive;
        if (!jitActive) {
            jitActive = _jitActiveFlags[poolId];
        }
        bool mustBeAllowlisted = jitActive || enforceAllowlist;

        // In Uniswap v4, the sender is the caller (e.g., PositionManager)
        // We need to check if the sender is allowlisted
        address liquidityProvider = sender;

        // Try to get the actual owner if sender is a PositionManager/router
        // For now, we check the sender directly (PositionManager should be allowlisted)
        emit DebugAllowlist(
            poolId,
            storedState.enforceAllowlist,
            config.enforceAllowlist,
            enforceAllowlist,
            jitActive,
            liquidityProvider
        );
        PegGuardLiquidityLib.enforceAddPolicy(poolAllowlist[poolId][liquidityProvider], mustBeAllowlisted);

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
            PegGuardLiquidityLib.enforceAddPolicy(poolAllowlist[poolId][liquidityProvider], true);
        }
        return BaseHook.beforeRemoveLiquidity.selector;
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

    function _setRole(mapping(address => bool) storage roleMap, bytes32 roleId, address account, bool enabled)
        internal
    {
        roleMap[account] = enabled;
        emit RoleUpdated(roleId, account, enabled);
    }

    function _hasRole(mapping(address => bool) storage roleMap, address account) internal view returns (bool) {
        return account == admin || roleMap[account];
    }
}
