// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {PegGuardHook} from "./PegGuardHook.sol";
import {IBurstExecutor} from "./interfaces/IBurstExecutor.sol";

/// @notice Contract that automates burst-liquidity (JIT) operations around PegGuard pools.
/// It is intentionally opinionated and mirrors the orchestration logic from the JIT reference repo.
contract PegGuardJITManager is AccessControl {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    PegGuardHook public immutable hook;
    IPositionManager public immutable positionManager;
    IPermit2 public immutable permit2;
    address public treasury;

    struct PoolJITConfig {
        int24 tickLower;
        int24 tickUpper;
        uint64 maxDuration;
        uint256 reserveShareBps;
    }

    struct BurstState {
        uint256 tokenId;
        address funder;
        uint128 liquidity;
        uint64 expiry;
        bool active;
    }

    mapping(PoolId => PoolJITConfig) public poolConfigs;
    mapping(PoolId => BurstState) public bursts;

    event PoolConfigured(PoolId indexed poolId, PoolJITConfig config);
    event BurstExecuted(PoolId indexed poolId, uint256 tokenId, address funder, uint128 liquidity, uint64 expiry);
    event BurstSettled(
        PoolId indexed poolId, uint256 tokenId, uint256 amount0Returned, uint256 amount1Returned, uint256 reserveDelta
    );
    event FlashBurstExecuted(
        PoolId indexed poolId, address indexed caller, uint256 tokenId, uint128 liquidity, address executor
    );
    event TreasuryUpdated(address indexed treasury);

    error PoolNotConfigured();
    error BurstActive();
    error BurstInactive();
    error DurationTooLong();
    error NativeCurrencyUnsupported();
    error ExecutorCallFailed();

    mapping(address => bool) private permitConfigured;

    constructor(address _hook, address _positionManager, address _permit2, address _treasury, address admin) {
        require(
            _hook != address(0) && _positionManager != address(0) && _permit2 != address(0),
            "PegGuardJITManager: zero address"
        );
        hook = PegGuardHook(_hook);
        positionManager = IPositionManager(_positionManager);
        permit2 = IPermit2(_permit2);
        treasury = _treasury;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CONFIG_ROLE, admin);
        _grantRole(EXECUTOR_ROLE, admin);
    }

    function setTreasury(address newTreasury) external onlyRole(CONFIG_ROLE) {
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function configurePool(PoolKey calldata key, PoolJITConfig calldata cfg) external onlyRole(CONFIG_ROLE) {
        require(cfg.tickLower < cfg.tickUpper, "PegGuardJITManager: ticks");
        require(cfg.reserveShareBps <= 10_000, "PegGuardJITManager: bps");
        PoolId poolId = key.toId();
        poolConfigs[poolId] = cfg;
        emit PoolConfigured(poolId, cfg);
    }

    function executeBurst(
        PoolKey calldata key,
        uint128 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        address funder,
        uint64 duration
    ) external onlyRole(EXECUTOR_ROLE) returns (uint256 tokenId) {
        PoolId poolId = key.toId();
        PoolJITConfig storage cfg = poolConfigs[poolId];
        if (cfg.maxDuration == 0) revert PoolNotConfigured();
        if (duration == 0) duration = cfg.maxDuration;
        if (duration > cfg.maxDuration) revert DurationTooLong();
        BurstState storage burst = bursts[poolId];
        if (burst.active) revert BurstActive();

        // Validate that configured ticks match hook's target range (if set)
        // This ensures JIT liquidity is only added within the allowed range
        (PegGuardHook.PoolConfig memory poolConfig,) = hook.getPoolSnapshot(key);
        if (poolConfig.targetRangeSet) {
            require(
                cfg.tickLower >= poolConfig.targetTickLower && cfg.tickUpper <= poolConfig.targetTickUpper,
                "PegGuardJITManager: ticks outside target range"
            );
        }

        _pullFunding(key.currency0, funder, amount0Max);
        _pullFunding(key.currency1, funder, amount1Max);
        _approveCurrency(key.currency0);
        _approveCurrency(key.currency1);
        _ensurePermitApprovals(key.currency0);
        _ensurePermitApprovals(key.currency1);

        uint256 amount0Spent;
        uint256 amount1Spent;
        (tokenId, amount0Spent, amount1Spent) =
            _mintPosition(key, cfg.tickLower, cfg.tickUpper, liquidity, amount0Max, amount1Max);

        _refund(key.currency0, funder, amount0Max - amount0Spent);
        _refund(key.currency1, funder, amount1Max - amount1Spent);

        burst.tokenId = tokenId;
        burst.funder = funder;
        burst.liquidity = liquidity;
        burst.expiry = uint64(block.timestamp + duration);
        burst.active = true;

        hook.setJITWindow(key, true);

        emit BurstExecuted(poolId, tokenId, funder, liquidity, burst.expiry);
    }

    function settleBurst(PoolKey calldata key, uint256 amount0Min, uint256 amount1Min)
        external
        onlyRole(EXECUTOR_ROLE)
    {
        PoolId poolId = key.toId();
        BurstState storage burst = bursts[poolId];
        if (!burst.active) revert BurstInactive();
        if (block.timestamp < burst.expiry) revert("PegGuardJITManager: burst live");

        PoolJITConfig memory cfg = poolConfigs[poolId];

        (uint256 amount0Collected, uint256 amount1Collected) =
            _burnPosition(key, burst.tokenId, burst.liquidity, amount0Min, amount1Min);

        burst.active = false;
        hook.setJITWindow(key, false);

        uint256 reserveShare0 = (amount0Collected * cfg.reserveShareBps) / 10_000;
        uint256 reserveShare1 = (amount1Collected * cfg.reserveShareBps) / 10_000;

        _payout(key.currency0, burst.funder, amount0Collected - reserveShare0);
        _payout(key.currency1, burst.funder, amount1Collected - reserveShare1);

        uint256 reserveDelta = 0;
        address reserveToken = hook.reserveToken();

        if (reserveShare0 > 0) {
            _payout(key.currency0, treasury, reserveShare0);
            if (Currency.unwrap(key.currency0) == reserveToken) reserveDelta += reserveShare0;
        }
        if (reserveShare1 > 0) {
            _payout(key.currency1, treasury, reserveShare1);
            if (Currency.unwrap(key.currency1) == reserveToken) reserveDelta += reserveShare1;
        }

        if (reserveDelta > 0) {
            hook.reportReserveDelta(key, int256(reserveDelta));
        }

        emit BurstSettled(poolId, burst.tokenId, amount0Collected, amount1Collected, reserveDelta);
    }

    function flashBurst(
        PoolKey calldata key,
        uint128 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        address executor,
        bytes calldata executorData
    )
        external
        onlyRole(EXECUTOR_ROLE)
        returns (uint256 amount0Spent, uint256 amount1Spent, uint256 amount0Out, uint256 amount1Out)
    {
        PoolId poolId = key.toId();
        PoolJITConfig storage cfg = poolConfigs[poolId];
        if (cfg.tickLower >= cfg.tickUpper) revert PoolNotConfigured();

        // Validate that configured ticks match hook's target range (if set)
        (PegGuardHook.PoolConfig memory poolConfig,) = hook.getPoolSnapshot(key);
        if (poolConfig.targetRangeSet) {
            require(
                cfg.tickLower >= poolConfig.targetTickLower && cfg.tickUpper <= poolConfig.targetTickUpper,
                "PegGuardJITManager: ticks outside target range"
            );
        }

        _approveCurrency(key.currency0);
        _approveCurrency(key.currency1);
        _ensurePermitApprovals(key.currency0);
        _ensurePermitApprovals(key.currency1);

        uint256 tokenId;
        (tokenId, amount0Spent, amount1Spent) =
            _mintPosition(key, cfg.tickLower, cfg.tickUpper, liquidity, amount0Max, amount1Max);

        if (executor != address(0)) {
            (bool ok,) = executor.call(executorData);
            if (!ok) revert ExecutorCallFailed();
        }

        (amount0Out, amount1Out) = _burnPosition(key, tokenId, liquidity, 0, 0);
        _payout(key.currency0, msg.sender, amount0Out);
        _payout(key.currency1, msg.sender, amount1Out);

        emit FlashBurstExecuted(poolId, msg.sender, tokenId, liquidity, executor);
    }

    function _pullFunding(Currency currency, address funder, uint256 amount) internal {
        if (amount == 0) return;
        address token = Currency.unwrap(currency);
        if (token == address(0)) revert NativeCurrencyUnsupported();
        IERC20(token).transferFrom(funder, address(this), amount);
    }

    function _refund(Currency currency, address to, uint256 amount) internal {
        if (amount == 0) return;
        address token = Currency.unwrap(currency);
        IERC20(token).transfer(to, amount);
    }

    function _approveCurrency(Currency currency) internal {
        address token = Currency.unwrap(currency);
        if (token == address(0)) return;
        IERC20 erc20 = IERC20(token);
        if (erc20.allowance(address(this), address(positionManager)) == 0) {
            erc20.approve(address(positionManager), type(uint256).max);
        }
    }

    function _ensurePermitApprovals(Currency currency) internal {
        address token = Currency.unwrap(currency);
        if (token == address(0) || permitConfigured[token]) return;
        IERC20(token).approve(address(permit2), type(uint256).max);
        permit2.approve(token, address(positionManager), type(uint160).max, type(uint48).max);
        permitConfigured[token] = true;
    }

    function _mintPosition(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        uint256 amount0Max,
        uint256 amount1Max
    ) internal returns (uint256 tokenId, uint256 amount0Spent, uint256 amount1Spent) {
        Currency currency0 = key.currency0;
        Currency currency1 = key.currency1;

        uint256 balance0Before = currency0.balanceOf(address(this));
        uint256 balance1Before = currency1.balanceOf(address(this));

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP), uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(key, tickLower, tickUpper, liquidity, amount0Max, amount1Max, address(this), bytes(""));
        params[1] = abi.encode(currency0, currency1);
        params[2] = abi.encode(currency0, address(this));
        params[3] = abi.encode(currency1, address(this));

        tokenId = positionManager.nextTokenId();
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        amount0Spent = balance0Before - currency0.balanceOf(address(this));
        amount1Spent = balance1Before - currency1.balanceOf(address(this));
    }

    function _burnPosition(
        PoolKey calldata key,
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal returns (uint256 amount0Out, uint256 amount1Out) {
        Currency currency0 = key.currency0;
        Currency currency1 = key.currency1;

        uint256 balance0Before = currency0.balanceOf(address(this));
        uint256 balance1Before = currency1.balanceOf(address(this));

        bytes memory actions =
            abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR), uint8(Actions.BURN_POSITION));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(tokenId, liquidity, amount0Min, amount1Min, bytes(""));
        params[1] = abi.encode(currency0, currency1, address(this));
        params[2] = abi.encode(tokenId, address(this));

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        amount0Out = currency0.balanceOf(address(this)) - balance0Before;
        amount1Out = currency1.balanceOf(address(this)) - balance1Before;
    }

    function _payout(Currency currency, address recipient, uint256 amount) internal {
        if (amount == 0 || recipient == address(0)) return;
        address token = Currency.unwrap(currency);
        IERC20(token).transfer(recipient, amount);
    }
}
