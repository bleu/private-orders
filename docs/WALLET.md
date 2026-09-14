# Running the flow with a real wallet

The last unproven step. Every other check uses the service's development wallet, which signs whatever
it is asked to sign without a UI in between. A wallet extension is where this project has already been
wrong twice: a typed-data payload sent as an object instead of a JSON string (Rabby rejects it), and a
wallet signing with the *selected* account rather than the connected one.

**Run once, by hand, with Rabby — and it worked.** On 2026-09-14, against the offline stack, the whole
flow settled as tx `0x31d6c0663a9991f5d60b3df7efab4d442e0bead852f25d5f28f7dd441bd4231c`:

- receipt status `0x1`, submitted by the relayer `0xf39Fd6e5…`, not by either party
- wrapper `consumed`, order `fulfilled`, receipt succeeded — the page's `settled` was the chain's answer
- neither party's nonce moved: no transaction anywhere in the flow
- both prompts rendered as readable EIP-712: a **COWShed** domain and an **ExecuteHooks** message, no
  hex blob, and no prompt mentioned gas

The steps below are the ones that were followed. The one that took a decision was the wallet setup:
chain id 1 must come from *overriding Ethereum's RPC*, not from adding a network.

## 1. Start the stack

```bash
colima start                      # this machine has no Docker Desktop; see docs/OFFLINE.md
cd ../offline-mode
docker compose up -d chain-deployer chain db db-migrations coingecko-mock \
  orderbook autopilot driver baseline
cd ../private-orders
./scripts/wallet-e2e.sh
```

`wallet-e2e.sh` deploys the contracts, allowlists the wrapper, funds two wallets with what they will
sell, and starts the sub-solver and the link service **without development keys**. It prints everything
below. If it has already run, re-running it is safe and resets the offer store.

## 2. Point the wallet at the local chain

The trade is signed for **chain id 1**, and the chain check on the page compares it with what the
wallet reports. So the wallet has to report chain id 1 while talking to `http://localhost:8545`,
which means overriding the RPC URL of *Ethereum*, not adding a new network.

**Rabby** — Settings → Modify RPC URL (or the network menu) → Ethereum → add `http://localhost:8545`
→ enable it. Rabby allows this, and this is the wallet the project has been tested against.

**MetaMask** — cannot do this: "Add network" refuses a chain id that already exists, and mainnet's RPC
cannot be pointed at localhost. Use Rabby, or a second browser profile with Rabby.

Import the maker account, and the taker account as well if you want one browser to play both sides:

```
maker   0x70997970C51812dc3A010C7d01b50e0d17dc79C8
        0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d

taker   0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
        0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
```

These are anvil's default accounts 1 and 2 (mnemonic `test test test … junk`). They hold ETH for gas,
though the flow should never need it.

## 3. Make the offer

Open `http://localhost:9200/`, connect as the **maker**, and create:

| Field | Value |
| --- | --- |
| You give (token address) | the USDC address `wallet-e2e.sh` printed, pre-filled |
| amount, in the smallest unit | `100000000` (100 USDC) |
| You want (token address) | the DAI address, pre-filled |
| amount, in the smallest unit | `100000000000000000000` (100 DAI) |
| The wallet you are trading with | the taker address |
| Offer expires in (hours) | anything |

## 4. Sign as the maker

The page should show two steps and one button. Signing asks for **two prompts**: the permit, then the
order authorisation. Neither is a transaction, and the wallet should say so.

Then copy the link the page shows. It is the canonical URL, without the wallet query string.

## 5. Sign as the taker

Open the link. Switch the wallet to the taker account first if you are using one browser. The page
should show what the taker pays and receives, then the same two prompts.

## What to look for

The reason to do this by hand. Each of these has been a real failure here, or would be one:

1. **Both wallets show readable prompts.** The order prompt should show a COWShed domain and an
   `ExecuteHooks` message, not a hex blob. If a wallet renders the EIP-712 message as raw bytes, its
   typed-data support is the problem — and the page falls back to nothing, by design: it does not
   offer `personal_sign` over a digest, because that signature cannot be valid.
2. **The wallet used the account the page connected with.** Switch the wallet to a third account
   *after* connecting, then press sign. The page must refuse with a sentence naming both accounts. If
   it instead collects a signature, the relay will reject it later with a paragraph about the wrong
   account — that is the failure this check exists to prevent.
3. **The chain check fires.** The local chain is chain id 1, the same as Ethereum, so the mismatch
   case needs the wallet on a genuinely different network: switch to Polygon (or any other chain) and
   press sign. The page must refuse and name both chains, rather than collecting a signature the local
   chain would reject.
4. **Settlement produces a receipt, not a spinner.** The page polls and then shows the settlement
   transaction. If it sits at "waiting for a solver", check `/tmp/subsolver.out`.
5. **Both wallets are unchanged in ways you can see.** The wallet's nonce should not move: neither
   party sends a transaction. A prompt that says "this will cost gas" means the permit path was not
   taken, which means the token's typed data was unavailable — check the `permit` kind the page shows.

## Useful while running

```bash
tail -f /tmp/link-service.out        # every request the service handled
tail -f /tmp/subsolver.out           # whether the pair was picked up
cast block-number --rpc-url http://localhost:8545
curl -s http://localhost:9200/offers/<id>/status | python3 -m json.tool
```

If something fails, the most useful thing to capture is the **exact prompt text** the wallet showed
plus the service's response in `/tmp/link-service.out`. The service logs the reason it rejected a
signature, including which account it recovered.
