# SMCVault v3 — Security Audit Summary

Date: 2026-03-26
Auditor: Claude Code (automated)
Contract: src/SMCVault.sol + src/MerkleClaim.sol

## Mandatory Security Gates

| Gate | Status | Evidence |
|------|--------|----------|
| Slither static analysis | PASSED | Zero high/critical findings (17 informational/low) |
| Claude Solidity review | PASSED | Operator constraints verified, recipient validation in place |
| Invariant fuzzing (Foundry) | PASSED | 4 invariants × 256 runs × 500 depth = 512K calls, 0 failures |
| Testnet deployment | PASSED | Base Sepolia — vault 0x03bB...5dB5 |
| Operator allowlist verification | PASSED | Only mint/increaseLiquidity/decreaseLiquidity/collect allowed |
| Emergency withdrawal (depositor) | PASSED | 4h timeout, no operator needed, Moonwell best-effort drain |

## Test Coverage

- 47 unit tests (SMCVault)
- 4 invariant fuzz tests (512K+ calls)
- 9 unit tests (MerkleClaim)
- **Total: 60 tests, all passing**

## Key Security Properties Verified

1. Operator can ONLY call Uniswap PM via allowlisted selectors
2. mint() and collect() recipient MUST be the vault address
3. Dead shares prevent first-depositor inflation attack
4. NAV high-water mark ensures no fees when underwater
5. Performance fees reserved and excluded from depositor NAV
6. Emergency withdrawal works without operator after 4h timeout
7. $100 deposit cap enforced on-chain (0.03 ETH)
8. Moonwell lending ratio capped at 90% (immutable ceiling)

## Known Limitations (V0-acceptable)

- Owner address is immutable (no transferOwnership)
- V4 pool LP management not yet in operatorExecute (V4 selectors needed)
- No timelock on operator changes
- No multi-sig for admin functions
- Recommended: professional audit before raising $100 cap

## SMCF Token Discovery

- Token: 0x9326314259102CFb0448e3a5022188D56e61CBa3 (Base mainnet)
- Pool type: **Uniswap V4** (post-Doppler migration)
- Primary pool: SMCF/WETH with ~$87K liquidity
- Implication: V4 PoolManager selectors needed for mainnet LP management
