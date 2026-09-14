#!/usr/bin/env bash
# Leaves the stack ready for a real wallet extension, and starts nothing else.
#
# This is the manual counterpart to `scripts/app-e2e.sh`. That script drives the flow with the
# service's development wallet, so it can never answer the question this one is for: what does Rabby
# or MetaMask actually do with these prompts. Here the service starts *without* development keys, so
# the page offers no wallet of its own, and you drive it with the extension.
#
#   ./scripts/wallet-e2e.sh
#
# Reads MAKER and TAKER from the environment, defaulting to the offline stack's second and third
# anvil accounts. Those are the accounts to import into the wallet; see docs/WALLET.md.
set -euo pipefail

RPC="${RPC:-http://localhost:8545}"
ORDERBOOK="${ORDERBOOK_URL:-http://localhost:8080}"
SERVICE="${SERVICE_URL:-http://localhost:9200}"
OFFLINE_DIR="${OFFLINE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../offline-mode" && pwd)}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ANVIL_KEY_0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
DEFAULT_MAKER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
DEFAULT_TAKER=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
MAKER="${MAKER:-$DEFAULT_MAKER}"
TAKER="${TAKER:-$DEFAULT_TAKER}"

log() { printf '\n==> %s\n' "$*"; }

set -a; source "${OFFLINE_DIR}/.env"; set +a
cd "${ROOT}"

USDC_ADDRESS="${USDC_ADDRESS:-0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48}"
DAI_ADDRESS="${DAI_ADDRESS:-0x6B175474E89094C44Da98b954EedeAC495271d0F}"

log "checking the offline stack"
cast block-number --rpc-url "${RPC}" >/dev/null 2>&1 \
  || { echo "anvil is not answering at ${RPC}. See docs/OFFLINE.md." >&2; exit 1; }
curl -fsS -m 3 "${ORDERBOOK}/api/v1/version" >/dev/null \
  || { echo "the orderbook is not answering at ${ORDERBOOK}. See docs/OFFLINE.md." >&2; exit 1; }
echo "    chain at block $(cast block-number --rpc-url "${RPC}") (chain id $(cast chain-id --rpc-url "${RPC}"))"

log "deploying the private trade contracts"
DEPLOYER_PRIVATE_KEY="${ANVIL_KEY_0}" SETTLEMENT_CONTRACT_ADDRESS="${SETTLEMENT_CONTRACT_ADDRESS}" \
  forge script script/DeployPrivateTrade.s.sol --rpc-url "${RPC}" --broadcast -q >/dev/null
export PRIVATE_TRADE_WRAPPER=$(python3 -c "import json;print(json.load(open('out-json/private-trade-deployed.json'))['wrapper'])")
export PRIVATE_TRADE_HANDLER=$(python3 -c "import json;print(json.load(open('out-json/private-trade-deployed.json'))['handler'])")

log "allowlisting ${PRIVATE_TRADE_WRAPPER}"
MANAGER=$(cast call "${AUTHENTICATOR_ADDRESS}" "manager()(address)" --rpc-url "${RPC}")
cast rpc anvil_setBalance "${MANAGER}" 0x21e19e0c9bab2400000 --rpc-url "${RPC}" >/dev/null
cast rpc anvil_impersonateAccount "${MANAGER}" --rpc-url "${RPC}" >/dev/null
cast send "${AUTHENTICATOR_ADDRESS}" "addSolver(address)" "${PRIVATE_TRADE_WRAPPER}" \
  --from "${MANAGER}" --unlocked --rpc-url "${RPC}" >/dev/null
cast rpc anvil_stopImpersonatingAccount "${MANAGER}" --rpc-url "${RPC}" >/dev/null

# The sell token has to be in the party's own wallet: their signed bundle moves it into their Shed,
# and a wallet with no balance fails at `transferFrom` after both signatures are already collected.
log "funding the two wallets with what they are selling"
cast send "${USDC_ADDRESS}" "mint(address,uint256)" "${MAKER}" 1000000000 \
  --private-key "${ANVIL_KEY_0}" --rpc-url "${RPC}" >/dev/null
cast send "${DAI_ADDRESS}" "mint(address,uint256)" "${TAKER}" 1000000000000000000000 \
  --private-key "${ANVIL_KEY_0}" --rpc-url "${RPC}" >/dev/null
echo "    maker ${MAKER} holds $(cast call "${USDC_ADDRESS}" "balanceOf(address)(uint256)" "${MAKER}" --rpc-url "${RPC}" | awk '{print $1}') USDC (raw)"
echo "    taker ${TAKER} holds $(cast call "${DAI_ADDRESS}" "balanceOf(address)(uint256)" "${TAKER}" --rpc-url "${RPC}" | awk '{print $1}') DAI (raw)"

node "${ROOT}/scripts/check-page.mjs" || exit 1

log "starting the sub-solver"
pkill -f private-trade-solver 2>/dev/null || true
rm -rf out-json/sub-solver-offers; mkdir -p out-json/sub-solver-offers
OFFERS_DIR="${ROOT}/out-json/sub-solver-offers" nohup node "${ROOT}/subsolver/private-trade-solver.mjs" \
  >/tmp/subsolver.out 2>&1 &

log "starting the link service without development keys"
# No PRIVATE_TRADE_DEV_KEYS: the page must not offer a wallet of its own, or this is not a wallet test.
pkill -f "link-service/server.mjs" 2>/dev/null || true
sleep 1
rm -rf out-json/link
PRIVATE_TRADE_ROOT="${ROOT}" RPC="${RPC}" ORDERBOOK_URL="${ORDERBOOK}" \
  PRIVATE_TRADE_WRAPPER="${PRIVATE_TRADE_WRAPPER}" PRIVATE_TRADE_HANDLER="${PRIVATE_TRADE_HANDLER}" \
  COWSHED_COMPOSABLE_COW_FACTORY_ADDRESS="${COWSHED_COMPOSABLE_COW_FACTORY_ADDRESS}" \
  COMPOSABLE_COW_ADDRESS="${COMPOSABLE_COW_ADDRESS}" VAULT_RELAYER_ADDRESS="${VAULT_RELAYER_ADDRESS}" \
  DEFAULT_SELL_TOKEN="${USDC_ADDRESS}" DEFAULT_BUY_TOKEN="${DAI_ADDRESS}" \
  RELAYER_PRIVATE_KEY="${ANVIL_KEY_0}" SUBSOLVER_OFFERS_DIR="${ROOT}/out-json/sub-solver-offers" \
  nohup node link-service/server.mjs >/tmp/link-service.out 2>&1 &
sleep 2
curl -fsS "${SERVICE}/health" >/dev/null || { echo "the service did not start; see /tmp/link-service.out" >&2; exit 1; }

cat <<DONE

==> ready

   Make the offer here
     ${SERVICE}/

   Wallet
     network    Ethereum, RPC url ${RPC}, chain id 1
     maker      ${MAKER}   (signs first, gets the link)
     taker      ${TAKER}   (opens the link, signs second)

   Use
     100000000 USDC  ->  100000000000000000000 DAI
     sell amount "100000000", buy amount "100000000000000000000"

   Then watch it settle
     /tmp/link-service.out     what the service did
     /tmp/subsolver.out        what the sub-solver did

   Details and what to look for: docs/WALLET.md
DONE
