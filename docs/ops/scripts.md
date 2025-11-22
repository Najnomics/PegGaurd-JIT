# Deployment Scripts

| Script | Purpose | Key Env Vars |
| --- | --- | --- |
| `script/00_DeployHook.s.sol` | Mines + deploys `PegGuardHook` with the proper CREATE2 flags | `PYTH_ADAPTER`, `RESERVE_TOKEN`, `PEG_GUARD_ADMIN` |
| `script/01_CreatePoolAndAddLiquidity.s.sol` | Creates a dynamic-fee pool and seeds initial liquidity | `token0Amount`, `token1Amount`, hook settings inside script |
| `script/02_AddLiquidity.s.sol` | Adds liquidity to an existing pool | same as above |
| `script/03_ConfigurePegGuard.s.sol` | Configures the hook, keeper, and JIT manager for a specific pool (feeds, thresholds, allowlists, target ticks) | `PEG_GUARD_*`, `POOL_*`, `KEEPER_*`, `JIT_*`, etc. |
| `script/04_DeployFlashBorrower.s.sol` | Deploys `PegGuardFlashBorrower` pointing at the JIT manager and an Aave V3 pool | `PEG_GUARD_JIT_MANAGER`, `AAVE_POOL`, `PEG_GUARD_ADMIN` |

## Workflow

1. **Deploy Hook** – `forge script script/00_DeployHook.s.sol --broadcast ...`
2. **Create Pool + Liquidity** – run `01_` (initialization) followed by `02_` (top-ups) once `hookContract` and tokens are set.
3. **Configure PegGuard** – `script/03_ConfigurePegGuard.s.sol` wires feed IDs, reserve cuts, keeper thresholds, target range, and allowlists; rerun when parameters change.
4. **Deploy Flash Borrower** – optional: `script/04_DeployFlashBorrower.s.sol` to bring Aave flash loans online. Grant the borrower `EXECUTOR_ROLE` on `PegGuardJITManager` and add it to the liquidity allowlist.
5. **Automation** – run the keeper/JIT bots (`pnpm keeper`, `pnpm jit`) using either env vars or a config file (`docs/ops/runtime-config.md`).

> Tip: after each script, log outputs (addresses) to your config file so the bots and future scripts reference the same values.***
