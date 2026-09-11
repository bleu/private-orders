#!/usr/bin/env node
// Private trade link service.
//
// Turns an agreed trade into a shareable link and drives it to settlement:
//
//   POST /offers              the maker describes the trade, gets a link and a digest to sign
//   GET  /offers/:id          the link target: terms, plus the digest the taker must sign
//   POST /offers/:id/signature  either party submits its signature
//   POST /offers/:id/accept   the taker accepts; the service relays both bundles and posts the order
//   GET  /offers/:id/status   open / settling / settled, with the settlement transaction
//   GET  /o/:id               a page rendering the link for a human
//
// Two deliberate properties:
//
//   * The service holds no keys that can move value. It relays owner-signed hook bundles, which
//     anyone may do, and posts an order whose signature is an ERC-1271 payload, not a secret. The
//     only signatures it collects are the two parties'.
//   * It never re-derives the trade. `script/LinkCompute.s.sol` is `PrivateTradeBuilder`, so the
//     service cannot drift from the on-chain rules; it just moves JSON and calls `cast`/`forge`.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const PORT = Number(process.env.PORT ?? 9200);
const ROOT = process.env.PRIVATE_TRADE_ROOT ?? path.resolve(import.meta.dirname, '..');
const RPC = process.env.RPC ?? 'http://localhost:8545';
const ORDERBOOK = process.env.ORDERBOOK_URL ?? 'http://localhost:8080';
const STORE = path.join(ROOT, 'out-json', 'link');
// Where the sub-solver looks for private offers. One file per live offer.
const OFFERS_DIR = process.env.SUBSOLVER_OFFERS_DIR ?? path.join(ROOT, 'out-json', 'sub-solver-offers');
const PUBLIC_URL = process.env.PUBLIC_URL ?? `http://localhost:${PORT}`;

const CONFIG = {
  wrapper: process.env.PRIVATE_TRADE_WRAPPER,
  handler: process.env.PRIVATE_TRADE_HANDLER,
  shedFactory: process.env.COWSHED_COMPOSABLE_COW_FACTORY_ADDRESS,
  composableCoW: process.env.COMPOSABLE_COW_ADDRESS,
  vaultRelayer: process.env.VAULT_RELAYER_ADDRESS,
  relayerKey: process.env.RELAYER_PRIVATE_KEY,
};

fs.mkdirSync(STORE, { recursive: true });
fs.mkdirSync(OFFERS_DIR, { recursive: true });

const json = (res, status, body) => {
  const payload = JSON.stringify(body, null, 2);
  res.writeHead(status, { 'content-type': 'application/json' }).end(payload);
};

const readBody = (req) =>
  new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', (chunk) => {
      raw += chunk;
      if (raw.length > 1e6) reject(new Error('body too large'));
    });
    req.on('end', () => {
      try {
        resolve(raw ? JSON.parse(raw) : {});
      } catch (err) {
        reject(new Error(`invalid json: ${err.message}`));
      }
    });
  });

const offerPath = (id) => path.join(STORE, `${id}.json`);
const loadOffer = (id) => (fs.existsSync(offerPath(id)) ? JSON.parse(fs.readFileSync(offerPath(id), 'utf8')) : null);
const saveOffer = (offer) => fs.writeFileSync(offerPath(offer.id), JSON.stringify(offer, null, 2));

function forge(args) {
  return execFileSync('forge', args, { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
}

function cast(args) {
  return execFileSync('cast', args, { cwd: ROOT, encoding: 'utf8' }).trim();
}

/// Ask the Solidity builder to derive the whole payload. No private key, no transaction.
function compute(request) {
  fs.writeFileSync(path.join(ROOT, 'out-json', 'link-request.json'), JSON.stringify(request, null, 2));
  forge(['script', 'script/LinkCompute.s.sol', '--rpc-url', RPC, '-q']);
  return JSON.parse(fs.readFileSync(path.join(ROOT, 'out-json', 'link-computed.json'), 'utf8'));
}

/// Relay both owner-signed bundles. Permissionless, and safe to retry.
function relay(computed, makerSignature, takerSignature) {
  fs.writeFileSync(
    path.join(ROOT, 'out-json', 'link-signatures.json'),
    JSON.stringify({ maker: makerSignature, taker: takerSignature }, null, 2),
  );
  execFileSync(
    'forge',
    ['script', 'script/LinkRelay.s.sol', '--rpc-url', RPC, '--broadcast', '-q'],
    { cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, RELAYER_PRIVATE_KEY: CONFIG.relayerKey } },
  );
}

async function postOrder(order) {
  const res = await fetch(`${ORDERBOOK}/api/v1/orders`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(order),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`orderbook rejected the order (${res.status}): ${text}`);
  return text.replace(/"/g, '');
}

async function orderStatus(uid) {
  try {
    const res = await fetch(`${ORDERBOOK}/api/v1/orders/${uid}`);
    if (!res.ok) return { status: 'unknown' };
    return await res.json();
  } catch {
    return { status: 'unknown' };
  }
}

const balanceOf = (token, holder) =>
  cast(['call', token, 'balanceOf(address)(uint256)', holder, '--rpc-url', RPC]).split(' ')[0];

/// The offer's progress, derived from the chain rather than from the service's own bookkeeping.
async function status(offer) {
  if (!offer.orderUid) return { status: offer.makerSigned && offer.takerSigned ? 'signed' : 'open' };

  const current = balanceOf(offer.computed.sellToken, offer.computed.makerShed);
  const baseline = BigInt(offer.makerBalanceAtAccept ?? current);
  if (BigInt(current) < baseline) {
    return { status: 'settled', orderUid: offer.orderUid, settlementTx: offer.settlementTx ?? null };
  }
  const order = await orderStatus(offer.orderUid);
  return { status: order.status === 'fulfilled' ? 'settled' : 'settling', orderUid: offer.orderUid };
}

/// What a party must do before signing. The bundle funds the Shed itself, so the only prior step is
/// one ERC-20 approval to the Shed. A separate transfer would cost a second transaction and leave a
/// window where the order is authorised but unfunded.
const funding = (computed, role) =>
  computed.fund === false
    ? {
        note: 'send the sell tokens to your Shed, then sign',
        token: computed[role === 'maker' ? 'sellToken' : 'buyToken'],
        to: role === 'maker' ? computed.makerShed : computed.takerBundle.shed,
        amount: computed[role === 'maker' ? 'sellAmount' : 'buyAmount'],
      }
    : {
        note: 'approve your Shed once, then a single signature funds it and authorises the order',
        token: computed[role === 'maker' ? 'sellToken' : 'buyToken'],
        owner: role === 'maker' ? computed.maker : computed.takerBundle.owner,
        spender: role === 'maker' ? computed.makerShed : computed.takerBundle.shed,
        amount: computed[role === 'maker' ? 'sellAmount' : 'buyAmount'],
        doneBy: 'your signature; this is the only transaction you need before signing',
      };

const page = (offer, computed) => `<!doctype html>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Private trade</title>
<style>
 body{font:16px/1.5 system-ui,sans-serif;max-width:34rem;margin:3rem auto;padding:0 1rem;color:#111}
 h1{font-size:1.25rem;margin-bottom:.25rem} .muted{color:#666;font-size:.9rem}
 table{width:100%;border-collapse:collapse;margin:1.5rem 0}
 td{padding:.4rem 0;border-bottom:1px solid #eee} td:last-child{text-align:right;font-variant-numeric:tabular-nums}
 code{background:#f4f4f4;padding:.15rem .35rem;border-radius:4px;font-size:.85rem;word-break:break-all}
 .status{display:inline-block;padding:.15rem .5rem;border-radius:999px;background:#e8f5e9;color:#1b5e20;font-size:.8rem}
</style>
<h1>Private trade</h1>
<p class="muted">Link <code>${offer.id}</code> · <span class="status">${offer.status ?? 'open'}</span></p>
<table>
 <tr><td>You receive</td><td><b>${computed.buyAmount}</b> <code>${computed.buyToken}</code></td></tr>
 <tr><td>You pay</td><td><b>${computed.sellAmount}</b> <code>${computed.sellToken}</code></td></tr>
 <tr><td>Counterparty</td><td><code>${computed.makerShed}</code></td></tr>
 <tr><td>Expires</td><td>${new Date(Number(computed.validTo) * 1000).toISOString()}</td></tr>
</table>
<p class="muted">First approve your Shed to take <b>${computed.buyAmount}</b> <code>${computed.buyToken}</code>
 (<code>approve(${computed.takerBundle.shed}, ${computed.buyAmount})</code>). Then sign this digest with the
 wallet that owns your Shed, and <code>POST /offers/${offer.id}/accept</code> with
 <code>{"signature":"0x…"}</code> — the signature funds your Shed and authorises the order in one go.</p>
<p><code>${computed.takerBundle.digest}</code></p>`;

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, PUBLIC_URL);
    const parts = url.pathname.split('/').filter(Boolean);

    if (req.method === 'GET' && parts[0] === 'health') return json(res, 200, { ok: true });

    if (req.method === 'POST' && parts[0] === 'offers' && parts.length === 1) {
      const body = await readBody(req);
      // Explicitly enumerated: CONFIG also holds the relayer key, and this object is written to disk.
      const request = {
        maker: body.maker,
        taker: body.taker ?? '0x0000000000000000000000000000000000000000',
        sellToken: body.sellToken,
        sellAmount: String(body.sellAmount),
        buyToken: body.buyToken,
        buyAmount: String(body.buyAmount),
        validFor: String(body.validFor ?? 86400),
        wrapper: CONFIG.wrapper,
        handler: CONFIG.handler,
        shedFactory: CONFIG.shedFactory,
        composableCoW: CONFIG.composableCoW,
        vaultRelayer: CONFIG.vaultRelayer,
      };
      const computed = compute(request);
      const id = computed.offerId.slice(2, 12);

      const offer = { id, request, computed, createdAt: new Date().toISOString(), signatures: {} };
      saveOffer(offer);

      return json(res, 201, {
        id,
        link: `${PUBLIC_URL}/o/${id}`,
        funding: funding(computed, 'maker'),
        makerBundle: {
          shed: computed.makerBundle.shed,
          nonce: computed.makerBundle.nonce,
          deadline: computed.makerBundle.deadline,
          digest: computed.makerBundle.digest,
        },
      });
    }

    if (parts[0] === 'offers' && parts[1]) {
      const offer = loadOffer(parts[1]);
      if (!offer) return json(res, 404, { error: 'unknown offer' });

      if (req.method === 'GET' && parts.length === 2) {
        return json(res, 200, {
          id: offer.id,
          status: (await status(offer)).status,
          terms: {
            sellToken: offer.computed.sellToken,
            sellAmount: offer.computed.sellAmount,
            buyToken: offer.computed.buyToken,
            buyAmount: offer.computed.buyAmount,
            makerShed: offer.computed.makerShed,
            validTo: offer.computed.validTo,
          },
          takerBundle: {
            shed: offer.computed.takerBundle.shed,
            nonce: offer.computed.takerBundle.nonce,
            deadline: offer.computed.takerBundle.deadline,
            digest: offer.computed.takerBundle.digest,
          },
          funding: funding(offer.computed, 'taker'),
          orderUid: offer.orderUid ?? null,
        });
      }

      if (req.method === 'GET' && parts[2] === 'status') return json(res, 200, await status(offer));

      if (req.method === 'POST' && parts[2] === 'signature') {
        const body = await readBody(req);
        if (!['maker', 'taker'].includes(body.role)) return json(res, 400, { error: 'role must be maker or taker' });
        if (!/^0x[0-9a-fA-F]{130}$/.test(body.signature ?? '')) {
          return json(res, 400, { error: 'signature must be 65 bytes, r || s || v' });
        }
        offer.signatures[body.role] = body.signature;
        saveOffer(offer);
        return json(res, 200, { id: offer.id, signed: Object.keys(offer.signatures) });
      }

      if (req.method === 'POST' && parts[2] === 'accept') {
        const body = await readBody(req);
        if (offer.orderUid) return json(res, 409, { error: 'already accepted', orderUid: offer.orderUid });

        // An open offer binds to whoever accepts; a restricted one already knows its taker.
        const restricted = offer.request.taker !== '0x0000000000000000000000000000000000000000';
        if (restricted && body.taker && body.taker.toLowerCase() !== offer.request.taker.toLowerCase()) {
          return json(res, 403, { error: 'this offer is restricted to another counterparty' });
        }
        if (!restricted && body.taker) {
          offer.request.taker = body.taker;
          offer.computed = compute(offer.request);
        }

        const signature = body.signature ?? offer.signatures.taker;
        if (!signature) return json(res, 400, { error: 'signature required' });
        offer.signatures.taker = signature;

        // Relaying funds both Sheds, so the baseline for "has it settled" must be read after it,
        // not before: otherwise the funding transfer itself looks like a sale.
        relay(offer.computed, offer.signatures.maker, offer.signatures.taker);
        offer.makerBalanceAtAccept = balanceOf(offer.computed.sellToken, offer.computed.makerShed);

        // The sub-solver now needs the private half: the maker's terms and its JIT order. Until
        // this file exists the order sits in the auction and nothing can pair it.
        fs.writeFileSync(path.join(OFFERS_DIR, `${offer.id}.json`), JSON.stringify(offer.computed, null, 2));

        offer.orderUid = await postOrder(offer.computed.takerOrder);
        offer.acceptedAt = new Date().toISOString();
        saveOffer(offer);

        return json(res, 202, { id: offer.id, orderUid: offer.orderUid, status: 'settling' });
      }
    }

    if (req.method === 'GET' && parts[0] === 'o' && parts[1]) {
      const offer = loadOffer(parts[1]);
      if (!offer) return json(res, 404, { error: 'unknown offer' });
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }).end(page(offer, offer.computed));
      return;
    }

    json(res, 404, { error: 'not found' });
  } catch (err) {
    json(res, 500, { error: err.message, stderr: String(err.stderr ?? '').slice(0, 800) });
  }
});

server.listen(PORT, () => {
  console.log(`private trade link service on ${PUBLIC_URL} (rpc ${RPC}, orderbook ${ORDERBOOK})`);
  if (!CONFIG.wrapper) console.warn('warning: PRIVATE_TRADE_WRAPPER is not set');
});
