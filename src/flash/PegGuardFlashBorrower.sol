// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {PegGuardJITManager} from "../PegGuardJITManager.sol";
import {IAaveV3Pool} from "../interfaces/aave/IAaveV3Pool.sol";
import {IFlashLoanSimpleReceiver} from "../interfaces/aave/IFlashLoanSimpleReceiver.sol";

/// @notice Coordinates Aave flash loans to fund PegGuard flash bursts.
/// @dev Liquidity is provided and removed within the same transaction, so the borrowed
///      asset plus the premium must be repaid immediately after the burst.
contract PegGuardFlashBorrower is AccessControl, IFlashLoanSimpleReceiver {
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    PegGuardJITManager public immutable jitManager;
    IAaveV3Pool public immutable lendingPool;
    address public immutable addressesProvider;

    error UnsupportedAsset();
    error InsufficientRepayment();

    struct FlashBurstParams {
        PoolKey key;
        uint128 liquidity;
        uint256 amount0Max;
        uint256 amount1Max;
        address executor;
        bytes executorData;
        address asset;
        uint256 loanAmount;
        address refundAddress;
    }

    constructor(address _jitManager, address _lendingPool, address admin) {
        require(_jitManager != address(0) && _lendingPool != address(0), "FlashBorrower: zero");
        jitManager = PegGuardJITManager(_jitManager);
        lendingPool = IAaveV3Pool(_lendingPool);
        addressesProvider = lendingPool.ADDRESSES_PROVIDER();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(EXECUTOR_ROLE, admin);
    }

    function initiateFlashBurst(FlashBurstParams calldata params) external onlyRole(EXECUTOR_ROLE) {
        require(params.loanAmount > 0, "FlashBorrower: loan=0");
        require(params.asset != address(0), "FlashBorrower: asset=0");
        bool supported = params.asset == Currency.unwrap(params.key.currency0)
            || params.asset == Currency.unwrap(params.key.currency1);
        if (!supported) revert UnsupportedAsset();

        lendingPool.flashLoanSimple(
            address(this),
            params.asset,
            params.loanAmount,
            abi.encode(params),
            0 // referralCode
        );
    }

    function executeOperation(address asset, uint256 amount, uint256 premium, address, bytes calldata params)
        external
        override
        returns (bool)
    {
        require(msg.sender == address(lendingPool), "FlashBorrower: invalid caller");
        FlashBurstParams memory decoded = abi.decode(params, (FlashBurstParams));
        require(decoded.asset == asset, "FlashBorrower: asset mismatch");

        IERC20(asset).approve(address(jitManager), amount);
        IERC20(asset).transfer(address(jitManager), amount);

        jitManager.flashBurst(
            decoded.key,
            decoded.liquidity,
            decoded.amount0Max,
            decoded.amount1Max,
            decoded.executor,
            decoded.executorData
        );

        uint256 repayment = amount + premium;
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (balance < repayment) revert InsufficientRepayment();

        IERC20(asset).transfer(address(lendingPool), repayment);

        if (decoded.refundAddress != address(0)) {
            uint256 leftover = IERC20(asset).balanceOf(address(this));
            if (leftover > 0) IERC20(asset).transfer(decoded.refundAddress, leftover);
        }

        return true;
    }

    function ADDRESSES_PROVIDER() external view override returns (address) {
        return addressesProvider;
    }

    function POOL() external view override returns (address) {
        return address(lendingPool);
    }
}
