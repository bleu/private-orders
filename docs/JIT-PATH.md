# The JIT + fulfillment path

The maker's order never reaches the orderbook. The taker's order does, and a sub-solver pairs them by
injecting the maker's half as a JIT trade:

```
taker posts an order (orderbook)          the only public half
        │
        ▼
autopilot auction
        │
        ▼
driver ──POST /solve──► private-trade sub-solver      holds the private offer
        │                        │
        │                        └── returns one solution:
        │                               trades: [jit(maker), fulfillment(taker)]
        │                               wrappers: [private trade wrapper]
        │                               interactions: []
        ▼
driver encodes wrappedSettle(settleData, chainedWrapperData), target = the wrapper
        │
        ▼
PrivateTradeWrapper validates the exact pair, publishes the terms
        │
        ▼
GPv2Settlement.settle — both legs move, or nothing does
```

Verified on the offline stack:

```
tx      0x3e179a9d2ff11a56ad5d0456f683f46501b3cdaf942183558c72e6eb24af1d10
to      0xfcDB4564c18A9134002b9771816092C9693622e3
method  wrappedSettle(bytes,bytes)
status  success, gasUsed 309906
result  taker DAI 300 → 200, maker USDC 300 → 200
```

Run it with `./scripts/private-trade-e2e.sh`; see [OFFLINE.md](OFFLINE.md) for the stack.

## Why this shape

The taker's order can be public without weakening anything: the wrapper demands exactly two trades,
exact reciprocity, both owners and zero interactions, so no solver can fill either half alone. Privacy
becomes a property of the maker's side, not a security boundary. That is the difference from an
earlier design where the confidentiality itself was load-bearing.

`interactions: []` matters. The stock baseline solver routes through AMM liquidity and appends
interactions, which the wrapper rejects by design — a private trade is not routed.

## Five things the driver requires, learned the hard way

1. **One `DRIVERS` entry per solver.** The driver mounts each configured solver at its own path
   (`mounting solver solver=private-trade path="/private-trade"`), so the autopilot must list
   `private-trade|http://driver/private-trade|…` separately. Configuring the solver in the driver
   alone is not enough; the autopilot never calls it.

2. **The autopilot's signature sweep must be off.** `DISABLE_1271_ORDER_SIG_FILTER=true`. The
   orderbook's `EIP1271_SKIP_CREATION_VALIDATION=true` only covers order creation; the autopilot
   re-validates signatures in the background and drops anything that does not validate, which is every
   private trade order by construction. The flag's own documentation describes this case: signatures
   that only become valid during execution.

3. **A fulfillment's signature is the payload *without* the owner prefix.** The driver's encoder
   concatenates `signer || signature.data` for EIP-1271, so an API order must carry
   `abi.encode(order, payload)`. Posting the on-chain form, `abi.encodePacked(owner, payload)`, makes
   the driver produce `owner || owner || payload`, and the Shed's `abi.decode` reverts with no data.
   A JIT order spec is the opposite: it carries the prefixed form, because the driver does not add the
   signer there.

4. **The token array is not two entries.** The driver emits one entry per order side, so a two-order
   settlement carries six. The wrapper therefore validates through each trade's own token indices
   instead of assuming `tokens[0]`/`tokens[1]`, and looks up prices by the maker trade's indices.

5. **A limit order fulfillment needs an explicit fee.** `fee: "0"`. Omitting the field means
   `Fee::Static`, and the driver rejects that for limit orders with `invalid fulfillment: invalid
   executed amount` — a message that names the wrong problem.

## Still open

- **Batching is impossible by construction.** The wrapper requires exactly two trades, and
  `Solution::merge` keeps only the left side's wrappers, so a merged solution would carry four trades
  and one bundle and be rejected. Private trades never share a settlement transaction.
- **The pair needs a fulfillment.** The driver's empty-solution filter treats `Fulfillment => true`
  and `Jit => surplusCapturingJitOrderOwners.contains(signer)`, so two JITs would be filtered out.