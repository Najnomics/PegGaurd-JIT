# PegGuard Architecture

PegGuard JIT merges two blueprints:

1. **Depeg Sentinel** – oracle-aware dynamic fees, reserve management, and penalty/rebate incentives.
2. **Uniswap v4 JIT Vault** – hook permissions, HookMiner workflow, and just-in-time liquidity orchestration.

## Contracts

| Contract | Role | Key Ideas Borrowed |
| --- | --- | --- |
| `PegGuardHook` | Dynamic-fee hook that protects the peg | BaseOverrideFee logic from Sentinel, hook permissioning & liquidity controls from the v4 template |
| `PegGuardKeeper` | On-chain sentinel/coordinator | Sentinel thresholds + automation hooks |
| `PegGuardJITManager` | Burst-liquidity orchestrator | Executes JIT mints similar to the Uniswap vault scripts, streams reserve share back to PegGuard |
| `PegGuardFlashBorrower` | Aave V3 flash receiver | Initiates single-block bursts with flash liquidity, calling `PegGuardJITManager.flashBurst` |
| `PythOracleAdapter` | Normalizes Pyth feeds | Shared utility between hook/keeper |

### PegGuardHook

- **Dynamic Fee Engine**: Pulls Pyth feeds to detect depeg magnitude and confidence, then:
  - boosts fees (up to 5%) when trades worsen the peg,
  - discounts fees (down to 5 bps) for stabilizing flow,
  - applies mode premiums (Alert/Crisis/JIT) so keepers can ratchet fees on demand.
- **Target Range + Allowlist**: When JIT mode is active, liquidity must land inside the keeper-set tick band and only allowlisted addresses (keepers/JIT manager) can mint/remove liquidity.
- **Reserve Mechanics** (new):
  - `fundReserve`, `withdrawReserve`, and `issueRebate` move the configured `reserveToken`,
  - per-pool reserve cut (20–50%) is announced via `DepegPenaltyApplied`,
  - rebates are emitted through `DepegRebateIssued`.

### Automation Layer

- `PegGuardKeeper` reads Pyth feeds, pushes updates on-chain, and toggles peg modes + JIT windows.
- `PegGuardJITManager` coordinates liquidity bursts (currently wallet-funded; flash-loan integrations land in step 2).
- TypeScript bots in `bots/` continuously feed the keeper/JIT manager using the Pyth price service.

## Scripts

- `script/00_DeployHook.s.sol` – HookMiner deployment (from the Uniswap template).
- `script/01_02_*.s.sol` – pool creation + liquidity seeding helpers.
- `script/03_ConfigurePegGuard.s.sol` – new: one broadcast to wire the hook, keeper, and JIT manager (feeds, thresholds, target ticks, allowlists, reserve cuts).

## Roadmap Summary

1. **Reserve Mechanics (this PR)** – parity with Sentinel for reserve flows/events.
2. **Flash-Loan JIT** — (in progress) hook in Aave flash loans + `flashBurst` flows for single-block depth, followed by multi-block credit lines.
3. **Keeper/Bot Expansion** — multi-pool configs, alerting, retry logic.
4. **Deployment Tooling** – scripts mirroring the Uniswap template, CLI harnesses.
5. **Integration Tests & Simulations** – `test/PegGuardIntegration.t.sol` ties hook + keeper + JIT manager together; extend with Universal Router/fork tests next.
6. **Docs & Ops** – runbooks, alert layouts, env templates.

Refer back to `README.md` for high-level positioning; this document focuses on the merged architecture and the delta between the upstream repos.***
