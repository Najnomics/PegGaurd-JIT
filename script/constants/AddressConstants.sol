// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Canonical token addresses for common networks
/// @dev Update these addresses based on the target network
library AddressConstants {
    // Mainnet addresses
    address constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant MAINNET_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant MAINNET_DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    // Sepolia testnet addresses
    address constant SEPOLIA_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant SEPOLIA_USDT = 0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0;

    // Aave V3 addresses (mainnet)
    address constant MAINNET_AAVE_POOL = 0x87870BCa3F3Fd6335c3F4Ce8392A6935C4b4e2ce;
    address constant MAINNET_AAVE_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;

    // Aave V3 addresses (Sepolia)
    address constant SEPOLIA_AAVE_POOL = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;
    address constant SEPOLIA_AAVE_PROVIDER = 0x0496275d34753A48320CA58103d5220d394FF77F;

    // Pyth addresses
    address constant MAINNET_PYTH = 0xff1a0f4744e8582DF1aE09D5611b887B6a12925C;
    address constant SEPOLIA_PYTH = 0xff1a0f4744e8582DF1aE09D5611b887B6a12925C; // Same address

    // Common Pyth price feed IDs (mainnet)
    // Note: These are example IDs - replace with actual Pyth feed IDs for your network
    bytes32 constant PYTH_USDC_USD =
        bytes32(uint256(0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a));
    bytes32 constant PYTH_USDT_USD =
        bytes32(uint256(0x2b89b9dc8fdf9f34709a5b106b472f5f85bb74e0e0b5c0b0e0b5c0b0e0b5c0b));
    bytes32 constant PYTH_ETH_USD =
        bytes32(uint256(0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace));
    bytes32 constant PYTH_DAI_USD = bytes32(uint256(0xb0948a5e5313200C6332C7F626e5c5C5C5C5C5C5C5C5C5C5C5C5C5C5C5C5C5C));

    /// @notice Get token address for a given network and token symbol
    /// @param network Network identifier (0 = mainnet, 1 = sepolia)
    /// @param token Token symbol (WETH, USDC, USDT, DAI)
    function getTokenAddress(uint256 network, string memory token) internal pure returns (address) {
        bytes32 tokenHash = keccak256(bytes(token));
        if (network == 0) {
            // Mainnet
            if (tokenHash == keccak256("WETH")) return MAINNET_WETH;
            if (tokenHash == keccak256("USDC")) return MAINNET_USDC;
            if (tokenHash == keccak256("USDT")) return MAINNET_USDT;
            if (tokenHash == keccak256("DAI")) return MAINNET_DAI;
        } else if (network == 1) {
            // Sepolia
            if (tokenHash == keccak256("WETH")) return SEPOLIA_WETH;
            if (tokenHash == keccak256("USDC")) return SEPOLIA_USDC;
            if (tokenHash == keccak256("USDT")) return SEPOLIA_USDT;
        }
        revert("AddressConstants: unsupported token");
    }

    /// @notice Get Aave pool address for a given network
    function getAavePool(uint256 network) internal pure returns (address) {
        if (network == 0) return MAINNET_AAVE_POOL;
        if (network == 1) return SEPOLIA_AAVE_POOL;
        revert("AddressConstants: unsupported network");
    }

    /// @notice Get Pyth address for a given network
    function getPyth(uint256 network) internal pure returns (address) {
        // Pyth uses same address on mainnet and testnets
        return MAINNET_PYTH;
    }
}

