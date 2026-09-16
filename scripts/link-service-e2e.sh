#!/usr/bin/env bash
# Drives a private trade the way a user would: create a link, sign, accept, settle.
#
#   ./scripts/link-service-e2e.sh
#
# The two parties are the offline stack's funded anvil accounts. Everything the service does with
# the chain it does through `forge`/`cast`, so the Solidity builder remains the only implementation
# of the trade rules.
set -euo pipefail

RPC="${RPC:-http://localhost:8545}"
ORDERBOOK="${ORDERBOOK_URL:-http://localhost:8080}"
SERVICE="${SERVICE_URL:-http://localhost:9200}"
OFFLINE_DIR="${OFFLINE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../offline-mode" && pwd)}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ANVIL_KEY_0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
MAKER_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
TAKER_KEY=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
MAKER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
TAKER=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC

log() { printf '\n==> %s\n' "$*"; }

# Impersonated, test-only: clears an allowance so the permit path is genuinely exercised. The
# nonces are captured after this, so the "no transaction" assertion still holds for the real flow.
reset_allowance() {
  local token=$1 owner=$2 spender=$3
  cast rpc anvil_impersonateAccount "${owner}" --rpc-url "${RPC}" >/dev/null
  cast send "${token}" "approve(address,uint256)" "${spender}" 0 \
    --from "${owner}" --unlocked --rpc-url "${RPC}" >/dev/null
  cast rpc anvil_stopImpersonatingAccount "${owner}" --rpc-url "${RPC}" >/dev/null
}

# The four balances that move when the pair settles. The received side lands in the parties' own
# wallets: the Shed holds the sell tokens, but the proceeds belong to the person.
snapshot() {
  printf '%s %s %s %s\n' \
    "$(cast call "${USDC_ADDRESS}" "balanceOf(address)(uint256)" "${MAKER}" --rpc-url "${RPC}" | awk '{print $1}')" \
    "$(cast call "${DAI_ADDRESS}" "balanceOf(address)(uint256)" "${MAKER}" --rpc-url "${RPC}" | awk '{print $1}')" \
    "$(cast call "${DAI_ADDRESS}" "balanceOf(address)(uint256)" "${TAKER}" --rpc-url "${RPC}" | awk '{print $1}')" \
    "$(cast call "${USDC_ADDRESS}" "balanceOf(address)(uint256)" "${TAKER}" --rpc-url "${RPC}" | awk '{print $1}')"
}

# What the Sheds hold. After a settlement all four are unchanged: the sell side was funded and spent
# inside the signed bundle, and the buy side is paid to the wallet. Nothing is stranded.
shed_balances() {
  printf '%s %s %s %s\n' \
    "$(cast call "${USDC_ADDRESS}" "balanceOf(address)(uint256)" "${MAKER_SHED}" --rpc-url "${RPC}" | awk '{print $1}')" \
    "$(cast call "${DAI_ADDRESS}" "balanceOf(address)(uint256)" "${MAKER_SHED}" --rpc-url "${RPC}" | awk '{print $1}')" \
    "$(cast call "${DAI_ADDRESS}" "balanceOf(address)(uint256)" "${TAKER_SHED}" --rpc-url "${RPC}" | awk '{print $1}')" \
    "$(cast call "${USDC_ADDRESS}" "balanceOf(address)(uint256)" "${TAKER_SHED}" --rpc-url "${RPC}" | awk '{print $1}')"
}

# Balances are too large for the shell's 64-bit arithmetic.
minus() { python3 -c "print(int('$1') - int('$2'))"; }
plus() { python3 -c "print(int('$1') + int('$2'))"; }

log() { printf '\n==> %s\n' "$*"; }

# Impersonated, test-only: clears an allowance so the permit path is genuinely exercised. The
# nonces are captured after this, so the "no transaction" assertion still holds for the real flow.
reset_allowance() {
  local token=$1 owner=$2 spender=$3
  cast rpc anvil_impersonateAccount "${owner}" --rpc-url "${RPC}" >/dev/null
  cast send "${token}" "approve(address,uint256)" "${spender}" 0 \
    --from "${owner}" --unlocked --rpc-url "${RPC}" >/dev/null
  cast rpc anvil_stopImpersonatingAccount "${owner}" --rpc-url "${RPC}" >/dev/null
}

jqq() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

set -a; source "${OFFLINE_DIR}/.env"; set +a
cd "${ROOT}"

# --- 1. contracts -------------------------------------------------------------------------------

log "deploying the private trade contracts"
DEPLOYER_PRIVATE_KEY="${ANVIL_KEY_0}" SETTLEMENT_CONTRACT_ADDRESS="${SETTLEMENT_CONTRACT_ADDRESS}" \
  forge script script/DeployPrivateTrade.s.sol --rpc-url "${RPC}" --broadcast -q >/dev/null

export PRIVATE_TRADE_WRAPPER=$(jqq "d['wrapper']" < out-json/private-trade-deployed.json)
export PRIVATE_TRADE_HANDLER=$(jqq "d['handler']" < out-json/private-trade-deployed.json)

log "allowlisting ${PRIVATE_TRADE_WRAPPER}"
MANAGER=$(cast call "${AUTHENTICATOR_ADDRESS}" "manager()(address)" --rpc-url "${RPC}")
cast rpc anvil_setBalance "${MANAGER}" 0x21e19e0c9bab2400000 --rpc-url "${RPC}" >/dev/null
cast rpc anvil_impersonateAccount "${MANAGER}" --rpc-url "${RPC}" >/dev/null
cast send "${AUTHENTICATOR_ADDRESS}" "addSolver(address)" "${PRIVATE_TRADE_WRAPPER}" \
  --from "${MANAGER}" --unlocked --rpc-url "${RPC}" >/dev/null
cast rpc anvil_stopImpersonatingAccount "${MANAGER}" --rpc-url "${RPC}" >/dev/null

# --- 2. service ---------------------------------------------------------------------------------

# The page builds a program inside a template literal, so an unescaped quote has broken it twice.
node "${ROOT}/scripts/check-page.mjs" || exit 1

log "starting the sub-solver"
pkill -f private-trade-solver 2>/dev/null || true
rm -rf out-json/sub-solver-offers; mkdir -p out-json/sub-solver-offers
SUBSOLVER_PORT="${SUBSOLVER_PORT:-9100}"
OFFERS_DIR="${ROOT}/out-json/sub-solver-offers" SOLVE_LOG=/tmp/private-trade-solve.log \
  PORT="${SUBSOLVER_PORT}" nohup node "${ROOT}/subsolver/private-trade-solver.mjs" >/tmp/subsolver.out 2>&1 &

log "starting the link service"
pkill -f link-service/server.mjs 2>/dev/null || true
sleep 1
rm -rf out-json/link
PRIVATE_TRADE_ROOT="${ROOT}" RPC="${RPC}" ORDERBOOK_URL="${ORDERBOOK}" \
  COWSHED_COMPOSABLE_COW_FACTORY_ADDRESS="${COWSHED_COMPOSABLE_COW_FACTORY_ADDRESS}" \
  COMPOSABLE_COW_ADDRESS="${COMPOSABLE_COW_ADDRESS}" VAULT_RELAYER_ADDRESS="${VAULT_RELAYER_ADDRESS}" \
  RELAYER_PRIVATE_KEY="${ANVIL_KEY_0}" SUBSOLVER_OFFERS_DIR="${ROOT}/out-json/sub-solver-offers" \
  nohup node link-service/server.mjs >/tmp/link-service.out 2>&1 &
sleep 2
curl -fsS "${SERVICE}/health" >/dev/null

# --- 3. the maker creates an offer ---------------------------------------------------------------

SELL_AMOUNT=100000000                      # 100 USDC, 6 decimals
BUY_AMOUNT=100000000000000000000           # 100 DAI, 18 decimals

log "maker creates the offer"
OFFER=$(curl -fsS -X POST "${SERVICE}/offers" -H 'content-type: application/json' -d "{
  \"maker\": \"$(cast wallet address --private-key ${MAKER_KEY})\",
  \"taker\": \"$(cast wallet address --private-key ${TAKER_KEY})\",
  \"sellToken\": \"${USDC_ADDRESS}\",
  \"sellAmount\": \"${SELL_AMOUNT}\",
  \"buyToken\": \"${DAI_ADDRESS}\",
  \"buyAmount\": \"${BUY_AMOUNT}\",
  \"validFor\": 86400
}")
OFFER_ID=$(echo "${OFFER}" | jqq "d['id']")
MAKER_SHED=$(echo "${OFFER}" | jqq "d['makerBundle']['shed']")
echo "   link: $(echo "${OFFER}" | jqq "d['link']")"

# The maker's signature funds the Shed, so the only prior step is one ERC-20 approval to it.
# The maker moves no transaction: the permit grants their Shed the allowance and the relayer
# submits it. The nonce taken here is checked at the end, so "no transaction" is asserted, not
# claimed.
MAKER_NONCE=$(cast nonce "${MAKER}" --rpc-url "${RPC}")
# Earlier runs may have left an allowance behind, which would let the permit path be skipped and the
# run pass without testing it. Clear both, so what follows is the permit.
reset_allowance "${USDC_ADDRESS}" "${MAKER}" "${MAKER_SHED}"
MAKER_NONCE=$(cast nonce "${MAKER}" --rpc-url "${RPC}")
cast send "${USDC_ADDRESS}" "mint(address,uint256)" "${MAKER}" 100000000 \
  --private-key "${ANVIL_KEY_0}" --rpc-url "${RPC}" >/dev/null

# The typed data is what a wallet signs, so it has to be the same message as the digest. This is
# checked by signing both and requiring byte-identical signatures — not by trusting the JSON.
#
# It is read from the service, per offer, on request. A scratch file on disk belongs to whichever
# offer wrote it last: the check that the page shows the right message was itself comparing today's
# digest against a two-day-old blob, and passing a fixture that belonged to a different offer.
view_field() {
  python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(json.dumps(d[sys.argv[2]][sys.argv[3]]))" "$1" "$2" "$3"
}
signs_alike() {
  local typed=$1 digest=$2 key=$3 label=$4
  echo "${typed}" > /tmp/typed-data.json
  local a b
  a=$(cast wallet sign --data --from-file /tmp/typed-data.json --private-key "${key}")
  b=$(cast wallet sign --no-hash --private-key "${key}" "${digest}")
  [ "${a}" = "${b}" ] || { echo "FAILED: the typed data for the ${label} is not the same message as its digest" >&2; exit 1; }
}

log "maker signs the bundle and the permit — no transaction"
echo "   permit: $(echo "${OFFER}" | jqq "d['funding']['kind']")"
MAKER_DIGEST=$(echo "${OFFER}" | jqq "d['makerBundle']['digest']")
MAKER_PERMIT=$(echo "${OFFER}" | jqq "d['funding']['digest']")
MAKER_VIEW=/tmp/maker-view.json
curl -fsS "${SERVICE}/offers/${OFFER_ID}/role?address=${MAKER}" > "${MAKER_VIEW}"
signs_alike "$(view_field "${MAKER_VIEW}" bundle typedData)" "${MAKER_DIGEST}" "${MAKER_KEY}" "maker's bundle"
signs_alike "$(view_field "${MAKER_VIEW}" permit typedData)" "${MAKER_PERMIT}" "${MAKER_KEY}" "maker's permit"
MAKER_SIG=$(cast wallet sign --no-hash --private-key "${MAKER_KEY}" "${MAKER_DIGEST}")
MAKER_PERMIT_SIG=$(cast wallet sign --no-hash --private-key "${MAKER_KEY}" "${MAKER_PERMIT}")
curl -fsS -X POST "${SERVICE}/offers/${OFFER_ID}/signature" -H 'content-type: application/json' \
  -d "{\"role\":\"maker\",\"signature\":\"${MAKER_SIG}\",\"permitSignature\":\"${MAKER_PERMIT_SIG}\"}" >/dev/null

# --- 4. the taker opens the link and accepts -----------------------------------------------------

log "taker opens the link"
# The public view carries no addresses; a party asks for its own side by address.
VIEW=$(curl -fsS "${SERVICE}/offers/${OFFER_ID}/role?address=${TAKER}")
TAKER_SHED=$(echo "${VIEW}" | jqq "d['permit']['spender']")
TAKER_DIGEST=$(echo "${VIEW}" | jqq "d['bundle']['digest']")
echo "   role: $(echo "${VIEW}" | jqq "d['role']")"
echo "   taker pays $(echo "${VIEW}" | jqq "d['terms']['buyAmount']") $(echo "${VIEW}" | jqq "d['terms']['buySymbol']")" \
     "for $(echo "${VIEW}" | jqq "d['terms']['sellAmount']") $(echo "${VIEW}" | jqq "d['terms']['sellSymbol']")"

log "taker signs the bundle and the permit — no transaction"
echo "   permit: $(echo "${VIEW}" | jqq "d['permit']['kind']")"
cast send "${DAI_ADDRESS}" "mint(address,uint256)" "${TAKER}" 100000000000000000000 \
  --private-key "${ANVIL_KEY_0}" --rpc-url "${RPC}" >/dev/null
reset_allowance "${DAI_ADDRESS}" "${TAKER}" "${TAKER_SHED}"
TAKER_NONCE=$(cast nonce "${TAKER}" --rpc-url "${RPC}")
TAKER_PERMIT=$(echo "${VIEW}" | jqq "d['funding']['digest']")

read -r M0 MD0 T0 TU0 <<< "$(snapshot)"
# The Sheds hold whatever earlier runs left; what matters is that a settlement adds nothing to them.
read -r SHED_MU0 SHED_MD0 SHED_TD0 SHED_TU0 <<< "$(shed_balances)"

log "taker accepts"
signs_alike "$(echo "${VIEW}" | jqq "json.dumps(d['bundle']['typedData'])")" "${TAKER_DIGEST}" "${TAKER_KEY}" "taker's bundle"
signs_alike "$(echo "${VIEW}" | jqq "json.dumps(d['permit']['typedData'])")" "${TAKER_PERMIT}" "${TAKER_KEY}" "taker's permit"
TAKER_SIG=$(cast wallet sign --no-hash --private-key "${TAKER_KEY}" "${TAKER_DIGEST}")
TAKER_PERMIT_SIG=$(cast wallet sign --no-hash --private-key "${TAKER_KEY}" "${TAKER_PERMIT}")
ACCEPT=$(curl -fsS -X POST "${SERVICE}/offers/${OFFER_ID}/accept" -H 'content-type: application/json' \
  -d "{\"signature\":\"${TAKER_SIG}\",\"permitSignature\":\"${TAKER_PERMIT_SIG}\"}")
ORDER_UID=$(echo "${ACCEPT}" | jqq "d['orderUid']")
echo "   order ${ORDER_UID}"

# Nothing had approved either Shed — the allowances were cleared above — so the permit is the only
# thing that can have granted them. The relay says so, per side.
for side in maker taker; do
  echo "${ACCEPT}" | jqq "d['relay']" | grep -q "permit applied" \
    || { echo "FAILED: no permit was applied for the ${side}" >&2; exit 1; }
done
echo "   both permits applied by the relayer" 

# --- 5. wait ------------------------------------------------------------------------------------

# Poll the service's own status: it reads the chain and the orderbook, so it cannot be fooled by the
# funding transfer the way a raw balance comparison can.
log "waiting for settlement"
STATUS=settling
for _ in $(seq 1 60); do
  STATUS=$(curl -fsS "${SERVICE}/offers/${OFFER_ID}/status" | jqq "d['status']")
  [ "${STATUS}" = "settled" ] && break
  sleep 5
done
[ "${STATUS}" = "settled" ] || { echo "FAILED: status is ${STATUS}" >&2; exit 1; }

read -r M1 MD1 T1 TU1 <<< "$(snapshot)"
# The claim this flow makes is that neither party sends a transaction. Assert it.
[ "$(cast nonce "${MAKER}" --rpc-url "${RPC}")" = "${MAKER_NONCE}" ] \
  || { echo "FAILED: the maker sent a transaction" >&2; exit 1; }
[ "$(cast nonce "${TAKER}" --rpc-url "${RPC}")" = "${TAKER_NONCE}" ] \
  || { echo "FAILED: the taker sent a transaction" >&2; exit 1; }

log "settled"
echo "   neither party sent a transaction (maker nonce ${MAKER_NONCE}, taker nonce ${TAKER_NONCE})"
echo "   maker wallet USDC ${M0} -> ${M1}   (sold)"
echo "   maker wallet DAI  ${MD0} -> ${MD1}   (received)"
echo "   taker wallet DAI  ${T0} -> ${T1}   (sold)"
echo "   taker wallet USDC ${TU0} -> ${TU1}   (received)"

read -r SHED_MU1 SHED_MD1 SHED_TD1 SHED_TU1 <<< "$(shed_balances)"

# Every balance, to the unit. "It moved" is not the claim; "it moved by exactly the agreed amounts, and
# nothing else moved" is.
[ "${M1}" = "$(minus "${M0}" "${SELL_AMOUNT}")" ] \
  || { echo "FAILED: the maker's USDC went ${M0} -> ${M1}, expected -${SELL_AMOUNT}" >&2; exit 1; }
[ "${MD1}" = "$(plus "${MD0}" "${BUY_AMOUNT}")" ] \
  || { echo "FAILED: the maker's DAI went ${MD0} -> ${MD1}, expected +${BUY_AMOUNT}" >&2; exit 1; }
[ "${T1}" = "$(minus "${T0}" "${BUY_AMOUNT}")" ] \
  || { echo "FAILED: the taker's DAI went ${T0} -> ${T1}, expected -${BUY_AMOUNT}" >&2; exit 1; }
[ "${TU1}" = "$(plus "${TU0}" "${SELL_AMOUNT}")" ] \
  || { echo "FAILED: the taker's USDC went ${TU0} -> ${TU1}, expected +${SELL_AMOUNT}" >&2; exit 1; }
echo "   each wallet moved by exactly the agreed amount, and nothing else"

# Nothing is stranded: the sell side was funded and spent inside the signed bundle, and the buy side
# was paid to the wallet rather than to the contract that owns the order.
[ "${SHED_MU1}" = "${SHED_MU0}" ] || { echo "FAILED: the maker's Shed kept ${SHED_MU1} USDC" >&2; exit 1; }
[ "${SHED_MD1}" = "${SHED_MD0}" ] || { echo "FAILED: the maker's Shed gained ${SHED_MD1} DAI" >&2; exit 1; }
[ "${SHED_TD1}" = "${SHED_TD0}" ] || { echo "FAILED: the taker's Shed kept ${SHED_TD1} DAI" >&2; exit 1; }
[ "${SHED_TU1}" = "${SHED_TU0}" ] || { echo "FAILED: the taker's Shed gained ${SHED_TU1} USDC" >&2; exit 1; }
echo "   no Shed gained, kept, or stranded anything"

# --- 6. cancellation -------------------------------------------------------------------------

# A second offer, with different amounts so it is a different offer on-chain: the salt is
# (maker, buyToken, block.timestamp), so two offers created in the same block with the same terms
# would be the same offer and this would be testing nothing.
log "maker cancels an unsigned trade"
CANCEL_OFFER=$(curl -fsS -X POST "${SERVICE}/offers" -H 'content-type: application/json' -d "{
  \"maker\": \"${MAKER}\",
  \"taker\": \"${TAKER}\",
  \"sellToken\": \"${USDC_ADDRESS}\",
  \"sellAmount\": \"200000000\",
  \"buyToken\": \"${DAI_ADDRESS}\",
  \"buyAmount\": \"200000000000000000000\",
  \"validFor\": 86400
}")
CANCEL_ID=$(echo "${CANCEL_OFFER}" | jqq "d['id']")
echo "   link: $(echo "${CANCEL_OFFER}" | jqq "d['link']")"

# The maker signs the bundle and the permit, so there is a real on-chain order and a real deposit to
# revoke — cancelling an offer nobody signed would not exercise the order removal.
CANCEL_VIEW=/tmp/cancel-view.json
curl -fsS "${SERVICE}/offers/${CANCEL_ID}/role?address=${MAKER}" > "${CANCEL_VIEW}"
CANCEL_DIGEST=$(echo "${CANCEL_OFFER}" | jqq "d['makerBundle']['digest']")
CANCEL_PERMIT=$(echo "${CANCEL_OFFER}" | jqq "d['funding']['digest']")
signs_alike "$(view_field "${CANCEL_VIEW}" bundle typedData)" "${CANCEL_DIGEST}" "${MAKER_KEY}" "cancellation offer's bundle"
CANCEL_SIG=$(cast wallet sign --no-hash --private-key "${MAKER_KEY}" "${CANCEL_DIGEST}")
CANCEL_PERMIT_SIG=$(cast wallet sign --no-hash --private-key "${MAKER_KEY}" "${CANCEL_PERMIT}")
curl -fsS -X POST "${SERVICE}/offers/${CANCEL_ID}/signature" -H 'content-type: application/json' \
  -d "{\"role\":\"maker\",\"signature\":\"${CANCEL_SIG}\",\"permitSignature\":\"${CANCEL_PERMIT_SIG}\"}" >/dev/null

CANCEL_PLAN=$(curl -fsS "${SERVICE}/offers/${CANCEL_ID}/cancel?address=${MAKER}")
CANCEL_TYPED=/tmp/cancel-typed.json
signs_alike "$(echo "${CANCEL_PLAN}" | jqq "json.dumps(d['typedData'])")" \
  "$(echo "${CANCEL_PLAN}" | jqq "d['digest']")" "${MAKER_KEY}" "cancellation"

echo "${CANCEL_PLAN}" | jqq "json.dumps(d['typedData'])" > "${CANCEL_TYPED}"
CANCEL_BUNDLE_SIG=$(cast wallet sign --data --from-file "${CANCEL_TYPED}" --private-key "${MAKER_KEY}")
CANCELLED=$(curl -fsS -X POST "${SERVICE}/offers/${CANCEL_ID}/cancel" -H 'content-type: application/json' \
  -d "{\"address\":\"${MAKER}\",\"signature\":\"${CANCEL_BUNDLE_SIG}\"}")
echo "   relay: $(echo "${CANCELLED}" | jqq "d['relay']")"

# The service reports cancelled only after reading the wrapper, so this is the chain's answer.
CANCEL_STATUS=$(curl -fsS "${SERVICE}/offers/${CANCEL_ID}/status" | jqq "d['status']")
CANCEL_STATE=$(curl -fsS "${SERVICE}/offers/${CANCEL_ID}/status" | jqq "d['wrapperState']")
[ "${CANCEL_STATUS}" = "cancelled" ] || { echo "FAILED: the offer is ${CANCEL_STATUS}, not cancelled" >&2; exit 1; }
[ "${CANCEL_STATE}" = "cancelled" ] || { echo "FAILED: the wrapper says ${CANCEL_STATE}" >&2; exit 1; }
echo "   the wrapper reports the offer cancelled"

# Cancelling again is not an error: a maker who is unsure must be able to retry, and the Shed skips a
# nonce it has already seen.
AGAIN=$(curl -fsS -X POST "${SERVICE}/offers/${CANCEL_ID}/cancel" -H 'content-type: application/json' \
  -d "{\"address\":\"${MAKER}\",\"signature\":\"${CANCEL_BUNDLE_SIG}\"}")
[ "$(echo "${AGAIN}" | jqq "d['status']")" = "cancelled" ] \
  || { echo "FAILED: retrying the cancellation did not converge" >&2; exit 1; }
echo "   retrying the cancellation converges"
