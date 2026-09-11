# The link service

Turns an agreed trade into a shareable link, and drives it to settlement.

```
maker: POST /offers ──────────► link ──────────► taker: GET /offers/:id
       signs the digest                             signs the digest
       POST /offers/:id/signature                   POST /offers/:id/accept
                                                          │
                                          the service relays both hook bundles,
                                          hands the offer to the sub-solver,
                                          posts the taker's order
                                                          │
                                                          ▼
                                                    settlement
```

```bash
./scripts/link-service-e2e.sh
```

That script is the whole story: it deploys the contracts, allowlists the wrapper, starts the
sub-solver and the service, then acts as both parties. Against the offline stack it ends with:

```
==> settled
   maker shed USDC 600000000 -> 600000000   (sold)
   maker shed DAI  400000000000000000000 -> 500000000000000000000   (received)
   taker shed DAI  400000000000000000000 -> 400000000000000000000   (sold)
   taker shed USDC 400000000 -> 500000000   (received)
```

The sell side nets to zero on purpose: the party funded their Shed and the Shed spent it, both inside
the one signed bundle. The received side is the trade.

## Funding is part of the signature

The Shed owns the order, so it must hold the sell tokens before the pair can settle. Rather than
leaving that as a separate transfer, the funding call rides **inside the same signed bundle**:

```
transferFrom(you, yourShed, sellAmount)   // fund it
approve(vaultRelayer, sellAmount)         // let settlement take it
create(orderParams)                       // authorise the order
```

So a party does exactly two things: approve their Shed on the sell token **once**, then sign. One
signature funds the Shed and authorises the order, and there is no window where the order is live but
unfunded. Send `{"fund": false}` to `POST /offers` for authorisation only, if the party would rather
move the tokens themselves.

## What the service does and does not hold

It holds **no key that can move value**. It relays owner-signed hook bundles, which anyone may do,
and posts an order whose signature is an ERC-1271 payload, not a secret. The only signatures it ever
sees are the two parties'.

It also **never re-derives the trade**. `script/LinkCompute.s.sol` *is* `PrivateTradeBuilder`, so the
service cannot drift from the on-chain rules — it moves JSON and calls `forge`/`cast`. A service that
reimplemented the offer id, the appData document or the order structs in another language would be a
second source of truth, and the two would eventually disagree.

## API

| Route | Auth | Purpose |
| --- | --- | --- |
| `POST /offers` | none | Describe the trade. Returns the link, the funding instruction, and the digest the maker must sign. |
| `GET /offers/:id` | none | The link target: terms, plus the digest the taker must sign. |
| `GET /o/:id` | none | The same, as a page for a human. |
| `POST /offers/:id/signature` | none | `{role: "maker"\|"taker", signature}`. 65-byte `r \|\| s \|\| v`. |
| `POST /offers/:id/accept` | none | The taker accepts. Relays, publishes the offer to the sub-solver, posts the order. |
| `GET /offers/:id/status` | none | `open` / `signed` / `settling` / `settled`, derived from the chain and the orderbook. |
| `GET /health` | none | liveness |

There is no account system. The two signatures *are* the authorisation, and the service cannot use
them for anything except the trade they describe.

## Two things that will bite an integrator

**Sign the digest without a personal-message prefix.** `cast wallet sign` applies the EIP-191 header
unless `--no-hash` is passed. The wrong choice produces a signature that recovers to a different
address, and the Shed reports it only as `InvalidSignature()` — with no hint that signing was the
problem. `script/SignDigest.s.sol` signs raw and exists as the unambiguous reference.

**A party's Shed is not their address.** The *Shed* owns the order; the EOA only signs. The first
version of `LinkCompute` set the taker's Shed to the taker's EOA, and the relay failed with
`InvalidSignature()` because the recovered signer was not the Shed's admin. `LinkRelay` now checks
that the bundle it is about to relay hashes to the digest that was signed *and* that the signature
recovers to the Shed's owner, so that class of mistake reports itself instead of surfacing as an
opaque revert.

## Known gaps

- **The approval to the Shed is still a separate transaction**, because it must be signed by the
  party's own key. It is a one-time, standard ERC-20 approval per token, but it is not free and it is
  not batched with the signature. An EIP-2612 permit where the token supports it would remove it.
- **Storage is local files.** Offers live under `out-json/link/`. A deployment needs a database and
  a reaper for expired offers.
- **No offer expiry sweep.** An offer that is never accepted keeps its authorisation on-chain until
  `validTo`; nothing revokes it early.
- **Open offers are untested.** The path exists (`taker` optional, recomputed on accept) but only
  address-restricted offers are covered by the end-to-end script.
