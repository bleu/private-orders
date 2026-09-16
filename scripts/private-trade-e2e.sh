#!/usr/bin/env bash
# End-to-end private trade through the CoW offline stack, using the JIT + fulfillment path.
#
#   ./scripts/private-trade-e2e.sh
#
# What it does, in order:
#   1. deploys the wrapper, handler and submitter
#   2. allowlists the wrapper (a manager action, so it needs impersonation)
#   3. funds both Sheds, relays both owner-signed hook bundles, writes the two payloads
#   4. starts the sub-solver on the private offer
#   5. posts the taker's order to the orderbook
#   6. waits for the settlement and checks the balances moved
#
# The maker's half never reaches the orderbook: the sub-solver injects it as a JIT trade, and the
# wrapper enforces the pair on-chain. See docs/JIT-PATH.md.
set -euo pipefail

RPC="${RPC:-http://localhost:8545}"
ORDERBOOK="${ORDERBOOK_URL:-http://localhost:8080}"
SUBSOLVER_PORT="${SUBSOLVER_PORT:-9100}"
OFFLINE_DIR="${OFFLINE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../offline-mode" && pwd)}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ANVIL_KEY_0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ANVIL_KEY_1=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
ANVIL_KEY_2=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a

log() { printf '\n==> %s\n' "$*"; }

# --- 0. environment -----------------------------------------------------------------------------

log "reading deployment addresses from the offline stack"
set -a; source "${OFFLINE_DIR}/.env"; set +a
export DEPLOYER_PRIVATE_KEY="${ANVIL_KEY_0}"
export MAKER_PRIVATE_KEY="${ANVIL_KEY_1}"
export TAKER_PRIVATE_KEY="${ANVIL_KEY_2}"
export PRIVATE_TRADE_USDC_AMOUNT="${PRIVATE_TRADE_USDC_AMOUNT:-100000000}"
export PRIVATE_TRADE_DAI_AMOUNT="${PRIVATE_TRADE_DAI_AMOUNT:-100000000000000000000}"
export PRIVATE_TRADE_VALID_FOR="${PRIVATE_TRADE_VALID_FOR:-86400}"

cd "${ROOT}"

# --- 1. deploy ----------------------------------------------------------------------------------

log "deploying wrapper, handler and submitter"
forge script script/DeployPrivateTrade.s.sol --rpc-url "${RPC}" --broadcast -q >/dev/null
WRAPPER=$(python3 -c "import json;print(json.load(open('out-json/private-trade-deployed.json'))['wrapper'])")
HANDLER=$(python3 -c "import json;print(json.load(open('out-json/private-trade-deployed.json'))['handler'])")
export PRIVATE_TRADE_WRAPPER="${WRAPPER}"
export PRIVATE_TRADE_HANDLER="${HANDLER}"

# --- 2. allowlist -------------------------------------------------------------------------------

log "allowlisting the wrapper as a solver"
MANAGER=$(cast call "${AUTHENTICATOR_ADDRESS}" "manager()(address)" --rpc-url "${RPC}")
cast rpc anvil_setBalance "${MANAGER}" 0x21e19e0c9bab2400000 --rpc-url "${RPC}" >/dev/null
cast rpc anvil_impersonateAccount "${MANAGER}" --rpc-url "${RPC}" >/dev/null
cast send "${AUTHENTICATOR_ADDRESS}" "addSolver(address)" "${WRAPPER}" \
  --from "${MANAGER}" --unlocked --rpc-url "${RPC}" >/dev/null
cast rpc anvil_stopImpersonatingAccount "${MANAGER}" --rpc-url "${RPC}" >/dev/null
[ "$(cast call "${AUTHENTICATOR_ADDRESS}" "isSolver(address)(bool)" "${WRAPPER}" --rpc-url "${RPC}")" = "true" ]

# --- 3. prepare ---------------------------------------------------------------------------------

log "funding the Sheds, relaying both bundles, building the payloads"
forge script script/PreparePrivateTrade.s.sol --rpc-url "${RPC}" --broadcast -q >/dev/null
TAKER_SHED=$(python3 -c "import json;print(json.load(open('out-json/private-trade-offer.json'))['taker'])")

# --- 4. sub-solver ------------------------------------------------------------------------------

log "starting the sub-solver on ${SUBSOLVER_PORT}"
pkill -f private-trade-solver 2>/dev/null || true
rm -f /tmp/private-trade-solve.log
OFFER_FILE="${ROOT}/out-json/private-trade-offer.json" SOLVE_LOG=/tmp/private-trade-solve.log \
  PORT="${SUBSOLVER_PORT}" nohup node "${ROOT}/subsolver/private-trade-solver.mjs" >/tmp/subsolver.out 2>&1 &
sleep 2
curl -fsS "http://localhost:${SUBSOLVER_PORT}/" >/dev/null

# --- 5. post the taker's order ------------------------------------------------------------------

MAKER_SHED=$(python3 -c "import json;print(json.load(open('out-json/private-trade-offer.json'))['makerJitOrder']['signature'][2:42])")
MAKER_SHED=0x${MAKER_SHED}
DAI_BEFORE=$(cast call "${DAI_ADDRESS}" "balanceOf(address)(uint256)" "${TAKER_SHED}" --rpc-url "${RPC}" | awk '{print $1}')
USDC_BEFORE=$(cast call "${USDC_ADDRESS}" "balanceOf(address)(uint256)" "${MAKER_SHED}" --rpc-url "${RPC}" | awk '{print $1}')
echo "   taker DAI before: ${DAI_BEFORE}"
echo "   maker USDC before: ${USDC_BEFORE}"

log "posting the taker's order"
ORDER_UID=$(curl -fsS -X POST "${ORDERBOOK}/api/v1/orders" \
  -H 'content-type: application/json' --data-binary @out-json/private-trade-order.json | tr -d '"')
echo "   ${ORDER_UID}"

# --- 6. wait for settlement ---------------------------------------------------------------------

log "waiting for the settlement"
DAI_AFTER="${DAI_BEFORE}"
for _ in $(seq 1 60); do
  DAI_AFTER=$(cast call "${DAI_ADDRESS}" "balanceOf(address)(uint256)" "${TAKER_SHED}" --rpc-url "${RPC}" | awk '{print $1}')
  if [ "${DAI_AFTER}" != "${DAI_BEFORE}" ]; then break; fi
  sleep 5
done

if [ "${DAI_AFTER}" = "${DAI_BEFORE}" ]; then
  echo "FAILED: the taker's DAI did not move (${DAI_BEFORE})" >&2
  exit 1
fi

USDC_AFTER=$(cast call "${USDC_ADDRESS}" "balanceOf(address)(uint256)" "${MAKER_SHED}" --rpc-url "${RPC}" | awk '{print $1}')
log "settled"
echo "   taker shed ${TAKER_SHED} (0x2a0d702a…)"
echo "     DAI  ${DAI_BEFORE} -> ${DAI_AFTER}"
echo "   maker shed ${MAKER_SHED}"
echo "     USDC ${USDC_BEFORE} -> ${USDC_AFTER}"
