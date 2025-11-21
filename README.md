PegGuard JIT" - Hybrid of Projects 1 & 4
(Targeting Stable-Asset Hooks - $10k prize pool)
Concept: Combine JIT liquidity provision with dynamic depeg protection for stablecoin/LST pairs.
How it works:

Uses JIT mechanics to add amplified liquidity (via Aave flash loans) ONLY when depeg risk is detected
Dynamic fees that punish depeg-worsening trades and reward peg-restoring trades
When pool is balanced: minimal liquidity, low fees
When depeg detected: Inject massive JIT liquidity + asymmetric fees
After trade: Remove liquidity, repay loans, keep fees

Why it wins:

Combines TWO winning patterns (JIT + dynamic fees)
Solves real problem (USDC depeg, stETH volatility)
Capital efficient (only borrow when needed)
