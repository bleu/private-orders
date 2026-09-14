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
sub-solver and the service, then acts as both parties. It asserts, rather than reports:

- both permits were applied by the relayer, per side, so neither party's `approve` was needed
- neither party's transaction count moved — neither of them sent a transaction
- the maker's wallet gained the buy token and the taker's wallet gained the sell token
- neither Shed gained anything: the proceeds are paid to the wallets, not to the contracts that hold
  the orders

Run it against the offline stack; it needs the orderbook and the settlements contracts up.

It was not re-run for the wallet-safety revision: Docker was not available on this machine, so the
browser and real-chain path is asserted by `docs/review/page-safety.mjs` (real Chrome, fixture chain)
rather than by that script.

## Funding, and why neither party pays gas

The Shed owns the order, so it must hold the sell tokens before the pair can settle. Two things make
that happen without the party sending a transaction.

**The funding rides inside the signed bundle:**

```
transferFrom(you, yourShed, sellAmount)   // fund it
approve(vaultRelayer, sellAmount)         // let settlement take it
create(orderParams)                       // authorise the order
```

**The allowance to the Shed comes from a `permit`.** Where the token supports it *and* its typed data
can be reproduced from the token's own `DOMAIN_SEPARATOR()`, the party signs an EIP-712 permit
instead of sending an `approve`, and the relayer submits it. So a party does two signatures and zero
transactions:

| | |
| --- | --- |
| Bundle digest | Funds the Shed and authorises the order |
| Permit digest | Grants the Shed its allowance |

Both shapes in the wild are supported, detected from the token rather than assumed:

- **EIP-2612** — `permit(owner, spender, value, deadline, v, r, s)`. USDC, and most modern tokens.
  The allowance is exactly the trade amount.
- **DAI-style** — `permit(holder, spender, nonce, expiry, allowed, v, r, s)`. DAI. This shape has no
  amount: `allowed: true` sets the allowance to the maximum. The service reports
  `"allowance": "unlimited"` and the page says so, because claiming an amount-limited approval that
  does not happen is the kind of untruth the page exists to avoid.

The digest is built from the token's own `DOMAIN_SEPARATOR()`, so there is no second EIP-712 domain to
get wrong.

**Where permit is unavailable, the party approves and then signs.** Two cases reach this path, and
the service reports which:

- the token has no permit function at all
- the token has one, but its EIP-712 domain fields cannot be reproduced from its own
  `DOMAIN_SEPARATOR()`, so no wallet can be shown what it is signing

```json
"funding": { "mode": "permit", "kind": "eip2612", "allowance": "exact", "digest": "0x…" }
"funding": { "mode": "permit", "kind": "dai", "allowance": "unlimited", "digest": "0x…" }
"funding": { "mode": "approve", "reason": "this token has no permit",
             "approve": { "to": "0x…", "data": "0x095ea7b3…", "value": "0x0" } }
```

`approve.data` is the `approve(spender, amount)` calldata, built by the service. The page sends that
transaction and never assembles one of its own, so what the reader approves is what the server
intended. It then polls the allowance rather than trusting the transaction: a replaced, dropped or
wrong-account approval leaves the allowance short, and that is what the flow waits for.

Three things decide whether permit is used, and all are deliberate:

- **Detection is a `staticcall` on the selector.** A token that writes storage before validating
  reverts with no data under a static call, which looks exactly like the function not existing. Such
  a token is reported as unsupported and the party falls back to `approve`. The cost is one needless
  transaction; the alternative is a signature no contract accepts.
- **No typed data means no permit signature.** There is no way to ask a wallet to sign a bare EIP-712
  digest correctly: `personal_sign` adds the EIP-191 header, and the signature then recovers to a
  different address. That path is not offered.
- **The relay checks the allowance afterwards, not the permit call's result.** A permit can be
  front-run, and a front-runner grants exactly the same allowance. So the relay treats a failed
  permit call as fine and then asserts the allowance, failing with the token and spender to approve
  directly if it is missing. An `approve` already in place short-circuits the permit entirely, which
  is what makes the approve path and the retry path the same code.

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

## Where the money lands

Each order is built with `receiver` set to **the party's own wallet**. The Shed owns the order, but
the proceeds belong to the person, so a settlement pays the wallet directly and nothing is left in a
contract afterwards. Before this, the receiver was the owner — the Shed — and every trade ended with
the reader owning tokens they had no way to move.

The beneficiary is declared in the terms rather than read from the Shed while building the order,
for two reasons: orders are built before the Sheds exist, and a Shed's admin is not readable from
outside it. The proxy answers `admin()` only when the caller is the proxy itself, so the
implementation can read it and nobody else can. A service that always sets the beneficiary to the
party's own wallet, and shows that address on the page, is what makes it safe — an on-chain check
would need the bundle to delegatecall a helper, which is the only context where a Shed can read its
own admin.

## Getting the money out, if anything is left

Nothing should be left, now that proceeds are paid to the wallet. But a trade settled before that
change, or sell tokens the trade did not spend, can still sit in a Shed — and a Shed is a contract
only its owner can move them out of.

So a settled trade shows a receipt **and** whatever is still in the Shed, with one button that sweeps
every token in it to the party's wallet. One signature, still no gas, no approval.
`script/Withdraw.s.sol` computes the bundle, the party signs the digest, and the service relays it.

The relay **replays the computed plan and never recomputes it.** A recomputed deadline is a different
message, and a signature that is perfectly valid for what was signed fails against it — which is the
mistake the script made first, and it looked exactly like a broken signature.

## Lifecycle, and what a status means

An offer moves through states the service derives from the chain and the orderbook, not from its own
bookkeeping. `GET /offers/:id/status` returns one of:

| Status | Meaning |
| --- | --- |
| `open` | Created. Neither party has signed. |
| `signed` | At least one party has signed. |
| `expired` | Past `validTo` and no order was posted. |
| `funding` / `funded` / `published` | An acceptance is in progress. Reported only while it is running. |
| `recovery_available` | Funding succeeded, but publishing or posting the order failed. The reason is in `error`; the party can still withdraw from its Shed. |
| `settling` | An order was posted and is not yet fully evidenced as settled. |
| `settled` | The intended order is fulfilled, its transaction has a successful receipt, and the wrapper reports the offer consumed. All three, or it is not settled. |
| `cancelled` | The maker revoked the order and cancelled the offer, in one owner-signed transaction. |

The maker cancels with `GET /offers/:id/cancel` (returns the digest and typed data) and
`POST /offers/:id/cancel` (relays the signature). The bundle executes two calls from the maker's Shed:
`ComposableCoW.remove` and `cancelOffer` on the wrapper. Both or neither — a cancellation cannot
leave the order revoked but the offer still settleable, and it cannot lose the race to a settlement,
because a consumed offer refuses to be cancelled.

**Retries are safe by construction.** The relay skipped a Shed whose bundle nonce is already spent
before it touches the permit, so a retry after partial funding converges instead of failing on a
consumed permit. The order UID is derived from the order, so re-posting an accepted offer is the same
order.

## Before a signature is taken

A wallet prompt is expensive to take back, so everything that can be known before one is asked is
asked first. `GET /offers/:id/role` reports the result as `ready`, and both `POST .../signature` and
`POST .../accept` refuse with `409` while any of it fails — the page shows the same reasons and
disables the button:

| Check | What it catches |
| --- | --- |
| `validateWrapperData` accepts the payload | the same call the settlement makes, so a malformed offer is refused before anyone commits |
| the wrapper is allowlisted as a solver | read from `AUTHENTICATOR().isSolver(wrapper)`, so a missing solver seat is a sentence rather than an opaque revert at settlement time |
| the offer is still available | read from the wrapper, so a cancelled or consumed offer cannot be signed for |
| the offer has not expired | the chain's clock, not the page's |
| this side holds what it is selling | the relay pulls from the party's own account, so an unfunded side fails only after both signatures are collected |
| the account can be authorised by one signature | see below |

Every passing check is shown under "Verify independently" on the page, so the reader can see what was
established rather than take the sentence on trust. A check whose answer cannot be read is reported as
passing: an unreadable chain is not evidence of a problem, and blocking a working flow on a flaky read
is worse than missing a warning. The settlement still refuses if the fact really is missing.

**The relay is simulated before it is broadcast.** `LinkRelay` runs once without `--broadcast` — forge
applies the whole script against current state and stops at the first call that would fail — and only
then for real. A signature the Shed refuses, a nonce already spent, or an allowance that never arrived
are reported before a transaction is paid for and before the taker is told the trade is settling.
`RELAY_DRY_RUN=0` skips the extra pass.

## Accounts that are contracts

A party's account can be a smart contract rather than an account holding a key — a Safe, most often.
Two things change, and the service decides both from `cast code` on the account:

- **Funding.** A token permit is verified by `ecrecover` *inside the token*, so a contract account
  cannot produce one at all. Offering that prompt costs a signature and then fails on the allowance,
  blaming the party for something impossible. Such a side funds by an `approve` transaction instead,
  which the service describes as calldata the page sends unmodified.
- **Signature validation.** The Shed already handles this: `LibAuthenticatedHooks.authenticateHooks`
  asks an owner with code over EIP-1271 and recovers an owner without it. The service asks the same
  way, so a contract account's correct signature is not reported as a wrong one by `ecrecover`. The
  relay's own pre-check branches the same way, in `ShedBundle.validSignature`.

**The message matters more than the signature count.** A Safe does not verify a signature over the
trade's digest; `CompatibilityFallbackHandler` and `SignatureVerifierMuxer.defaultIsValidSignature`
both check its owners' signatures over `hashMessage(digest)`. So the page cannot hand a Safe the
trade's own EIP-712 message and expect the result to be accepted — it asks for a `SafeMessage` whose
`message` is the digest, which hashes to exactly what the account checks. The signature that comes
back is opaque: the service never inspects its shape beyond a length sanity check, and asks the
account whether it is valid.

**Collecting the owners is the account's job, not ours.** A 2-of-3 Safe gathers its owners through its
own tooling — the Safe App, WalletConnect, the Safe SDK — and returns one blob, whose owners' ECDSA
signatures are concatenated in ascending address order because `Safe.checkSignatures` requires a
strictly increasing signer. None of that belongs in this service or this page: the threshold and owner
count are *reported* so the page can say what to expect, and never gate anything. What the app owes in
exchange is to accept a blob of any reasonable length and to judge it by asking the account.

## Truthfulness, and where the page comes from

A page that asks for a signature has one job, and it is not looking nice: it has to say what is about
to be authorised. Three rules follow from that, and they are enforced by
`docs/review/page-safety.mjs` in a real browser.

**Untrusted text never becomes markup.** A token's symbol is chosen by whoever deployed the token, and
it lands on a signing page. Symbols, wallet names, error strings, addresses and transaction hashes all
go through one escape function before they reach the DOM; the browser check feeds the page a symbol
containing an `<img onerror>` and asserts that no element appears and no script runs.

**The allowance is described as what it is.** `exact` for EIP-2612 permits and approvals, `unlimited`
for DAI-style permits, words rather than a number for the unlimited case.

**The chain is checked before signing, not after failing.** The page compares the wallet's
`eth_chainId` with the chain the trade was signed for and refuses to sign on a mismatch, naming both
chains. It re-reads the active account immediately before every signature, because a wallet signs
with whichever account is selected rather than the one the page connected with.

## Known gaps

- **A party signs twice.** The bundle and the permit are separate EIP-712 domains (the Shed's and the
  token's), so they cannot be merged into one message. Two signatures and no transaction beats one
  signature and a transaction for a taker with no ETH, but it is not the theoretical minimum.
- **Received tokens land in the Shed, which is one extra step.** Every order is built with
  `receiver` set to the party's own wallet — `makerBeneficiary` is the maker's address and
  `takerBeneficiary` the taker's — so the proceeds arrive in the wallet and the Shed does not gain.
  What the withdrawal button is for is the other case: sell tokens the trade never spent. Setting the
  receiver was a terms change, which is why the button came first.
- **A permit signed at offer time can expire before settlement.** Its deadline is the offer's, so a
  long-lived offer needs a fresh permit rather than a stale one.
- **Storage is local files.** Offers live under `out-json/link/`. Records and sub-solver files are
  written to a temporary file and renamed, so a reader never sees a partial one, but a deployment
  needs a database and a reaper for expired offers.
- **Acceptance locking is per process.** A second acceptance of the same offer is refused while one is
  in flight, but only within one service process. Two instances over one store still need a
  store-level lock or a single writer; the worst case is duplicated relay work and a confusing second
  answer, because the relay is idempotent and the order UID is derived from the order.
- **No offer expiry sweep.** An offer that is never accepted keeps its authorisation on-chain until
  `validTo`; nothing revokes it early. `validTo` is enforced by the order itself.
- **Open offers are not supported.** A concrete taker address is required at creation; the earlier
  optional-taker path recomputed terms on accept and invalidated the maker's signature. Supporting it
  needs a separate authorization design.
- **Synchronous subprocess calls.** Computing, relaying and cancelling run `forge`/`cast` in the
  request path, which blocks the process for the duration. Fine for a beta; a queue is the next step.
