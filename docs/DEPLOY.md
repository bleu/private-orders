# Deploying private trades

The four contracts deploy with `CREATE2` under one fixed salt, so:

- a dry run prints the addresses a broadcast will produce;
- the same four addresses appear on every chain, whoever sends the transaction;
- one audit and one allowlist entry cover both a Sepolia rehearsal and mainnet.

The addresses are a function of `(proxy, salt, init code)`. `forge script` does not create
`new{salt}` with the broadcasting account — it goes through the canonical deterministic deployment
proxy at `0x4e59b44847b379578588920cA78FbF26c0B4956C`, which is why the deployer key is not an input
to the address. The only constructor argument that varies is `settlement`, which CoW deploys at
`0x9008D19f58AAbD9eD0D60971565AA8510560ab41` on every chain it supports. Nothing in the derivation
reads the chain, and `test_derivationMatchesFoundrysOwn` proves the derivation agrees with
`vm.computeCreate2Address`'s own default deployer.

`test/PrivateTradeDeploy.t.sol` freezes the addresses and rejects the deployment if the prediction
does not match what was deployed. **Any change to a contract, a constructor argument, the deployer or
the salt fails that test** — which is the point: the addresses in the audit report have to keep
describing what is deployed.

## 0. Before anything

```bash
cp .env.example .env      # .env is git-ignored
set -a; . ./.env; set +a
```

- The deployer key needs gas on the chain you are deploying to. It does not affect the addresses.
  `DEPLOYER_ADDRESS`, when set, is checked against the key so the wrong key cannot be loaded.
- The addresses are pinned in `test/PrivateTradeDeploy.t.sol`. After any change to a contract,
  re-pin them deliberately:

```bash
forge test --match-contract PrivateTradeDeployTest -vv     # prints the four addresses to pin
```

## 1. Dry run (no broadcast, no gas)

```bash
forge script script/DeployPrivateTrade.s.sol --rpc-url "$RPC"
```

Prints `chainId`, `deployer`, `settlement`, the salt and the four addresses. Nothing is sent and
nothing is written: the manifests are written only in a broadcast. This is the command to run before
every real deployment, on every chain, and the printed addresses must be identical. Verified against
live mainnet state for release `private-trade.v1`:

```
wrapper    0x6AF00f967E04fE003ac2120fee81E5D32Ed68e70
handler    0x39e201DA745A9f6050B27736276515489385Ae57
submitter  0xe833E42Ad12bF2c72Ee4B761Ca020F638EF28AE5
authoriser 0x46724A7550549C4Df246819F6D4Eb4a22AF9600B
```

These move whenever the wrapper's bytecode changes, because the handler's init code embeds the
wrapper's address and the other two are compiled against both. `test/PrivateTradeDeploy.t.sol` pins
all four and fails with "re-pin if that was intended" — re-pin here too, in the same commit, or this
page describes a deployment that no longer exists.

## 2. Sepolia

```bash
RPC=https://sepolia.infura.io/v3/$KEY \
ORDERBOOK_URL=https://api.cow.fi/sepolia \
  forge script script/DeployPrivateTrade.s.sol --rpc-url "$RPC" --broadcast

DEPLOY_MANIFEST=out-json/deployments forge script script/DeployPrivateTrade.s.sol --rpc-url "$RPC" --broadcast
```

It writes `out-json/private-trade-deployed.json` (the path the link service and four shell scripts
read) and, when `DEPLOY_MANIFEST` is set, one `<chainId>.json` per chain. Copy that into
`deployments/` and commit it — that directory is the record of what is on chain.

## 3. Verify the source

The audit and the allowlist request both need readable source.

```bash
forge verify-contract <wrapper> src/PrivateTradeWrapper.sol:PrivateTradeWrapper \
  --constructor-args $(cast abi-encode "c(address)" "$SETTLEMENT_CONTRACT_ADDRESS") \
  --chain sepolia --watch
forge verify-contract <handler> src/PrivateTradeOrder.sol:PrivateTradeOrder \
  --constructor-args $(cast abi-encode "c(address)" <wrapper>) --chain sepolia --watch
forge verify-contract <submitter> src/PrivateTradeSubmitter.sol:PrivateTradeSubmitter --chain sepolia --watch
forge verify-contract <authoriser> src/PrivateTradeAuthoriser.sol:PrivateTradeAuthoriser --chain sepolia --watch
```

## 4. Allowlist

`GPv2Settlement.settle` is `onlySolver`, so the **wrapper** must be in
`GPv2AllowListAuthentication` (`0x2c4c28DDBdAc9C5E7055b4C863b72eA0149D8aFE`) or nothing settles.
This is a manager action; there is no bypass. Ask for the wrapper, and for `PrivateTradeSubmitter`
too unless BYOS is the caller — being on that list is administrative, so a contract appears as a
"solver" whatever it does.

```bash
cast call $AUTHENTICATOR "isSolver(address)(bool)" <wrapper> --rpc-url "$RPC"
```

## 5. Wire the service

```bash
export PRIVATE_TRADE_WRAPPER=<wrapper>
export PRIVATE_TRADE_HANDLER=<handler>
export PRIVATE_TRADE_AUTHORISER=<authoriser>
export COWSHED_COMPOSABLE_COW_FACTORY_ADDRESS=0x5E284e80F3bd6A7D80A8500D9c49878028110848
export COMPOSABLE_COW_ADDRESS=0xfdaFc9d1902f4e0b84f65F49f244b32b31013b74
export VAULT_RELAYER_ADDRESS=0xC92E8bdf79f0507f65a392b0ab4667716BFE0110
export RPC=... ORDERBOOK_URL=... PUBLIC_URL=...
node link-service/server.mjs
```

Check it before signing anything: create an offer, confirm the page shows the terms, and confirm the
computed `wrapper` is the deployed one.

## 6. Mainnet

Same commands, mainnet `RPC` and `ORDERBOOK_URL=https://api.cow.fi/mainnet`, after the audit and the
DAO allowlist. Then walk `docs/MAINNET-ROADMAP.md` phase 4: one small trade, cancellation path ready,
receipt evidence rather than a balance reading.

## Post-deploy checks

```bash
cast code <wrapper> --rpc-url "$RPC" | head -c 3          # 0x, not 0x0
cast call <wrapper> "name()(string)" --rpc-url "$RPC"     # PrivateTradeWrapper
cast call $AUTHENTICATOR "isSolver(address)(bool)" <wrapper> --rpc-url "$RPC"   # true
cast call <handler> "WRAPPER()(address)" --rpc-url "$RPC"  # the wrapper
cast call <wrapper> "offerState(bytes32)(uint8)" 0x00… --rpc-url "$RPC"          # 0 = available
```

If a redeploy ever gets a *different* address than the dry run printed, stop: the init code hash and
the creation code have drifted apart, which means the audited artefact is not what was deployed.

The deploy script is also exercised end to end by `./scripts/private-trade-e2e.sh` against anvil, so
run that once after any change to it.
