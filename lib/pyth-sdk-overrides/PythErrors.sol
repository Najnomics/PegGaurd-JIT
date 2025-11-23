// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

/**
 * @notice Deprecated - this codebase will be removed on 1 August 2025.
 * @dev Switch to the maintained package. See migration guide at pyth.network docs.
 * @custom:deprecated Repository scheduled for deletion.
 */
library PythErrors {
    error PriceFeedNotFound();
    error StalePrice();
    error InvalidArgument();
    error NoFreshUpdate();
    error InsufficientFee();
    error PriceFeedNotFoundWithinRange();
}
