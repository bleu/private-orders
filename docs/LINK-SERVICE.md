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
   neither party sent a transaction (maker nonce 6, taker nonce 6)
==> settled
   maker shed USDC 600000000 -> 600000000   (sold)
   maker shed DAI  400000000000000000000 -> 500000000000000000000   (received)
   taker shed DAI  400000000000000000000 -> 400000000000000000000   (sold)
   taker shed USDC 400000000 -> 500000000   (received)
```

The sell side nets to zero on purpose: the party funded their Shed and the Shed spent it, both inside
the one signed bundle. The received side is the trade.

## Funding, and why neither party pays gas

The Shed owns the order, so it must hold the sell tokens before the pair can settle. Two things make
that happen without the party sending a transaction.

**The funding rides inside the signed bundle:**

```
transferFrom(you, yourShed, sellAmount)   // fund it
approve(vaultRelayer, sellAmount)         // let settlement take it
create(orderParams)                       // authorise the order
```

**The allowance to the Shed comes from a `permit`.** Where the token supports it, the party signs an
EIP-712 permit instead of sending an `approve`, and the relayer submits it. So a party does two
signatures and zero transactions:

| | |
| --- | --- |
| Bundle digest | Funds the Shed and authorises the order |
| Permit digest | Grants the Shed its allowance |

The permit signature is safe to publish: it can only move that amount into the party's own Shed, and
the bundle's `transferFrom` is the thing that spends it. It is also permissionless to submit, so no
one can hold it hostage.

Both shapes in the wild are supported, detected from the token rather than assumed:

- **EIP-2612** — `permit(owner, spender, value, deadline, v, r, s)`. USDC, and most modern tokens.
- **DAI-style** — `permit(holder, spender, nonce, expiry, allowed, v, r, s)`. DAI.

The digest is built from the token's own `DOMAIN_SEPARATOR()`, so there is no second EIP-712 domain to
get wrong.

**Where permit is unavailable, nothing breaks.** The party sends one `approve` to their Shed and then
signs as before. The service reports which case applies, so a client never has to guess:

```json
"funding": { "mode": "permit", "kind": "eip2612", "digest": "0x…", "spender": "0x…" }
"funding": { "mode": "approve", "approve": "approve(0x…, 100000000) on 0x…" }
```

Two things decide whether permit is used, and both are deliberate:

- **Detection is a `staticcall` on the selector.** A token that writes storage before validating
  reverts with no data under a static call, which looks exactly like the function not existing. Such
  a token is reported as unsupported and the party falls back to `approve`. The cost is one needless
  transaction; the alternative is a signature no contract accepts.
- **The relay checks the allowance afterwards, not the permit call's result.** A permit can be
  front-run, and a front-runner grants exactly the same allowance. So the relay treats a failed
  permit call as fine and then asserts the allowance, failing with the token and spender to approve
  directly if it is missing.

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

- **A party signs twice.** The bundle and the permit are separate EIP-712 domains (the Shed's and the
  token's), so they cannot be merged into one message. Two signatures and no transaction beats one
  signature and a transaction for a taker with no ETH, but it is not the theoretical minimum.
- **A permit signed at offer time can expire before settlement.** Its deadline is the offer's, so a
  long-lived offer needs a fresh permit rather than a stale one.
- **Storage is local files.** Offers live under `out-json/link/`. A deployment needs a database and
  a reaper for expired offers.
- **No offer expiry sweep.** An offer that is never accepted keeps its authorisation on-chain until
  `validTo`; nothing revokes it early.
- **Open offers are untested.** The path exists (`taker` optional, recomputed on accept) but only
  address-restricted offers are covered by the end-to-end script.
