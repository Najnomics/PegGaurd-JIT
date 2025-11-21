# PegGuard JIT

PegGuard JIT fuses oracle-aware risk controls with the Uniswap v4 just-in-time liquidity playbook. The result is a hook-driven stable-asset vault that:

- injects flash-loan powered liquidity bursts when a peg is at risk,
- discourages trades that widen the imbalance via oracle-driven fees, and
- rewards traders who help stabilize the pool by temporarily lowering their execution costs.

These capabilities allow the system to stay lean during calm periods while going on the offensive the moment a depeg event unfolds.

## System Architecture

1. **Sentinel & Oracle Adapter** — Continuously reads Pyth price feeds for both sides of the stable pair, computes depeg severity, and tags pools as *balanced*, *at risk*, or *in crisis*.
2. **Dynamic Fee Hook** — A custom Uniswap v4 hook that overrides pool fees. It increases fees up to 5% for trades that worsen depegs and rebates users (down to 5 bps) who restore balance.
3. **JIT Liquidity Orchestrator** — Uses Aave/flash-loan providers to borrow depth only when the sentinel escalates a pool. Liquidity is added just-in-time, sits inside a tight tick band, and is pulled immediately after the trade window closes so debt can be repaid.
4. **Keeper & Automation Layer** — Off-chain executors monitor sentinel alerts, submit hook configuration updates, and trigger JIT liquidity scripts.
5. **Reserve & Treasury Manager** — Receives penalty fees, funds rebates, and enforces configurable reserve ratios per pool.

## Swap Lifecycle

1. Sentinel detects volatility (>0.5% price gap from Pyth) and flags the pool.
2. Keeper triggers the JIT orchestrator which:
   - flashes capital,
   - mints concentrated liquidity around the target tick range,
   - seeds reserve balances for rebates.
3. During the volatile window the hook:
   - levies an extra fee when a swap worsens the peg,
   - routes a rebate plus reserve contribution when the swap restores the peg.
4. After the window closes liquidity is withdrawn, flash loans are repaid, and penalty fees are streamed to the reserve.

## User Flow

```mermaid
flowchart TD
    A[User opens PegGuard UI / sends swap tx] --> B{Pool balanced?}
    B -- Yes --> C[Standard swap routed\nthrough hook]
    C --> D[Base fees apply\nno extra liquidity]
    B -- No: depeg detected --> E[Sentinel escalates]
    E --> F[JIT orchestrator flashes capital\nand mints concentrated liquidity]
    F --> G[Hook overrides fees\npenalize bad flow / rebate good flow]
    G --> H[Swap completes\nJIT liquidity removed]
    H --> I[Flash loan repaid &\nreserves topped up]
    I --> J[User sees execution\nprice + rebate/penalty in UI]
```

From the user’s perspective, PegGuard feels like a normal Uniswap swap except during volatile windows, where the interface surfaces whether their trade helped or hurt the peg along with any rebates or surcharges applied.

## Repository Layout

```
src/        Hook contracts (currently the template Counter hook placeholder)
script/     Foundry deployment scripts (to be updated for PegGuard flows)
test/       Forge-based hook tests
```

## Getting Started

```bash
forge install       # pulls dependencies declared in foundry.toml
forge test          # runs the hook test suite
```

To experiment with scripts from the Uniswap template:

```bash
anvil --fork-url <RPC>
forge script script/00_DeployHook.s.sol --rpc-url http://localhost:8545 --private-key <KEY> --broadcast
```

## Production Development Plan

| Phase | Goal | Key Tasks |
| --- | --- | --- |
| 0. Template Hardening | Align with upstream Uniswap v4 template | Replace `Counter.sol` with the PegGuard hook skeleton, wire forge remappings, and port BaseOverrideFee + Pyth adapter components |
| 1. Oracle & Fee Logic | Enforce dynamic depeg penalties | Implement the Pyth oracle adapter and dynamic fee logic, add sentinel configuration storage, write fork tests covering fee escalations and rebates |
| 2. JIT Liquidity Engine | Burst-liquidity deployment | Build a Foundry script that borrows via flash loans (Aave or Morpho), mints liquidity within configured ticks, and tears it down post-swap |
| 3. Keeper & Monitoring | Automated response | Ship a lightweight Node.js/Foundry keeper that watches pool price + oracle feed, triggers fee mode changes, and executes the JIT script |
| 4. Risk & Treasury | Long-term sustainability | Finalize reserve token strategy, stream penalty fees into reserves, expose admin/pauser/config roles |
| 5. Production Readiness | Harden + ship | End-to-end simulations, mainnet test deployment, audits, integrate dashboards/alerting |

Short-term priorities:

1. Port oracle-aware fee math into place, replacing `Counter.sol`.
2. Scaffold flash-loan-based liquidity scripts with mocked pools on anvil.
3. Write invariant/fork tests ensuring fees never drop below the base rate and flash-loan repayment always succeeds.
4. Document keeper configuration + environment variables once automation scripts exist.
