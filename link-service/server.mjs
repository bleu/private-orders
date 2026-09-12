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

import { render } from './page.mjs';

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
function relay(computed, signatures) {
  fs.writeFileSync(
    path.join(ROOT, 'out-json', 'link-signatures.json'),
    JSON.stringify(
      {
        maker: signatures.maker,
        taker: signatures.taker,
        // Empty when the token has no permit; the relay skips those.
        makerPermit: signatures.makerPermit ?? '0x',
        takerPermit: signatures.takerPermit ?? '0x',
      },
      null,
      2,
    ),
  );
  let out;
  try {
    out = execFileSync(
      'forge',
      ['script', 'script/LinkRelay.s.sol', '--rpc-url', RPC, '--broadcast'],
      { cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, RELAYER_PRIVATE_KEY: CONFIG.relayerKey } },
    ).toString();
  } catch (err) {
    // The relay already says why in one line. Everything around it is the command that failed and
    // forge's build notices, which is noise to whoever is holding the link.
    throw new Error(relayReason(String(err.stderr ?? err.message ?? '')));
  }

  // The relay's own lines, returned so a caller can see what happened without reading a log file.
  return out
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.includes('permit applied') || line.includes('digest matches') || line.includes('relayed'));
}

/// The first `Error: ...` line out of a failed `forge` run, without the invocation around it.
function relayReason(text) {
  const lines = text.split('\n').map((line) => line.trim());
  const reason = lines.find((line) => line.startsWith('Error: ')) ?? lines.find(Boolean) ?? 'the relay failed';
  return reason.replace(/^Error: /, '').split('\n').slice(0, 4).join(' ');
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

/// Symbol and decimals, read once per token and kept on the offer. Raw amounts are unreadable —
/// `100000000` is not a price — and a client should never be the one to guess a token's decimals.
function tokenMeta(offer, token) {
  offer.tokens ??= {};
  const key = token.toLowerCase();
  if (!offer.tokens[key]) {
    offer.tokens[key] = {
      address: token,
      // `cast` returns a string return value quoted.
      symbol: cast(['call', token, 'symbol()(string)', '--rpc-url', RPC]).trim().replace(/^"|"$/g, ''),
      decimals: Number(cast(['call', token, 'decimals()(uint8)', '--rpc-url', RPC]).split(' ')[0]),
    };
  }
  return offer.tokens[key];
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

/// What a party must do before signing.
///
/// Where the token supports `permit`, the party signs an EIP-712 permit and the relayer submits it,
/// so the party needs no transaction at all. Where it does not, the party approves their Shed first —
/// the fallback that works for every token. The two cases are reported distinctly so a client never
/// has to guess which one it is in.
const funding = (computed, role) => {
  const side = role === 'maker' ? computed.makerBundle : computed.takerBundle;
  const common = { token: side.sellToken, owner: side.owner, spender: side.shed, amount: side.sellAmount };

  if (side.permitKind === 'none') {
    return {
      mode: 'approve',
      ...common,
      note: 'this token has no permit: approve your Shed first, then sign',
      approve: `approve(${side.shed}, ${side.sellAmount}) on ${side.sellToken}`,
    };
  }

  return {
    mode: 'permit',
    ...common,
    kind: side.permitKind,
    deadline: side.deadline,
    digest: side.permitDigest,
    note: `sign the permit and the bundle; the relayer submits both, so you need no transaction`,
    verify: 'the permit can only move this amount into your own Shed, so publishing it is safe',
  };
};

/// The terms, with amounts already scaled. No addresses: this view answers to whoever holds the link.
const publicTerms = (offer) => {
  const computed = offer.computed;
  const sell = tokenMeta(offer, computed.sellToken);
  const buy = tokenMeta(offer, computed.buyToken);
  return {
    sellToken: computed.sellToken,
    sellAmount: computed.sellAmount,
    sellSymbol: sell.symbol,
    sellDecimals: sell.decimals,
    buyToken: computed.buyToken,
    buyAmount: computed.buyAmount,
    buySymbol: buy.symbol,
    buyDecimals: buy.decimals,
    validTo: Number(computed.validTo),
    expiresAt: new Date(Number(computed.validTo) * 1000).toISOString(),
  };
};

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

      const offer = {
        id,
        request,
        computed,
        createdAt: new Date().toISOString(),
        signatures: {},
        permits: {},
      };
      saveOffer(offer);

      return json(res, 201, {
        id,
        link: `${PUBLIC_URL}/o/${id}`,
        funding: funding(computed, 'maker'),
        permitRequired: computed.makerBundle.permitKind !== 'none',
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

      if (req.method === 'GET' && parts[2] === 'role') {
        const who = (url.searchParams.get('address') ?? '').toLowerCase();
        if (!/^0x[0-9a-f]{40}$/.test(who)) return json(res, 400, { error: 'an address query parameter is required' });

        const maker = offer.computed.maker.toLowerCase();
        const taker = offer.request.taker.toLowerCase();
        const role = who === maker ? 'maker' : who === taker ? 'taker' : null;
        if (!role) return json(res, 200, { role: null, terms: publicTerms(offer) });

        const side = role === 'maker' ? offer.computed.makerBundle : offer.computed.takerBundle;
        return json(res, 200, {
          role,
          terms: publicTerms(offer),
          // Only a party learns who the other one is. The link itself is a bearer token, and the Shed
          // is derivable from its owner, so publishing it would publish the maker's address to
          // anyone holding the link.
          counterparty: role === 'taker' ? offer.computed.makerShed : offer.computed.takerBundle.shed,
          bundle: { digest: side.digest, typedData: side.bundleTypedData, deadline: Number(side.deadline) },
          permit: {
            kind: side.permitKind,
            digest: side.permitDigest,
            typedData: side.permitTypedData ?? null,
            typedDataAvailable: side.permitTypedDataAvailable === true,
            token: side.sellToken,
            amount: side.sellAmount,
            symbol: tokenMeta(offer, side.sellToken).symbol,
            decimals: tokenMeta(offer, side.sellToken).decimals,
            spender: side.shed,
            deadline: Number(side.deadline),
          },
          funding: funding(offer.computed, role),
          balance: balanceOf(side.sellToken, who),
          signed: offer.signatures?.[role] !== undefined,
          makerSigned: offer.signatures?.maker !== undefined,
          orderUid: offer.orderUid ?? null,
        });
      }

      if (req.method === 'GET' && parts.length === 2) {
        return json(res, 200, {
          id: offer.id,
          status: (await status(offer)).status,
          terms: publicTerms(offer),
          // Whether the counterparty has signed is not secret, and a taker waiting on a maker needs
          // to know it. Which addresses those are is not part of this view.
          makerSigned: offer.signatures?.maker !== undefined,
          takerSigned: offer.signatures?.taker !== undefined,
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
        const side = body.role === 'maker' ? offer.computed.makerBundle : offer.computed.takerBundle;
        if (side.permitKind !== 'none' && !/^0x[0-9a-fA-F]{130}$/.test(body.permitSignature ?? '')) {
          return json(res, 400, {
            error: `the sell token supports permit, so a permitSignature is required alongside it`,
            permitKind: side.permitKind,
          });
        }
        offer.signatures[body.role] = body.signature;
        if (body.permitSignature) offer.permits[body.role] = body.permitSignature;
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
        if (body.permitSignature) offer.permits.taker = body.permitSignature;

        for (const role of ['maker', 'taker']) {
          const side = role === 'maker' ? offer.computed.makerBundle : offer.computed.takerBundle;
          if (side.permitKind !== 'none' && !offer.permits[role]) {
            return json(res, 400, {
              error: `the ${role}'s sell token supports permit, so its permitSignature is required`,
              permitKind: side.permitKind,
              funding: funding(offer.computed, role),
            });
          }
        }

        // Relaying funds both Sheds, so the baseline for "has it settled" must be read after it,
        // not before: otherwise the funding transfer itself looks like a sale.
        const relayLog =
          relay(offer.computed, { ...offer.signatures, makerPermit: offer.permits.maker, takerPermit: offer.permits.taker });
        offer.makerBalanceAtAccept = balanceOf(offer.computed.sellToken, offer.computed.makerShed);

        // The sub-solver now needs the private half: the maker's terms and its JIT order. Until
        // this file exists the order sits in the auction and nothing can pair it.
        fs.writeFileSync(path.join(OFFERS_DIR, `${offer.id}.json`), JSON.stringify(offer.computed, null, 2));

        offer.orderUid = await postOrder(offer.computed.takerOrder);
        offer.acceptedAt = new Date().toISOString();
        saveOffer(offer);

        return json(res, 202, { id: offer.id, orderUid: offer.orderUid, status: 'settling', relay: relayLog });
      }
    }

    if (req.method === 'GET' && parts[0] === 'o' && parts[1]) {
      const offer = loadOffer(parts[1]);
      if (!offer) return json(res, 404, { error: 'unknown offer' });
      // No caching: this page is served by a service that changes, and a stale copy looks exactly
      // like a bug in the page.
      res
        .writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' })
        .end(render(offer.id));
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
