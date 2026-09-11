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

# The four balances that move when the pair settles: the two sell tokens, and the two received
# tokens. Printed as one line so a caller can read them into variables.
snapshot() {
  printf '%s %s %s %s\n' \
    "$(cast call "${USDC_ADDRESS}" "balanceOf(address)(uint256)" "${MAKER_SHED}" --rpc-url "${RPC}" | awk '{print $1}')" \
    "$(cast call "${DAI_ADDRESS}" "balanceOf(address)(uint256)" "${MAKER_SHED}" --rpc-url "${RPC}" | awk '{print $1}')" \
    "$(cast call "${DAI_ADDRESS}" "balanceOf(address)(uint256)" "${TAKER_SHED}" --rpc-url "${RPC}" | awk '{print $1}')" \
    "$(cast call "${USDC_ADDRESS}" "balanceOf(address)(uint256)" "${TAKER_SHED}" --rpc-url "${RPC}" | awk '{print $1}')"
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

log "starting the sub-solver"
pkill -f private-trade-solver 2>/dev/null || true
rm -rf out-json/sub-solver-offers; mkdir -p out-json/sub-solver-offers
OFFERS_DIR="${ROOT}/out-json/sub-solver-offers" SOLVE_LOG=/tmp/private-trade-solve.log \
  nohup node "${ROOT}/subsolver/private-trade-solver.mjs" >/tmp/subsolver.out 2>&1 &

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

log "maker creates the offer"
OFFER=$(curl -fsS -X POST "${SERVICE}/offers" -H 'content-type: application/json' -d "{
  \"maker\": \"$(cast wallet address --private-key ${MAKER_KEY})\",
  \"taker\": \"$(cast wallet address --private-key ${TAKER_KEY})\",
  \"sellToken\": \"${USDC_ADDRESS}\",
  \"sellAmount\": \"100000000\",
  \"buyToken\": \"${DAI_ADDRESS}\",
  \"buyAmount\": \"100000000000000000000\",
  \"validFor\": 86400
}")
OFFER_ID=$(echo "${OFFER}" | jqq "d['id']")
MAKER_SHED=$(echo "${OFFER}" | jqq "d['makerBundle']['shed']")
echo "   link: $(echo "${OFFER}" | jqq "d['link']")"

# The maker's signature funds the Shed, so the only prior step is one ERC-20 approval to it.
log "maker approves their Shed to move the sell tokens"
cast send "${USDC_ADDRESS}" "mint(address,uint256)" "${MAKER}" 100000000 \
  --private-key "${ANVIL_KEY_0}" --rpc-url "${RPC}" >/dev/null
cast send "${USDC_ADDRESS}" "approve(address,uint256)" "${MAKER_SHED}" 100000000 \
  --private-key "${MAKER_KEY}" --rpc-url "${RPC}" >/dev/null

log "maker signs"
MAKER_DIGEST=$(echo "${OFFER}" | jqq "d['makerBundle']['digest']")
MAKER_SIG=$(cast wallet sign --no-hash --private-key "${MAKER_KEY}" "${MAKER_DIGEST}")
curl -fsS -X POST "${SERVICE}/offers/${OFFER_ID}/signature" -H 'content-type: application/json' \
  -d "{\"role\":\"maker\",\"signature\":\"${MAKER_SIG}\"}" >/dev/null

# --- 4. the taker opens the link and accepts -----------------------------------------------------

log "taker opens the link"
VIEW=$(curl -fsS "${SERVICE}/offers/${OFFER_ID}")
TAKER_SHED=$(echo "${VIEW}" | jqq "d['takerBundle']['shed']")
TAKER_DIGEST=$(echo "${VIEW}" | jqq "d['takerBundle']['digest']")
echo "   taker pays $(echo "${VIEW}" | jqq "d['terms']['sellAmount']") for $(echo "${VIEW}" | jqq "d['terms']['buyAmount']")"

log "taker approves their Shed to move the sell tokens"
cast send "${DAI_ADDRESS}" "mint(address,uint256)" "${TAKER}" 100000000000000000000 \
  --private-key "${ANVIL_KEY_0}" --rpc-url "${RPC}" >/dev/null
cast send "${DAI_ADDRESS}" "approve(address,uint256)" "${TAKER_SHED}" 100000000000000000000 \
  --private-key "${TAKER_KEY}" --rpc-url "${RPC}" >/dev/null

read -r M0 MD0 T0 TU0 <<< "$(snapshot)"

log "taker accepts"
TAKER_SIG=$(cast wallet sign --no-hash --private-key "${TAKER_KEY}" "${TAKER_DIGEST}")
ACCEPT=$(curl -fsS -X POST "${SERVICE}/offers/${OFFER_ID}/accept" -H 'content-type: application/json' \
  -d "{\"signature\":\"${TAKER_SIG}\"}")
ORDER_UID=$(echo "${ACCEPT}" | jqq "d['orderUid']")
echo "   order ${ORDER_UID}"

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
log "settled"
echo "   maker shed USDC ${M0} -> ${M1}   (sold)"
echo "   maker shed DAI  ${MD0} -> ${MD1}   (received)"
echo "   taker shed DAI  ${T0} -> ${T1}   (sold)"
echo "   taker shed USDC ${TU0} -> ${TU1}   (received)"
