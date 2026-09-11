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

## Exactness, not "at least"

Both legs are fill-or-kill, fee-free, `BALANCE_ERC20` sell orders, and the wrapper requires
`executedAmount == sellAmount` for both. Reciprocity reuses GPv2's own equation,
`executedBuy = ceilDiv(sellAmount * sellPrice, buyPrice)`, and requires the result to equal the
agreed amount on both sides. GPv2's limit-price check alone would allow a better price on one leg;
this does not.

Interactions are rejected outright, in all three phases. A settlement that contains a Uniswap call
is not a bilateral trade, whatever the orders say.

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
