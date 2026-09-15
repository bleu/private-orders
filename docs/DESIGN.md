# Design

## The problem the design has to solve

A Private Trade is a trade two parties already agreed on. The interesting part is not the swap; it
is making each half unusable on its own:

- Alice's order must not be fillable by anyone except Bob.
- Bob's acceptance must not be fillable by any solver that happens to find Alice's order.
- Both halves must execute together, or neither does.

A plain GPv2 order cannot express "only valid in this pair". `GPv2Order.Data` has no `taker` field
and the settlement contract does not care who submits a valid order. Secrecy plus a bonded solver
gets close, but it is an operational promise, not an invariant.

## What makes it an invariant

Both orders are owned by contract accounts, so `GPv2Settlement` delegates order validity to their
`isValidSignature`. That turns order validity into arbitrary on-chain logic.

`PrivateTradeWrapper` is an authorised solver, so it is the only contract that can put the pair in
front of `GPv2Settlement.settle`. During that call it publishes `activeOfferId` and `activeTaker`.
`PrivateTradeOrder.verify` refuses to validate unless:

1. the caller is the settlement contract,
2. the supplied order hash matches the supplied order,
3. `activeOfferId` equals the `offerId` in that party's own `staticInput`,
4. `activeTaker` equals that party's counterparty,
5. the owner matches the role (maker or taker),
6. the order equals the order the terms imply.

Conditions 3 and 4 are the pair binding. Outside the wrapper's window `activeOfferId` is zero and
every order reverts.

## Fitting into Atomic Bundles

The wrapper is a CoW Atomic Bundle rather than a bespoke settlement entry point, so it inherits the
framework's entry point (`wrappedSettle(settleData, chainedWrapperData)`), its chained encoding, its
solver authentication, and its allowlist.

Three framework properties changed the design:

**The bundle must be last in the chain.** CoW's own documentation is explicit that `settleData` can
be rewritten by an intermediate bundle, and that validating it is therefore only meaningful when
nothing runs afterwards. The wrapper reverts unless `remainingWrapperData` is empty, which makes the
calldata it validated exactly the calldata `GPv2Settlement.settle` receives. Without that rule, a
later bundle could resize amounts or add an interaction after the checks passed.

**`wrapperData` is untrusted.** It is normally carried in the order's appData, which is aggregated by
the driver from a document it does not hash on-chain. Nothing in it is believed: the wrapper checks
it internally, and the orders re-check the published terms against the offer each party authorised
in ComposableCoW. A tampered `allowedTaker` produces a different `offerId` and the maker's own order
stops validating.

**The pair binding does not live in appData.** It would be tempting to bind the terms by making
`order.appData` the hash of the terms. It cannot work: GPv2's `appData` field must hash to the appData
document the orderbook stores, and that document cannot be reconstructed on-chain for arbitrary
terms. The binding therefore stays where it is enforceable — in the conditional order's `staticInput`,
which ComposableCoW hashes into the order's identity, plus the wrapper's published context.

## Why the maker does not commit to the taker's order hash

The obvious construction is mutual commitment: Alice's order commits to Bob's order UID, Bob's to
Alice's. That is a hash cycle; it cannot be computed.

Instead the maker commits to an `offerId`, which is a commitment to the maker's terms only:

```
offerId = H(PrivateOffer{ maker, allowedTaker, sellToken, sellAmount,
                          buyToken, buyAmount, validTo, salt })
```

The taker's obligation is derived, not hashed: `takerOrder(terms) = mirror(makerOrder(terms))`. The
wrapper checks that the two trades really are mirrors, and each handler checks that the settlement's
`activeOfferId` is the offer it authorised. `allowedTaker` lives inside `offerId`, so rewriting it —
or a different `salt`, or a different amount — produces a different `activeOfferId` and the maker's
order stops validating.

## The window, and the proof it was used

The pair binding needs a fact that is true only while the settlement is executing: `activeOfferId` and
`activeTaker`, which the order handlers read to refuse an order that does not belong to the pair being
settled. It lives in **transient** storage, so it cannot outlive the transaction that set it.

That is a statement about failure modes, not about gas — it costs about 3,000 more gas in a settlement
of 1.1M. With persistent storage, a later edit that returned early between opening the window and
closing it would leave the window open **forever**: every subsequent settlement would revert on the
reentrancy guard and the wrapper would be dead until redeployed. Transient storage cannot leak that way.
An impossible failure mode for 0.3% of a settlement is the trade.

Validating the settlement's calldata — before it runs — is what proves the orders are the right ones and
are priced reciprocally. What it does not prove is that a fill was recorded, and a bundle that returns
without delivering is exactly what the Atomic Bundle documentation warns about. So the wrapper reads
`filledAmount` for both legs before the settlement and requires it to have increased after: the
settlement's own record of what it moved, rather than an inference from the calldata being accepted.
The identifier is derived from the orders the settlement is about to execute, and getting it wrong is
not a silent failure — `filledAmount` reads zero for an order the settlement never saw, so every
settlement test would revert.

`_wrap` is three statements — refuse to share the window, open it, close it and check — because that is
the honest shape of what happens. `_open` and `_close` carry the detail, which also keeps each of them
inside the compiler's stack limit.

## Exactness, not "at least"

Both legs are fill-or-kill, fee-free, `BALANCE_ERC20` sell orders, and the wrapper requires
`executedAmount == sellAmount` for both. Reciprocity reuses GPv2's own equation,
`executedBuy = ceilDiv(sellAmount * sellPrice, buyPrice)`, and requires the result to equal the
agreed amount on both sides. GPv2's limit-price check alone would allow a better price on one leg;
this does not.

Interactions are rejected outright, in all three phases. A settlement that contains a Uniswap call
is not a bilateral trade, whatever the orders say.

## How a private trade executes

There is no orderbook, no auction, no price discovery and no solver competition. That is the premise
of the RFC, and the on-chain design depends on it: a private trade's orders are valid *only* inside
the settlement that pairs them, so publishing them serves no purpose.

The path is:

```
1. Maker creates an offer          -> service stores it, returns a link
2. Taker opens the link, accepts   -> service now holds both halves
3. Both parties sign               -> CoW Shed hook bundles (approve + authorise the order)
4. An allowlisted submitter calls  -> PrivateTradeWrapper.wrappedSettle(settleData, chainedWrapperData)
5. GPv2Settlement settles          -> both legs move, or nothing does
```

Step 4 is the whole integration. The orders never become public, so there is nothing to discover,
quote, rank or compete over.

Step 4 is built twice, deliberately:

- **Through BYOS**, the intended path. The submitter is BYOS: already bonded, already allowlisted,
  with escrow collateral absorbing reverts and its own fee mechanism. A private-trade sub-solver is
  an ordinary key — BYOS's integration guide is explicit that a sub-solver needs no solver seat and
  no allowlist entry, and the tests assert exactly that. The sub-solver signs
  `PrivateTradeProposal(wrapper, termsHash, validUntil)`, and the wrapper verifies that signature
  on-chain, so BYOS cannot substitute a payload and blame the sub-solver.
- **Through `PrivateTradeSubmitter`**, a deployed stateless contract, as a permissionless fallback
  for deployments that do not want BYOS in the path. Because the contract is the allowlisted
  identity, the caller needs no permission at all. It costs one extra allowlist entry and has no
  accountability layer, which is why it is the fallback and not the default.

`PrivateTradeBuilder` is the pure library both use. It needs no private key: order authorisation
comes from the Shed-owned conditional orders.

**One allowlisted submitter is required.** `CowWrapper.wrappedSettle` is `external` on the base
contract and not `virtual`, so it enforces `AUTHENTICATOR.isSolver(msg.sender)`, and the wrapper
itself must be allowlisted because it becomes the direct caller of `GPv2Settlement.settle`. That is
two entries in the same list CoW already maintains for solvers and bundles, and it is exactly the
role BYOS exists to fill: a bonded, already-allowlisted solver that submits on behalf of parties who
are not.

The submitter is transport, not a trust anchor. It cannot fill one half without the other, cannot
change the terms, cannot redirect the proceeds, and cannot reuse either order elsewhere — the wrapper
and the order handlers refuse all of that on-chain. A misbehaving submitter can only decline to
submit.

## If you route it through the standard flow instead

This is a rejected alternative, recorded because the findings are concrete and the temptation is
real: an order that enters the orderbook becomes visible to every solver, which is the opposite of
the premise, and three further obstacles follow.

**Creation-time signature validation can never pass.** An order valid only inside its settlement
cannot return a magic value when the orderbook calls `isValidSignature` during `POST /orders`. CoW
has the flag for this class of order (`--eip1271-skip-creation-validation`,
`crates/orderbook/src/arguments.rs:111-114`), but relaxing it means the orders are public.

**The stock solver cannot serve a private trade.** The baseline solver routes through AMM liquidity
and appends interactions. The wrapper rejects interactions outright, so a bundled solution would
need a purpose-built solver that submits exactly two fulfillments.

**The bundle must be echoed by the solver.** The driver reads `metadata.wrappers` from appData and
forwards it per order, the solver returns a flat `wrappers` list, and the driver sets
`to = wrappers[0].address`, encoding `wrappedSettle(settleData, chainedWrapperData)`. The wire format
uses `address`, not `target` (the public docs are wrong, the code is right), and full app data must
be registered with `PUT /api/v1/app_data/{hash}` or the driver sees no wrappers and settles without
them.

Two driver behaviours worth knowing if anyone does try it: the driver never cross-checks a solver's
`wrappers` against the orders' appData, and `Solution::merge` keeps only the left-hand solution's
wrappers, so a merged solution can lose its bundle. Neither weakens this design, because the wrapper
and the handlers enforce the pair regardless.

## Why not the alternatives

| Option | Why not |
| --- | --- |
| New `PrivateTradeSettlement` contract with two `transferFrom`s | Discards GPv2's signature, expiry, fill-state, and allowance handling; a new contract to audit; no path to JIT or BYOS |
| Fork `GPv2Settlement` and drop `onlySolver` | The contract documents security assumptions that depend on authorised solvers, including temporary use of settlement balances |
| Trust the bonded solver to only submit the pair | Works in practice, but the guarantee becomes a promise. This design keeps the solver as transport, not as the security boundary |
| GPv2 `AppData` to carry the counterparty | AppData is committed as a hash and is not otherwise interpreted on-chain; it hides intent but does not enforce it |

## Where it sits next to normal CoW

A normal CoW order asks "find me good execution". A Private Trade says "execution is already agreed;
just settle it". No auction, no price discovery, no competition — the settlement engine is reused,
the search layer is skipped.

That is also what makes it a plausible fit for BYOS: the proposal a sub-solver would submit is
mechanical (`fulfillment(taker) + JIT(maker)`), and the JIT leg is exactly the "private market
maker" pattern BYOS already anticipates.

## Open questions

1. **Who is allowed to call the wrapper.** Today, any allowlisted solver. A dedicated solver
   allowlist entry would narrow it further, but the security does not depend on it.
2. **Fees.** A protocol fee would need a third leg or a `feeAmount`, which breaks exactness. Not
   addressed.
3. **EOA funding.** Contract-wallet ownership is required for both parties. For EOA users the CoW
   Shed path supplies it; the funding and order-creation step is not in this repo yet.
4. **Non-ERC20 assets.** NFTs and game items need a different transfer mechanism, most likely a
   hook or an escrow leg.
5. **Driver semantics.** Whether the driver will accept a settlement containing two contract orders
   and no auction is still open, and is the next thing to test against `cow-offline-mode`.
6. **Composition with other bundles.** Requiring "last in the chain" is what makes the calldata
   check meaningful, but it means a private trade cannot currently be combined with a bundle that
   needs to run inside it. A pre-settlement funding bundle chained *before* the wrapper would work;
   one that must run after the settlement would not.
