# Blockroom contracts

Foundry project (Solidity 0.8.28, Cancun, OpenZeppelin v5.4.0).

```bash
forge build
```
```bash
forge test                                   # unit + fuzz + invariant + live-mainnet fork tests
```
```bash
FORK_TESTS=false forge test                  # offline
```
```bash
FORK_TESTS=false forge coverage --no-match-coverage "(test|script)" --report summary
```
```bash
slither . --config-file slither.config.json
```

Deployment: see ../DEPLOY.md. Design: see ../DECISIONS.md and ../THREAT_MODEL.md.
