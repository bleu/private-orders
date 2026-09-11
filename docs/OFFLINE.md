# Running the end-to-end checks

Two paths, both exercised against real deployments:

| Path | Command | Needs |
| --- | --- | --- |
| Mainnet fork | `FORK_RPC=https://ethereum-rpc.publicnode.com forge test --match-path 'test/fork/*' -vv` | Network only |
| Offline stack | `./scripts/offline-e2e.sh` | Docker, ~25 GB free, one Dockerfile patch |

Both run the same `PrivateTradeE2EBase` flow: two EOAs own their orders through CoW Sheds, and one
settlement exchanges the two assets atomically. Each also asserts the negative case — the same pair
submitted directly to `GPv2Settlement` is refused.

The fork path is the cheaper one and needs no patching. Use the offline stack when you need the
orderbook, autopilot and driver in the loop.

## Mainnet fork

Real `GPv2Settlement` (`0x9008…ab41`), real `GPv2AllowListAuthentication` (the test allowlists the
wrapper by impersonating the manager), real `ComposableCoW`, real `COWShedFactoryForComposableCoW`
at `0x5E284e80F3bd6A7D80A8500D9c49878028110848`, and real USDC/DAI seeded with `deal`.

## Regenerating the offline stack's state

The repo ships a prebuilt `state/anvil-state.json`, and `chain-deployer` short-circuits whenever it
exists. Regenerating requires **an archive-capable mainnet RPC** (`MAINNET_RPC_URL`), because the
deploy replays mainnet transactions onto anvil. A public endpoint is not enough: the run fails at
`Error: tx not found` during the CoW core deployment. Back up the state file before trying.

That shipped state is also stale in one way that matters here:

- **It deploys the plain `COWShed`, not `COWShedForComposableCoW`.** The plain implementation has no
  `isValidSignature`, so a Shed on it cannot own a ComposableCoW order.
- **Its Shed is version 2.0.0**, while the current `cow-shed` is 2.1.0, and the version is inside the
  EIP-712 domain. Signing with the wrong version fails as `InvalidSignature()`.
- **`COWSHED_COMPOSABLE_COW_FACTORY_ADDRESS` is read but never deployed or configured.**
  `scripts/orders/composable-cow/*.ts` and `test/utils/loadAddresses.ts` all expect it.

`contracts/script/DeployCoWShed.s.sol` is patched to deploy `COWShedForComposableCoW`, so a
regeneration with an archive RPC produces a stack whose Shed can own conditional orders. Until then,
`test/offline/*` deploys the ComposableCoW Shed itself. It also reads `VERSION()` from the deployed
implementation instead of hardcoding the domain version.

## Offline stack notes

The stack's `db` service publishes host port 5432, which collides with any local Postgres. Set
`PORT_DB=5433` in the offline repo's `.env`.

The Rust workspace needs about 25 GB free, and a container VM with more than the default 2 CPUs
(`colima start --cpu 6 --memory 12`). `modules/services/rust-toolchain` pins `stable`, which is too
new for `alloy-signer-aws 1.1.0`; the Dockerfile patch pins 1.89.0 and sets `RUSTUP_TOOLCHAIN` so the
toolchain file cannot override it.


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

## 1a. Required local patch to the offline repo

The stack does not build unpatched. Two edits to `offline-mode/Dockerfile`:

```dockerfile
# in the cargo-build stage, replacing `rustup install stable && rustup default stable`
ARG RUST_VERSION=1.89.0
RUN rustup install ${RUST_VERSION} && \
    rustup default ${RUST_VERSION}
# modules/services/rust-toolchain pins "stable", which rustup obeys over the default above.
# RUSTUP_TOOLCHAIN takes precedence over the toolchain file.
ENV RUSTUP_TOOLCHAIN=${RUST_VERSION}
```

```dockerfile
# build only what the check needs, instead of the whole workspace
CARGO_PROFILE_RELEASE_DEBUG=1 cargo build --release \
  -p autopilot -p driver -p orderbook -p solvers && \
cp target/release/autopilot / && cp target/release/driver / && \
cp target/release/orderbook / && cp target/release/solvers /
```

Why: `stable` is rustc 1.98.1, which cannot compile `alloy-signer-aws 1.1.0`
(`error: queries overflow the depth limit`). `crates/ethrpc` enables alloy's `signer-aws` feature
unconditionally, so dropping the `alerter` target alone does not avoid it. 1.89.0 is from the same
era as the pinned services revision (2025-12-18).

And one environment variable on the orderbook service, for the reason in
[DESIGN.md](DESIGN.md#integrating-with-the-orderbook-and-driver):

```
EIP1271_SKIP_CREATION_VALIDATION=true
```

## 1b. Disk

The Rust workspace needs **roughly 20-30 GB free**. `CARGO_PROFILE_RELEASE_DEBUG=1` inflates
`target/` considerably. If the container runtime's disk fills during `cargo build`, the build stops
with `Input/output error` and the runtime's own disk can be left needing a restart.

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
