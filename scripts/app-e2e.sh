#!/usr/bin/env bash
# The whole private trade flow, driven through the app in a real browser.
#
# Sets up the stack the same way the link service's e2e does — deploy, allowlist, sub-solver, service —
# with two development wallets instead of real ones, then hands over to scripts/app-e2e.mjs, which
# clicks through both sides and checks what the pages show.
set -euo pipefail

RPC="${RPC:-http://localhost:8545}"
ORDERBOOK="${ORDERBOOK_URL:-http://localhost:8080}"
SERVICE="${SERVICE_URL:-http://localhost:9200}"
OFFLINE_DIR="${OFFLINE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../offline-mode" && pwd)}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ANVIL_KEY_0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
MAKER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
MAKER_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
TAKER=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
TAKER_KEY=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a

log() { printf '\n==> %s\n' "$*"; }

set -a; source "${OFFLINE_DIR}/.env"; set +a
cd "${ROOT}"

USDC_ADDRESS="${USDC_ADDRESS:-0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48}"
DAI_ADDRESS="${DAI_ADDRESS:-0x6B175474E89094C44Da98b954EedeAC495271d0F}"

# The deploy script's own variables, as the link service's e2e sets them.
: "${SETTLEMENT_CONTRACT_ADDRESS:?the offline stack must be up}"
export DEPLOYER_PRIVATE_KEY="${ANVIL_KEY_0}"
export SETTLEMENT_CONTRACT_ADDRESS

log "deploying the private trade contracts"
forge script script/DeployPrivateTrade.s.sol --rpc-url "${RPC}" --broadcast >/dev/null
PRIVATE_TRADE_WRAPPER=$(python3 -c "import json;print(json.load(open('out-json/private-trade-deployed.json'))['wrapper'])")
PRIVATE_TRADE_HANDLER=$(python3 -c "import json;print(json.load(open('out-json/private-trade-deployed.json'))['handler'])")
export PRIVATE_TRADE_WRAPPER PRIVATE_TRADE_HANDLER

log "allowlisting ${PRIVATE_TRADE_WRAPPER}"
# Add the wrapper as a solver: it is what calls `settle` on the pair's behalf, so it needs the seat.
MANAGER=$(cast call "${AUTHENTICATOR_ADDRESS}" "manager()(address)" --rpc-url "${RPC}")
cast rpc anvil_setBalance "${MANAGER}" 0x21e19e0c9bab2400000 --rpc-url "${RPC}" >/dev/null
cast rpc anvil_impersonateAccount "${MANAGER}" --rpc-url "${RPC}" >/dev/null
cast send "${AUTHENTICATOR_ADDRESS}" "addSolver(address)" "${PRIVATE_TRADE_WRAPPER}" \
  --from "${MANAGER}" --unlocked --rpc-url "${RPC}" >/dev/null
cast rpc anvil_stopImpersonatingAccount "${MANAGER}" --rpc-url "${RPC}" >/dev/null

# Both parties start with what they are selling and no allowance, so the permits are what grant it.
cast send "${USDC_ADDRESS}" "mint(address,uint256)" "${MAKER}" 1000000 \
  --private-key "${ANVIL_KEY_0}" --rpc-url "${RPC}" >/dev/null
cast send "${DAI_ADDRESS}" "mint(address,uint256)" "${TAKER}" 100000000000000000000 \
  --private-key "${ANVIL_KEY_0}" --rpc-url "${RPC}" >/dev/null

node "${ROOT}/scripts/check-page.mjs" || exit 1

log "starting the sub-solver"
pkill -f private-trade-solver 2>/dev/null || true
rm -rf out-json/sub-solver-offers; mkdir -p out-json/sub-solver-offers
OFFERS_DIR="${ROOT}/out-json/sub-solver-offers" nohup node "${ROOT}/subsolver/private-trade-solver.mjs" \
  >/tmp/subsolver.out 2>&1 &

log "starting the link service with two development wallets"
pkill -f "link-service/server.mjs" 2>/dev/null || true
sleep 1
PRIVATE_TRADE_DEV_KEYS="${MAKER}=${MAKER_KEY},${TAKER}=${TAKER_KEY}" \
  DEFAULT_SELL_TOKEN="${USDC_ADDRESS}" \
  DEFAULT_BUY_TOKEN="${DAI_ADDRESS}" \
  SUBSOLVER_OFFERS_DIR="${ROOT}/out-json/sub-solver-offers" \
  RELAYER_PRIVATE_KEY="${ANVIL_KEY_0}" \
  nohup node link-service/server.mjs >/tmp/link-service.out 2>&1 &
sleep 2
curl -fsS "${SERVICE}/health" >/dev/null || { echo "the service did not start" >&2; exit 1; }

APP_E2E_MAKER="${MAKER}" APP_E2E_TAKER="${TAKER}" \
  USDC_ADDRESS="${USDC_ADDRESS}" DAI_ADDRESS="${DAI_ADDRESS}" \
  SERVICE_URL="${SERVICE}" RPC="${RPC}" \
  node "${ROOT}/scripts/app-e2e.mjs"
