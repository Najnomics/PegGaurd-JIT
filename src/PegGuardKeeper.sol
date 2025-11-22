// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {PegGuardHook} from "./PegGuardHook.sol";
import {PythOracleAdapter} from "./oracle/PythOracleAdapter.sol";

/// @notice Keeper contract that consumes Pyth oracle data and drives PegGuardHook state changes.
/// Inspired by the sentinel logic in CONTEXT/Depeg-Sentinel.
contract PegGuardKeeper is AccessControl {
    using PoolIdLibrary for PoolKey;

    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    PegGuardHook public immutable hook;
    PythOracleAdapter public immutable adapter;

    struct KeeperConfig {
        uint256 alertBps;
        uint256 crisisBps;
        uint256 jitActivationBps;
        uint256 modeCooldown;
        uint256 jitCooldown;
    }

    mapping(PoolId => KeeperConfig) public keeperConfigs;
    mapping(PoolId => uint256) public lastModeUpdate;
    mapping(PoolId => uint256) public lastJitToggle;

    event KeeperConfigUpdated(PoolId indexed poolId, KeeperConfig cfg);
    event KeeperEvaluated(
        PoolId indexed poolId, PegGuardHook.PoolMode targetMode, bool jitTarget, uint256 depegBps, uint256 confidenceBps
    );
    event StaleFeedDetected(PoolId indexed poolId, bytes32 feedId);
    event ReserveDeltaReported(PoolId indexed poolId, int256 delta);

    constructor(address _hook, address admin) {
        require(_hook != address(0), "PegGuardKeeper: invalid hook");
        hook = PegGuardHook(_hook);
        adapter = hook.pythAdapter();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CONFIG_ROLE, admin);
        _grantRole(EXECUTOR_ROLE, admin);
    }

    function setKeeperConfig(PoolKey calldata key, KeeperConfig calldata cfg) external onlyRole(CONFIG_ROLE) {
        require(cfg.alertBps > 0 && cfg.crisisBps >= cfg.alertBps, "PegGuardKeeper: invalid thresholds");
        require(cfg.jitActivationBps >= cfg.alertBps, "PegGuardKeeper: jit threshold too low");
        PoolId poolId = key.toId();
        keeperConfigs[poolId] = cfg;
        emit KeeperConfigUpdated(poolId, cfg);
    }

    function evaluateAndUpdate(PoolKey calldata key) external onlyRole(EXECUTOR_ROLE) {
        PoolId poolId = key.toId();
        KeeperConfig memory cfg = keeperConfigs[poolId];
        require(cfg.alertBps != 0, "PegGuardKeeper: config missing");

        (PegGuardHook.PoolConfig memory poolConfig, PegGuardHook.PoolState memory state) = hook.getPoolSnapshot(key);
        require(
            poolConfig.priceFeedId0 != bytes32(0) && poolConfig.priceFeedId1 != bytes32(0),
            "PegGuardKeeper: feeds missing"
        );

        (uint256 depegBps, uint256 confRatio, bool stale) = _observe(poolConfig);
        uint256 volThreshold = hook.VOLATILITY_THRESHOLD_BPS();

        // If feeds are stale, log but don't update mode (fallback to current state)
        if (stale) {
            emit KeeperEvaluated(poolId, state.mode, state.jitLiquidityActive, depegBps, confRatio);
            return;
        }

        PegGuardHook.PoolMode targetMode = _modeFromDepeg(depegBps, confRatio, cfg, volThreshold);
        bool jitTarget = depegBps >= cfg.jitActivationBps && confRatio <= volThreshold;

        if (targetMode != state.mode && _modeCooldownSatisfied(poolId, cfg.modeCooldown)) {
            hook.setPoolMode(key, targetMode);
            lastModeUpdate[poolId] = block.timestamp;
        }

        if (jitTarget != state.jitLiquidityActive && _jitCooldownSatisfied(poolId, cfg.jitCooldown)) {
            hook.setJITWindow(key, jitTarget);
            lastJitToggle[poolId] = block.timestamp;
        }

        emit KeeperEvaluated(poolId, targetMode, jitTarget, depegBps, confRatio);
    }

    /// @notice Report reserve delta to the hook (for tracking penalty fees allocated to reserve)
    /// @param key The pool key
    /// @param delta The reserve delta (positive for additions, negative for withdrawals)
    function reportReserveDelta(PoolKey calldata key, int256 delta) external onlyRole(EXECUTOR_ROLE) {
        hook.reportReserveDelta(key, delta);
    }

    function _modeFromDepeg(uint256 depegBps, uint256 confRatio, KeeperConfig memory cfg, uint256 volThreshold)
        internal
        pure
        returns (PegGuardHook.PoolMode)
    {
        if (confRatio > volThreshold) return PegGuardHook.PoolMode.Calm;
        if (depegBps >= cfg.crisisBps) return PegGuardHook.PoolMode.Crisis;
        if (depegBps >= cfg.alertBps) return PegGuardHook.PoolMode.Alert;
        return PegGuardHook.PoolMode.Calm;
    }

    function _modeCooldownSatisfied(PoolId poolId, uint256 cooldown) internal view returns (bool) {
        if (cooldown == 0) return true;
        return block.timestamp - lastModeUpdate[poolId] >= cooldown;
    }

    function _jitCooldownSatisfied(PoolId poolId, uint256 cooldown) internal view returns (bool) {
        if (cooldown == 0) return true;
        return block.timestamp - lastJitToggle[poolId] >= cooldown;
    }

    function _observe(PegGuardHook.PoolConfig memory poolConfig)
        internal
        view
        returns (uint256 depegBps, uint256 confBps, bool stale)
    {
        try adapter.getPriceWithConfidence(poolConfig.priceFeedId0) returns (int64 price0, uint64 conf0, uint256) {
            try adapter.getPriceWithConfidence(poolConfig.priceFeedId1) returns (int64 price1, uint64 conf1, uint256) {
                uint256 confRatio =
                    (adapter.computeConfRatioBps(price0, conf0) + adapter.computeConfRatioBps(price1, conf1)) / 2;
                return (_computeDepegBps(price0, price1), confRatio, false);
            } catch {
                return (0, type(uint256).max, true); // Stale feed
            }
        } catch {
            return (0, type(uint256).max, true); // Stale feed
        }
    }

    function _computeDepegBps(int64 price0, int64 price1) internal pure returns (uint256) {
        int256 diff = int256(price0) - int256(price1);
        if (diff < 0) diff = -diff;
        int256 denomSigned = int256(price1);
        uint256 denom = uint256(denomSigned >= 0 ? denomSigned : -denomSigned);
        if (denom == 0) denom = 1;
        return (uint256(diff) * 10_000) / denom;
    }
}
