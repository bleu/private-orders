# Running the offline end-to-end check

This runs a private trade against the live `bleu/cow-offline-mode` chain: the real `GPv2Settlement`,
the real `COWShedFactory` and `COWShedForComposableCoW`, and the real mintable test tokens the
offline stack serves to its own services.

## 1. Start the stack

```bash
cd /Users/joseribeiro/projects/bleu/cow/offline-mode
git submodule update --init modules/services   # required: compose builds the Rust services from here
cp -n .env.example .env

# only what the check needs; skips frontend/explorer/adminer/grafana/prometheus
docker compose up -d chain-deployer chain db db-migrations coingecko-mock \
  orderbook autopilot driver baseline tempo

# wait
curl --retry 60 --retry-delay 5 --retry-all-errors http://localhost:8080/api/v1/version
cast block-number --rpc-url http://localhost:8545
curl -fsS http://localhost:9000/healthz     # driver
curl -fsS http://localhost:9001/healthz     # baseline solver
```

The first start builds the Rust workspace from `modules/services`, which dominates the wall clock
(30-90 minutes cold on a laptop; fast afterwards from cache).

`chain-deployer` short-circuits when `state/anvil-state.json` exists, and the repo ships one. If you
delete it, the container needs internet plus a working mainnet RPC (`MAINNET_RPC_URL`), because it
replays mainnet bytecode onto anvil.

## 2. Run the check

```bash
cd /Users/joseribeiro/projects/bleu/cow/private-orders
./scripts/offline-e2e.sh
# or: OFFLINE_RPC=http://localhost:8545 forge test --match-path 'test/offline/*' -vv
```

Without `OFFLINE_RPC` the test is skipped, so a plain `forge test` stays hermetic.

## What it proves

| Step | Real thing it exercises |
| --- | --- |
| `COWShedFactory.proxyOf(eoa)` | The deployed factory's CREATE2 derivation, on the real chain |
| Owner signs `ExecuteHooks`, anyone relays | `LibAuthenticatedHooks` signature path and the deployed proxy |
| Bundle calls `approve` + `ComposableCoW.create` | The real `ComposableCoW` on the real chain |
| `addSolver(wrapper)` via the manager | `GPv2AllowListAuthentication` — the wrapper is a bundle, so it must be allowlisted |
| `wrappedSettle(settleData, chainedWrapperData)` | The real `GPv2Settlement.settle` at `0x9008…ab41` |
| Balance assertions on the Sheds | Tokens actually move through the settlement |

## Stack facts this depends on

- Chain id is **1**; core contracts sit at their mainnet addresses.
- Tokens are `TestUSDC`/`TestDAI` bytecode copied onto the mainnet token addresses, and they expose
  `mint(address,uint256)`.
- Anvil account #0 (`0xf39F…92266`) is both the deployer and a pre-authorized solver; the
  authenticator's manager is read from the deployed contract, so the test allowlists the wrapper
  itself.
- Runtime deployments are **not** persistent: the `chain` service runs anvil without
  `--dump-state`, so contracts deployed after startup vanish on `docker compose up` with a recreated
  container. The test deploys the wrapper per run inside a fork, which sidesteps this.
