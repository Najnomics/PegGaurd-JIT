# Runtime Configuration

PegGuard bots can be driven entirely by environment variables (single pool) or by a JSON config that describes multiple pools. Point both `bots/keeper.ts` and `bots/jit.ts` at the same file via `PEG_GUARD_CONFIG=/path/to/config.json`.

## File Schema

```jsonc
{
  "rpcUrl": "https://mainnet.infura.io/v3/<key>",
  "privateKey": "0xabc...",
  "keeper": {
    "contract": "0xKeeper",
    "pyth": "0xPyth",
    "jobs": [
      {
        "id": "usdc-usdt",
        "pool": {
          "currency0": "0xA0b8...",
          "currency1": "0xdAC1...",
          "fee": 8388608,           // LPFeeLibrary.DYNAMIC_FEE_FLAG
          "tickSpacing": 10,
          "hooks": "0xHook"
        },
        "priceFeedIds": [
          "0xeaa0....c94a",
          "0x2b89....e53b"
        ],
        "intervalMs": 60000,
        "pythEndpoint": "https://xc-mainnet.pyth.network"
      }
    ]
  },
  "jit": {
    "manager": "0xManager",
    "hook": "0xHook",
    "jobs": [
      {
        "id": "usdc-usdt",
        "pool": {
          "currency0": "0xA0b8...",
          "currency1": "0xdAC1...",
          "fee": 8388608,
          "tickSpacing": 10,
          "hooks": "0xHook"
        },
        "liquidity": "1000000000000000000",
        "amount0Max": "0",
        "amount1Max": "0",
        "duration": 900,
        "modeThreshold": 2,
        "settleBufferSec": 5,
        "intervalMs": 45000,
        "flashBorrower": {
          "address": "0xFlashBorrower",
          "asset": "0xA0b8...",
          "amount": "5000000000000000000",
          "executor": "0xExecutor",
          "executorData": "0x"
        }
      }
    ]
  }
}
```

### Notes

- `fee` must match the pool's `PoolKey.fee`. Use `8388608` for dynamic-fee pools.
- `flashBorrower` is optional. When present, the jit bot calls `PegGuardFlashBorrower.initiateFlashBurst` instead of `executeBurst`, enabling flash-loan–funded bursts.
- Omit `keeper.jobs` or `jit.jobs` to fall back to env vars for that bot.

See `docs/ops/example-config.json` for a ready-to-edit template.***
