# How PegGuard Works

PegGuard lives in `/Users/najnomics/november/FOR ETHGLOBAL/PegGaurd-JIT`. From there you can run `forge test`, execute the keeper/JIT bots (TypeScript), or broadcast the Foundry scripts under `script/`.

## 1. Accessing the Project

1. `cd /Users/najnomics/november/FOR ETHGLOBAL/PegGaurd-JIT`
2. Install deps once: `forge install` and `pnpm install`
3. Run tests: `forge test --gas-report`
4. Run bots (after exporting env vars): `pnpm keeper`, `pnpm jit`

Everything—contracts, scripts, bots, docs—lives inside this folder, so no extra context checkout is required.

## 2. User Perspective Flow

1. **Calm swaps** – Trader swaps in a PegGuard-enabled Uniswap v4 pool. Hook behaves like vanilla pool with base fees.
2. **Depeg detected** – Oracle (Pyth) flags price divergence. UI surfaces “At Risk” or “Crisis” badge; hook raises penalties for destabilizing trades and offers rebates for stabilizing ones.
3. **JIT Liquidity burst** – Keeper + JIT bot flash-borrow liquidity, inject it between configured tickLower/tickUpper, and immediately unwind after the burst window.
4. **Outcome** – User sees: extra depth for large orders, penalties displayed if their trade worsened the peg, or rebates if they helped. After the window, liquidity is pulled and flash loans repaid; reserves grow from penalties.

To the end user, PegGuard feels like a smarter Uniswap pool that defends the peg when it matters, while looking normal during calm periods.

## 3. Technical Architecture

### 3.1 Contracts
- **PegGuardHook** – Inherits `BaseOverrideFee` (hence `BaseHook`). Overrides fees before swaps using Pyth data, handles reserve accounting, enforces allowlists & target ranges in `beforeAddLiquidity/beforeRemoveLiquidity`.
- **PegGuardKeeper** – Stores per-pool configs (alert/crisis thresholds, cooldowns). Pulls oracle data, flips pool modes (Calm/Alert/Crisis), and toggles JIT activation flags.
- **PegGuardJITManager** – Executes burst liquidity. Enforces tick bands, requests liquidity funding, and pays reserve shares. Works with `PegGuardFlashBorrower` to source Aave V3 flash loans.
- **PythOracleAdapter** – Thin wrapper around Pyth price service, exposes price/confidence/staleness data.

### 3.2 Automation & Tooling
- **Bots** – `bots/keeper.ts` retries Pyth updates, calls keeper; `bots/jit.ts` listens for hook/keeper events to run `executeBurst`/`settleBurst`.
- **Scripts** – Foundry scripts deploy hook, keeper, JIT manager, flash borrower, set roles, configure pools, or execute multi-pool JSON configs (`config/example-pools.json`).
- **Docs & Runbooks** – `README.md`, `docs/DEPLOYMENT.md`, and `docs/MANUAL_RUNBOOK.md` explain deployment steps, env vars, and manual crisis simulations.

### 3.3 Flow Under the Hood
1. **Deploy** hook (CREATE2), keeper, JIT manager, flash borrower; configure pools with feeds, fees, reserve tokens, target ticks.
2. **Monitor** – Keeper bot pushes Pyth prices, keeper contract evaluates mode + JIT status.
3. **Crisis handling** – Hook increases penalties/rebates; JIT manager injects concentrated liquidity via flash loans; reserve tracker receives penalty share.
4. **Settlement** – Liquidity is pulled, loans repaid, reserves updated, keeper returns pool to Calm once oracle gap closes.

## 4. Summary Cheat Sheet
- **Path**: `/Users/najnomics/november/FOR ETHGLOBAL/PegGaurd-JIT`
- **Primary commands**: `forge test`, `pnpm keeper`, `pnpm jit`
- **Key contracts**: Hook, Keeper, JIT Manager, Flash Borrower, Oracle Adapter
- **Docs**: `README.md`, `docs/DEPLOYMENT.md`, `docs/MANUAL_RUNBOOK.md`, `docs/HOW.md`

PegGuard = user-friendly stable swaps backed by an automated crisis response stack (oracle-driven fees, JIT liquidity bursts, reserve accounting) that all run from this single repository.
