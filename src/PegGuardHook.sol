// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
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
        int24 targetTickLower;
        int24 targetTickUpper;
        bool targetRangeSet;
        bool enforceAllowlist;
    }

    struct PoolState {
        PoolMode mode;
        bool jitLiquidityActive;
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
    }

    struct FeeContext {
        uint24 baseFee;
        uint24 maxFee;
        uint24 minFee;
        uint24 feeFloor;
    }

    mapping(PoolId => PoolConfig) public poolConfigs;
    mapping(PoolId => PoolState) public poolStates;

    PythOracleAdapter public immutable pythAdapter;
    address public immutable reserveToken;

    bool public paused;

    error MissingPriceFeeds();
    error InvalidAmount();
    error InsufficientReserve();
    error UnauthorizedLiquidityProvider();
    error TargetRangeViolation();
    error InvalidTargetRange();

    event PoolConfigured(PoolId indexed poolId, bytes32 feed0, bytes32 feed1, uint24 baseFee);
    event PoolModeUpdated(PoolId indexed poolId, PoolMode mode);
    event JITWindowUpdated(PoolId indexed poolId, bool active);
    event ReserveSynced(PoolId indexed poolId, uint256 newBalance);
    event FeeOverrideApplied(PoolId indexed poolId, uint24 fee, bool penalty);
    event Paused(address indexed account, bool value);
    event TargetRangeUpdated(PoolId indexed poolId, int24 tickLower, int24 tickUpper);
    event LiquidityPolicyUpdated(PoolId indexed poolId, bool enforceAllowlist);
    event LiquidityAllowlistUpdated(PoolId indexed poolId, address indexed account, bool allowed);

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

        if (config.baseFee == 0) config.baseFee = DEFAULT_BASE_FEE;

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
        if (state.jitLiquidityActive == active) return;
        state.jitLiquidityActive = active;
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

    function getPoolSnapshot(PoolKey calldata key)
        external
        view
        returns (PoolConfig memory config, PoolState memory state)
    {
        PoolId poolId = key.toId();
        config = poolConfigs[poolId];
        state = poolStates[poolId];
    }

    function setTargetRange(PoolKey calldata key, int24 tickLower, int24 tickUpper) external onlyRole(CONFIG_ROLE) {
        if (tickLower >= tickUpper) revert InvalidTargetRange();
        PoolId poolId = key.toId();
        PoolConfig storage config = poolConfigs[poolId];
        config.targetTickLower = tickLower;
        config.targetTickUpper = tickUpper;
        config.targetRangeSet = true;
        emit TargetRangeUpdated(poolId, tickLower, tickUpper);
    }

    function clearTargetRange(PoolKey calldata key) external onlyRole(CONFIG_ROLE) {
        PoolId poolId = key.toId();
        PoolConfig storage config = poolConfigs[poolId];
        config.targetRangeSet = false;
        config.targetTickLower = 0;
        config.targetTickUpper = 0;
        emit TargetRangeUpdated(poolId, 0, 0);
    }

    function setLiquidityPolicy(PoolKey calldata key, bool enforceAllowlist) external onlyRole(CONFIG_ROLE) {
        PoolId poolId = key.toId();
        poolConfigs[poolId].enforceAllowlist = enforceAllowlist;
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

        FeeContext memory ctx;
        ctx.baseFee = config.baseFee == 0 ? DEFAULT_BASE_FEE : config.baseFee;
        ctx.maxFee = config.maxFee == 0 ? DEFAULT_MAX_FEE : config.maxFee;
        ctx.minFee = config.minFee == 0 ? DEFAULT_MIN_FEE : config.minFee;
        ctx.feeFloor = ctx.baseFee + _modePremium(state.mode);
        if (state.jitLiquidityActive) ctx.feeFloor += JIT_ACTIVE_PREMIUM;
        if (ctx.feeFloor > ctx.maxFee) ctx.feeFloor = ctx.maxFee;

        if (paused || config.priceFeedId0 == bytes32(0) || config.priceFeedId1 == bytes32(0)) {
            state.lastOverrideFee = ctx.feeFloor;
            return ctx.feeFloor;
        }

        (int64 price0, uint64 conf0,) = pythAdapter.getPriceWithConfidence(config.priceFeedId0);
        (int64 price1, uint64 conf1,) = pythAdapter.getPriceWithConfidence(config.priceFeedId1);

        uint256 confRatioBps =
            (pythAdapter.computeConfRatioBps(price0, conf0) + pythAdapter.computeConfRatioBps(price1, conf1)) / 2;
        state.lastConfidenceBps = confRatioBps;

        if (confRatioBps > VOLATILITY_THRESHOLD_BPS) {
            state.lastOverrideFee = ctx.feeFloor;
            return ctx.feeFloor;
        }

        uint256 depegBps = _computeDepegBps(price0, price1);
        state.lastDepegBps = depegBps;

        if (depegBps <= DEPEG_THRESHOLD_BPS) {
            state.lastOverrideFee = ctx.feeFloor;
            return ctx.feeFloor;
        }

        bool worsensDepeg = (price0 < price1 && params.zeroForOne) || (price0 > price1 && !params.zeroForOne);
        uint24 dynamicFee;

        if (worsensDepeg) {
            uint24 penalty = uint24((depegBps / 10) * 100);
            dynamicFee = ctx.feeFloor + penalty;
            if (dynamicFee > ctx.maxFee) dynamicFee = ctx.maxFee;
            state.totalPenaltyFees += dynamicFee > ctx.feeFloor ? dynamicFee - ctx.feeFloor : 0;
            emit FeeOverrideApplied(poolId, dynamicFee, true);
        } else {
            uint24 rebate = uint24((depegBps / 20) * 50);
            if (rebate >= ctx.feeFloor || ctx.feeFloor - rebate < ctx.minFee) {
                dynamicFee = ctx.minFee;
            } else {
                dynamicFee = ctx.feeFloor - rebate;
            }
            if (dynamicFee < ctx.minFee) dynamicFee = ctx.minFee;
            state.totalRebates += ctx.feeFloor > dynamicFee ? ctx.feeFloor - dynamicFee : 0;
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
        PoolState storage state = poolStates[poolId];
        _enforceAddPolicy(poolId, sender, state.jitLiquidityActive || poolConfigs[poolId].enforceAllowlist);

        if (state.jitLiquidityActive && poolConfigs[poolId].targetRangeSet) {
            PoolConfig storage config = poolConfigs[poolId];
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
        if (state.jitLiquidityActive) {
            _enforceAddPolicy(poolId, sender, true);
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

    function _enforceAddPolicy(PoolId poolId, address sender, bool mustBeAllowlisted) internal view {
        if (!mustBeAllowlisted) return;
        if (poolAllowlist[poolId][sender] || hasRole(KEEPER_ROLE, sender)) return;
        revert UnauthorizedLiquidityProvider();
    }
}
