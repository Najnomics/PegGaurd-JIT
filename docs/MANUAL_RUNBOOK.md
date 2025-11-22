# Manual Runbook

This runbook provides step-by-step instructions for manually testing and operating PegGuard in a development environment.

## Prerequisites

- Anvil running locally or access to a testnet RPC
- Foundry installed
- Private key with test ETH
- Environment variables configured

## Setup Sequence

### 1. Start Local Node

```bash
anvil --fork-url $RPC_URL
# Or for clean local testing:
anvil
```

### 2. Deploy Contracts

```bash
# Set environment variables
export PEG_GUARD_ADMIN=$(cast wallet address $PRIVATE_KEY)
export PYTH_ADAPTER=<deploy_pyth_adapter_first>
export RESERVE_TOKEN=<token_address>
export POOL_MANAGER=<v4_pool_manager>
export POSITION_MANAGER=<v4_position_manager>
export PERMIT2=<permit2_address>

# Deploy hook
forge script script/00_DeployHook.s.sol \
  --rpc-url http://localhost:8545 \
  --private-key $PRIVATE_KEY \
  --broadcast

# Save hook address
export PEG_GUARD_HOOK=<hook_address>

# Deploy keeper and JIT manager
forge script script/05_DeployKeeperAndJIT.s.sol \
  --rpc-url http://localhost:8545 \
  --private-key $PRIVATE_KEY \
  --broadcast

# Save addresses
export PEG_GUARD_KEEPER=<keeper_address>
export PEG_GUARD_JIT_MANAGER=<jit_manager_address>
```

### 3. Create and Initialize Pool

```bash
# Create pool (if not exists)
forge script script/01_CreatePoolAndAddLiquidity.s.sol \
  --rpc-url http://localhost:8545 \
  --private-key $PRIVATE_KEY \
  --broadcast
```

### 4. Configure PegGuard

```bash
# Set all configuration variables
export POOL_CURRENCY0=<token0_address>
export POOL_CURRENCY1=<token1_address>
export POOL_TICK_SPACING=60
export POOL_KEY_FEE=0x800000
export PRICE_FEED_ID0=<pyth_feed_id_0>
export PRICE_FEED_ID1=<pyth_feed_id_1>
export POOL_BASE_FEE=3000
export POOL_MAX_FEE=50000
export POOL_MIN_FEE=500
export KEEPER_ALERT_BPS=100
export KEEPER_CRISIS_BPS=200
export KEEPER_JIT_BPS=150
export KEEPER_MODE_COOLDOWN=300
export KEEPER_JIT_COOLDOWN=60
export JIT_TICK_LOWER=-300
export JIT_TICK_UPPER=300
export JIT_MAX_DURATION=3600
export JIT_RESERVE_SHARE_BPS=1000

# Configure
forge script script/03_ConfigurePegGuard.s.sol \
  --rpc-url http://localhost:8545 \
  --private-key $PRIVATE_KEY \
  --broadcast
```

## Testing Scenarios

### Scenario 1: Balanced Pool (No Action)

1. Set prices to be balanced:
```bash
# Update Pyth prices (via mock or keeper bot)
# FEED0: 100.00
# FEED1: 100.00
```

2. Trigger keeper evaluation:
```bash
cast send $PEG_GUARD_KEEPER \
  "evaluateAndUpdate((address,address,uint24,int24,address))" \
  "[$CURRENCY0,$CURRENCY1,$FEE,$TICK_SPACING,$HOOK]" \
  --rpc-url http://localhost:8545 \
  --private-key $PRIVATE_KEY
```

3. Verify pool is in Calm mode:
```bash
cast call $PEG_GUARD_HOOK \
  "getPoolSnapshot((address,address,uint24,int24,address))" \
  "[$CURRENCY0,$CURRENCY1,$FEE,$TICK_SPACING,$HOOK]" \
  --rpc-url http://localhost:8545
# Should show mode=0 (Calm), jitLiquidityActive=false
```

### Scenario 2: Alert Mode

1. Set prices to trigger alert (1% depeg):
```bash
# FEED0: 99.00
# FEED1: 100.00
```

2. Trigger keeper evaluation

3. Verify pool is in Alert mode:
```bash
# Should show mode=1 (Alert), jitLiquidityActive=false
```

### Scenario 3: Crisis Mode with JIT Burst

1. Set prices to trigger crisis (2%+ depeg):
```bash
# FEED0: 98.00
# FEED1: 100.00
```

2. Trigger keeper evaluation

3. Verify crisis mode and JIT activation:
```bash
# Should show mode=2 (Crisis), jitLiquidityActive=true
```

4. Execute JIT burst:
```bash
# Approve tokens first
cast send $TOKEN0 "approve(address,uint256)" $PEG_GUARD_JIT_MANAGER $AMOUNT \
  --rpc-url http://localhost:8545 --private-key $PRIVATE_KEY

cast send $PEG_GUARD_JIT_MANAGER \
  "executeBurst((address,address,uint24,int24,address),uint128,uint256,uint256,address,uint64)" \
  "[$CURRENCY0,$CURRENCY1,$FEE,$TICK_SPACING,$HOOK]" \
  $LIQUIDITY $AMOUNT0_MAX $AMOUNT1_MAX $FUNDER $DURATION \
  --rpc-url http://localhost:8545 --private-key $PRIVATE_KEY
```

5. Wait for duration, then settle:
```bash
# Fast forward time
cast rpc anvil_setNextBlockTimestamp $(($(date +%s) + 3600)) --rpc-url http://localhost:8545

cast send $PEG_GUARD_JIT_MANAGER \
  "settleBurst((address,address,uint24,int24,address),uint256,uint256)" \
  "[$CURRENCY0,$CURRENCY1,$FEE,$TICK_SPACING,$HOOK]" 0 0 \
  --rpc-url http://localhost:8545 --private-key $PRIVATE_KEY
```

6. Verify reserve accumulation:
```bash
# Check reserve balance increased
cast call $PEG_GUARD_HOOK \
  "getPoolSnapshot((address,address,uint24,int24,address))" \
  "[$CURRENCY0,$CURRENCY1,$FEE,$TICK_SPACING,$HOOK]" \
  --rpc-url http://localhost:8545
```

### Scenario 4: Fee Override During Swap

1. Set up crisis mode (as in Scenario 3)

2. Execute a swap that worsens the depeg:
```bash
cast send $SWAP_ROUTER \
  "swap((address,address,uint24,int24,address),(bool,int256,uint160),bytes,bytes)" \
  "[$CURRENCY0,$CURRENCY1,$FEE,$TICK_SPACING,$HOOK]" \
  "[true,$AMOUNT,$SQRT_PRICE_LIMIT]" \
  "" "" \
  --rpc-url http://localhost:8545 --private-key $PRIVATE_KEY
```

3. Verify penalty fee was applied:
```bash
# Check lastOverrideFee > baseFee
cast call $PEG_GUARD_HOOK \
  "getPoolSnapshot((address,address,uint24,int24,address))" \
  "[$CURRENCY0,$CURRENCY1,$FEE,$TICK_SPACING,$HOOK]" \
  --rpc-url http://localhost:8545
```

4. Execute a swap that helps restore the peg:
```bash
# Swap in opposite direction
cast send $SWAP_ROUTER \
  "swap((address,address,uint24,int24,address),(bool,int256,uint160),bytes,bytes)" \
  "[$CURRENCY0,$CURRENCY1,$FEE,$TICK_SPACING,$HOOK]" \
  "[false,$AMOUNT,$SQRT_PRICE_LIMIT]" \
  "" "" \
  --rpc-url http://localhost:8545 --private-key $PRIVATE_KEY
```

5. Verify rebate fee was applied:
```bash
# Check lastOverrideFee < baseFee
```

## Monitoring

### Check Pool State

```bash
cast call $PEG_GUARD_HOOK \
  "getPoolSnapshot((address,address,uint24,int24,address))" \
  "[$CURRENCY0,$CURRENCY1,$FEE,$TICK_SPACING,$HOOK]" \
  --rpc-url http://localhost:8545
```

### Check Keeper Config

```bash
cast call $PEG_GUARD_KEEPER \
  "keeperConfigs(bytes32)" \
  $POOL_ID \
  --rpc-url http://localhost:8545
```

### Check JIT Manager Config

```bash
cast call $PEG_GUARD_JIT_MANAGER \
  "poolConfigs(bytes32)" \
  $POOL_ID \
  --rpc-url http://localhost:8545
```

### Check Active Burst

```bash
cast call $PEG_GUARD_JIT_MANAGER \
  "bursts(bytes32)" \
  $POOL_ID \
  --rpc-url http://localhost:8545
```

## Troubleshooting

**Keeper not updating mode:**
- Check keeper has `KEEPER_ROLE` on hook
- Verify price feeds are configured correctly
- Check cooldown periods haven't elapsed

**JIT burst failing:**
- Verify JIT manager has `KEEPER_ROLE` on hook
- Check allowlist includes position manager
- Ensure tick range matches hook's target range (if set)
- Verify sufficient token approvals

**Fee overrides not applying:**
- Check pool is configured with price feeds
- Verify Pyth adapter is working
- Check confidence thresholds aren't too high
- Ensure hook is not paused

**Reserve not accumulating:**
- Verify reserve token is set correctly
- Check reserve share BPS is > 0
- Ensure settleBurst is called after burst expires

## Automated Testing

Run the full test suite:

```bash
forge test
```

Run specific test suites:

```bash
forge test --match-contract PegGuardHook
forge test --match-contract PegGuardKeeper
forge test --match-contract PegGuardJITManager
forge test --match-contract PegGuardIntegration
```

Run with gas reporting:

```bash
forge test --gas-report
```

Run with verbose output:

```bash
forge test -vvv
```

