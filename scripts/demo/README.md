# Running a demo

A private trade between two parties on a local CoW stack: both sides hold their balances in a Shed,
neither sends a transaction, and a relayer pays the gas. This directory is the runbook for putting that
in front of someone else.

Everything here assumes the offline stack already exists at `../../offline-mode` and that the repo has
been built at least once. `docs/OFFLINE.md` covers the stack itself, including the failures that look
like our code but are not.

## The whole thing, in order

```sh
./scripts/demo/stack-up.sh                       # the CoW stack: chain, orderbook, autopilot/driver/baseline
./scripts/demo/reset-and-run.sh                  # deploy our contracts, then settle one trade as a smoke test
./scripts/demo/service-up.sh                     # the page and API, with PUBLIC_URL set (see below)
./scripts/demo/faucet-up.sh                      # demo tokens for whoever is trading
```

`reset-and-run.sh` leaves the sub-solver and the service running, so a demo taken straight after it
works. Re-run `service-up.sh` after it if you want the service pointed at a different `PUBLIC_URL`.

## Reaching it from somewhere else

Set `PUBLIC_URL` to the address the audience will open, because the page builds its share links from it:

```sh
PUBLIC_URL=https://demo.example.ts.net ./scripts/demo/service-up.sh
```

Only the service and the faucet need exposing. A party signs EIP-712 typed data and nothing else, so
their wallet never needs a node — no RPC to add, no chain to select beyond the one the offer names.
With Tailscale on the host that hostname is reachable, so:

```sh
tailscale serve --bg --https=443 http://localhost:9200
tailscale serve --bg --https=443 --set-path=/faucet http://localhost:9300
```

`serve` is tailnet-only, which is the right default: anvil's admin methods are open and its development
keys are public knowledge, so a public tunnel would need an RPC relay in front of the chain. Keeping the
chain private avoids that entirely.

## What a visitor does

1. Open `/faucet`, paste their address, take the demo tokens.
2. Open `/`, connect a wallet, name the counterparty's address as the taker, share the link.
3. The counterparty opens the link and signs.

## Say these out loud

- **The tokens are worthless and the chain is a local fork.** The visitor's wallet shows their *real*
  balances for that chain id, which is the single most confusing thing about this demo.
- **An offer names one counterparty.** "Anyone with the link" is not how it works: the taker is part of
  the signed terms. Open offers are listed as a gap in `docs/LINK-SERVICE.md`.
- **Restarting the stack is a fresh chain.** Orders and balances reset; `reset-and-run.sh` can then
  re-provision. The contracts are CREATE2, so the addresses survive.
- **Nothing here is production.** No audit, no deployment, one process, local files.

## The three things that fail like bugs and are not

| Symptom | Cause |
| --- | --- |
| Stack healthy, nothing ever settles | `host.docker.internal` does not resolve on a plain Linux engine. The driver needs `extra_hosts: ["host.docker.internal:host-gateway"]`. |
| Sub-solver exits at once, driver auctions forever | 9100 is node_exporter's port. Set `SUBSOLVER_PORT` and match it in `config/offline/driver.toml`. |
| Sub-solver logs "acceptance not in this auction" | The orderbook still holds an older run's order. `reset-and-run.sh` clears it. |
