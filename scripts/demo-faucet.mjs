#!/usr/bin/env node
// A faucet for the demo stack: give an address the tokens this fork funds trades with.
//
// A visitor arrives holding nothing on this chain. Their wallet is real and their signature works, but
// the permit they sign has no balance behind it, so the relay's transfer reverts and the trade dies at
// the first step with a message about allowance. This hands them the two demo tokens so the flow is
// something they can drive themselves.
//
// The tokens on this fork are the real mainnet contracts, so there is no `mint` to call. What works —
// and what the end-to-end scripts already do on this stack — is to impersonate one of the pre-funded
// anvil accounts and send from it. No storage slots, no whale addresses, nothing to keep in step with
// the fork.
//
//   RPC=http://localhost:8545 DAI=0x… USDC=0x… node scripts/demo-faucet.mjs
//
// Env:
//   RPC        chain to fund on            (default http://localhost:8545)
//   DAI, USDC  token addresses             (no defaults: a wrong address is worse than a refusal)
//   PORT       listen port                 (default 9300)
//   AMOUNT_DAI, AMOUNT_USDC                (defaults 10000 whole tokens)
//   FUNDER_KEY private key of a funded account (default: anvil account #0)

import http from 'node:http';
import { execFileSync } from 'node:child_process';

const RPC = process.env.RPC ?? 'http://localhost:8545';
const PORT = Number(process.env.PORT ?? 9300);
const FUNDER_KEY = process.env.FUNDER_KEY ?? '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';

const TOKENS = [
  { name: 'DAI', symbol: 'DAI', address: process.env.DAI, decimals: 18, amount: process.env.AMOUNT_DAI ?? '10000' },
  { name: 'USDC', symbol: 'USDC', address: process.env.USDC, decimals: 6, amount: process.env.AMOUNT_USDC ?? '10000' },
];

/// `cast` is the tool this repository already uses for every chain call, so the faucet does not add a
/// dependency to run. The two helpers are separate because `--rpc-url` is only accepted by the calls
/// that reach a chain — passing it to `cast wallet address` is a usage error, not a no-op.
const cast = (args) => execFileSync('cast', [...args, '--rpc-url', RPC], { encoding: 'utf8' }).trim();
const castLocal = (args) => execFileSync('cast', args, { encoding: 'utf8' }).trim();

let funder;
try {
  funder = castLocal(['wallet', 'address', '--private-key', FUNDER_KEY]);
} catch (err) {
  console.error(`cannot derive the funding account: ${err.message}`);
  process.exit(1);
}

const whole = (amount, decimals) => (BigInt(amount) * 10n ** BigInt(decimals)).toString();

function fund(address) {
  const results = [];
  // Impersonation makes the transfer possible; `--unlocked` is what lets `cast` send without the key.
  cast(['rpc', 'anvil_impersonateAccount', funder]);
  try {
    for (const token of TOKENS) {
      if (!token.address) {
        results.push({ symbol: token.symbol, sent: false, error: 'no address configured for this token' });
        continue;
      }
      try {
        const before = BigInt(cast(['call', token.address, 'balanceOf(address)(uint256)', address]).split(' ')[0]);
        cast([
          'send', token.address, 'transfer(address,uint256)', address, whole(token.amount, token.decimals),
          '--from', funder, '--unlocked',
        ]);
        const after = BigInt(cast(['call', token.address, 'balanceOf(address)(uint256)', address]).split(' ')[0]);
        results.push({ symbol: token.symbol, sent: after > before, balance: after.toString() });
      } catch (err) {
        results.push({ symbol: token.symbol, sent: false, error: String(err.stderr ?? err.message).slice(0, 200) });
      }
    }
  } finally {
    cast(['rpc', 'anvil_stopImpersonatingAccount', funder]);
  }
  return results;
}

const isAddress = (value) => /^0x[0-9a-fA-F]{40}$/.test(value);

/// A form, because the audience is not going to call the API with curl.
function page(body = '') {
  return `<!doctype html><meta charset="utf-8"><title>Demo tokens</title>
<style>
  body { background:#121212; color:#eee; font:16px/1.5 ui-sans-serif,system-ui; max-width:34rem; margin:4rem auto; padding:0 1rem }
  input,button { font:inherit; padding:.5rem .75rem; border-radius:.4rem; border:1px solid #444; background:#1e1e1e; color:#eee }
  input { width: 100%; box-sizing: border-box }
  .ok { color:#7ee787 } .bad { color:#ff7b72 } .muted { color:#999; font-size:.9rem }
  code { background:#1e1e1e; padding:.1rem .3rem; border-radius:.25rem }
</style>
<h1>Demo tokens</h1>
<p>This page funds an address on the <strong>demo chain only</strong>. The tokens are worthless, the
chain is a local fork, and none of this touches mainnet.</p>
<form method="get"><input name="address" placeholder="0x… your wallet address" value="${body.match?.(/0x[0-9a-fA-F]{40}/)?.[0] ?? ''}"><p><button>Send me demo tokens</button></p></form>
${body}`;
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const address = url.searchParams.get('address') ?? '';

  if (!address) {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }).end(page());
    return;
  }
  if (!isAddress(address)) {
    res.writeHead(400, { 'content-type': 'text/html; charset=utf-8' }).end(page('<p class="bad">That is not an address.</p>'));
    return;
  }

  let results;
  try {
    results = fund(address);
  } catch (err) {
    res.writeHead(500, { 'content-type': 'text/html; charset=utf-8' }).end(page(`<p class="bad">Could not fund: ${String(err.message).slice(0, 300)}</p>`));
    return;
  }

  const rows = results
    .map((r) => (r.sent
      ? `<li class="ok">${r.symbol} sent — balance now ${r.balance}</li>`
      : `<li class="bad">${r.symbol} not sent — ${r.error}</li>`))
    .join('');
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }).end(page(
    `<p>Funded <code>${address}</code>:</p><ul>${rows}</ul>` +
    '<p class="muted">Open the trade link again. You can now fund your Shed; you still pay no gas.</p>',
  ));
});

TOKENS.forEach((t) => {
  if (!t.address) console.error(`note: ${t.symbol} has no address, it will be skipped`);
});
server.listen(PORT, '0.0.0.0', () => {
  console.log(`demo faucet on ${PORT}, funding from ${funder}, tokens: ${TOKENS.filter((t) => t.address).map((t) => t.symbol).join(', ')}`);
});
