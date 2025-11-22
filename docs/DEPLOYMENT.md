# Deployment Guide

This guide covers deploying PegGuard contracts and configuring pools for production use.

## Prerequisites

- Foundry installed (`forge`, `cast`, `anvil`)
- Access to an RPC endpoint for your target network
- Private key with sufficient ETH for gas
- Pyth price feed IDs for your token pairs
- Aave V3 pool address (if using flash loans)

## Deployment Sequence

### 1. Deploy Hook

The hook must be deployed with CREATE2 to ensure a deterministic address that matches the required hook flags.

```bash
forge script script/00_DeployHook.s.sol \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

**Required Environment Variables:**
- `PYTH_ADAPTER` - PythOracleAdapter contract address
- `RESERVE_TOKEN` - Reserve token address (e.g., USDC)
- `PEG_GUARD_ADMIN` - Admin address for role grants
- `POOL_MANAGER` - Uniswap v4 PoolManager address

**Output:** Hook address (save this for next steps)

### 2. Deploy Keeper and JIT Manager

```bash
forge script script/05_DeployKeeperAndJIT.s.sol \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

**Required Environment Variables:**
- `PEG_GUARD_HOOK` - Hook address from step 1
- `POSITION_MANAGER` - Uniswap v4 PositionManager address
- `PERMIT2` - Permit2 contract address
- `TREASURY` - Treasury address (optional, defaults to admin)
- `PEG_GUARD_ADMIN` - Admin address

**Output:** Keeper and JIT Manager addresses

### 3. Deploy Flash Borrower (Optional)

Only needed if you plan to use Aave flash loans for JIT bursts.

```bash
forge script script/04_DeployFlashBorrower.s.sol \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

**Required Environment Variables:**
- `PEG_GUARD_JIT_MANAGER` - JIT Manager address from step 2
- `AAVE_POOL` - Aave V3 pool address (or set `NETWORK_ID` for canonical address)
- `PEG_GUARD_ADMIN` - Admin address

### 4. Configure Pool

Configure a single pool with all settings:

```bash
forge script script/03_ConfigurePegGuard.s.sol \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

**Required Environment Variables:**
- `PEG_GUARD_HOOK` - Hook address
- `PEG_GUARD_KEEPER` - Keeper address
- `PEG_GUARD_JIT_MANAGER` - JIT Manager address
- `POOL_CURRENCY0` - Token address or symbol (WETH, USDC, USDT, DAI)
- `POOL_CURRENCY1` - Token address or symbol
- `POOL_TICK_SPACING` - Tick spacing (e.g., 60)
- `PRICE_FEED_ID0` - Pyth feed ID for currency0
- `PRICE_FEED_ID1` - Pyth feed ID for currency1
- `POOL_BASE_FEE` - Base fee in bps (e.g., 3000)
- `POOL_MAX_FEE` - Max fee in bps (e.g., 50000)
- `POOL_MIN_FEE` - Min fee in bps (e.g., 500)
- `KEEPER_ALERT_BPS` - Alert threshold
- `KEEPER_CRISIS_BPS` - Crisis threshold
- `KEEPER_JIT_BPS` - JIT activation threshold
- `JIT_TICK_LOWER` - JIT lower tick
- `JIT_TICK_UPPER` - JIT upper tick
- `JIT_MAX_DURATION` - Max burst duration in seconds
- `JIT_RESERVE_SHARE_BPS` - Reserve share percentage

### 5. Multi-Pool Deployment

Deploy multiple pools from a JSON configuration:

```bash
forge script script/06_MultiPoolDeploy.s.sol \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --sig "run()" \
  --env POOL_CONFIG_JSON=config/example-pools.json
```

See `config/example-pools.json` for the JSON format.

## Canonical Addresses

The deployment scripts support canonical addresses for common tokens and protocols. Set `NETWORK_ID=0` for mainnet or `NETWORK_ID=1` for Sepolia, then use token symbols instead of addresses.

**Supported Tokens:**
- WETH
- USDC
- USDT
- DAI

**Supported Protocols:**
- Aave V3 Pool (mainnet and Sepolia)

## Post-Deployment

1. **Grant Roles:** Ensure the keeper has `KEEPER_ROLE` on the hook
2. **Fund Reserves:** Optionally fund the hook's reserve for rebates
3. **Start Keeper Bot:** Run `bots/keeper.ts` to begin monitoring
4. **Start JIT Bot:** Run `bots/jit.ts` to enable automatic bursts

## Verification

Verify deployments:

```bash
# Check hook configuration
cast call $PEG_GUARD_HOOK "getPoolSnapshot((address,address,uint24,int24,address))" \
  "[$CURRENCY0,$CURRENCY1,$FEE,$TICK_SPACING,$HOOK]" \
  --rpc-url $RPC_URL

# Check keeper config
cast call $PEG_GUARD_KEEPER "keeperConfigs(bytes32)" $POOL_ID \
  --rpc-url $RPC_URL
```

## Troubleshooting

**Hook address mismatch:** Ensure CREATE2 factory is correct and salt matches

**Role errors:** Grant required roles (ADMIN_ROLE, CONFIG_ROLE, KEEPER_ROLE, EXECUTOR_ROLE)

**Price feed errors:** Verify Pyth feed IDs are correct for your network

**Tick range errors:** Ensure JIT ticks are within hook's target range (if set)

