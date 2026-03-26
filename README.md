# SMC Vault

Community Liquidity Vault for managed LP positions on Base chain.

## What it does

Users deposit ETH + token into the vault. An AI agent manages concentrated liquidity positions on Uniswap, earns swap fees, and compounds returns. Everything on-chain, everything transparent.

## Key features

| Feature | Details |
|---------|---------|
| **Dual-asset deposits** | ETH + token in ~50/50 ratio |
| **NAV high-water mark fees** | 10% performance fee, only on new all-time highs |
| **Operator allowlist** | Agent can only call Uniswap — cannot transfer funds |
| **Emergency withdrawal** | Depositor-triggered after 4h timeout |
| **$100 cap** | Per wallet, enforced on-chain |
| **First-depositor protection** | Dead shares prevent inflation attacks |
| **Withdrawal cooldown** | 1 hour minimum between deposit and withdrawal |

## Security

- Slither static analysis: 0 high/critical findings
- Codex adversarial audit: 12 issues found, all fixed
- Invariant fuzzing: 128,000 calls across 4 invariants, zero violations
- Operator trust boundary: immutable target (Uniswap PM), selector allowlist
- Fee reservation: performance fees excluded from depositor NAV

## Architecture

```
Depositor → Vault Contract → Operator (AI Agent)
                                  │
                                  ↓
                         Uniswap V3 Position Manager
                                  │
                                  ↓
                          LP Position (earns fees)
```

The operator can only call 4 functions on the Uniswap NonfungiblePositionManager:
- `mint` — create new LP position
- `increaseLiquidity` — add to existing position
- `decreaseLiquidity` — remove from position
- `collect` — collect earned fees

All other calls revert. The operator cannot transfer tokens to arbitrary addresses.

## Contracts

| Contract | Purpose |
|----------|---------|
| `SMCVault.sol` | Dual-asset vault with managed LP |
| `MerkleClaim.sol` | Airdrop for 68,160 legacy holders |

## Build

```bash
forge build
forge test
```

## Tests

42 tests total:
- 27 vault unit tests (deposit, withdrawal, emergency, fees, operator, admin)
- 4 invariant fuzz tests (128K calls)
- 11 Merkle claim tests

## Links

- [0xSMC Landing Page](https://0xsmcai.github.io/)
- [X (@0xsmcai)](https://x.com/0xsmcai)
- [Factory Architecture](https://github.com/0xsmcai/factory-public)

## License

MIT
