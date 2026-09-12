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
import { execFileSync, spawnSync } from 'node:child_process';

import { render } from './page.mjs';

const PORT = Number(process.env.PORT ?? 9200);
const ROOT = process.env.PRIVATE_TRADE_ROOT ?? path.resolve(import.meta.dirname, '..');
const RPC = process.env.RPC ?? 'http://localhost:8545';
const ORDERBOOK = process.env.ORDERBOOK_URL ?? 'http://localhost:8080';
const STORE = path.join(ROOT, 'out-json', 'link');
// Where the sub-solver looks for private offers. One file per live offer.
const OFFERS_DIR = process.env.SUBSOLVER_OFFERS_DIR ?? path.join(ROOT, 'out-json', 'sub-solver-offers');
const PUBLIC_URL = process.env.PUBLIC_URL ?? `http://localhost:${PORT}`;

// The deploy script writes the addresses it deployed. Reading them as a fallback means the service
// starts correctly by hand, not only when a script exports the environment first.
const deployed = (() => {
  try {
    return JSON.parse(fs.readFileSync(path.join(ROOT, 'out-json', 'private-trade-deployed.json'), 'utf8'));
  } catch {
    return {};
  }
})();

const CONFIG = {
  wrapper: process.env.PRIVATE_TRADE_WRAPPER ?? deployed.wrapper,
  handler: process.env.PRIVATE_TRADE_HANDLER ?? deployed.handler,
  shedFactory: process.env.COWSHED_COMPOSABLE_COW_FACTORY_ADDRESS,
  composableCoW: process.env.COMPOSABLE_COW_ADDRESS,
  authoriser: process.env.PRIVATE_TRADE_AUTHORISER ?? deployed.authoriser,
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

const PROBE_DOMAIN = {
  name: 'PrivateTradeProbe',
  version: '1',
  chainId: 1,
  verifyingContract: '0x0000000000000000000000000000000000000001',
};

/// Diagnostics, not payloads: each probe adds one feature, so the first failure names the culprit.
function probes() {
  return [
    {
      name: '1. one uint256',
      typedData: {
        primaryType: 'Probe',
        domain: PROBE_DOMAIN,
        types: { Probe: [{ name: 'value', type: 'uint256' }] },
        message: { value: '42' },
      },
    },
    {
      name: '2. array of a struct holding bytes',
      typedData: {
        primaryType: 'Probe',
        domain: PROBE_DOMAIN,
        types: {
          Probe: [{ name: 'items', type: 'Item[]' }],
          Item: [
            { name: 'target', type: 'address' },
            { name: 'value', type: 'uint256' },
            { name: 'callData', type: 'bytes' },
            { name: 'allowFailure', type: 'bool' },
            { name: 'isDelegateCall', type: 'bool' },
          ],
        },
        message: {
          items: [
            {
              target: '0x6b175474e89094c44da98b954eedeac495271d0f',
              value: '0',
              callData: '0x095ea7b3000000000000000000000000c92e8bdf79f0507f65a392b0ab4667716bfe0110',
              allowFailure: false,
              isDelegateCall: false,
            },
          ],
        },
      },
    },
  ];
}

/// Which side of a trade an address is, or null. Kept in one place so the role view and the
/// withdrawal agree on who may ask for what.
function addressRole(offer, who) {
  if (who === offer.computed.maker.toLowerCase()) return 'maker';
  if (who === offer.request.taker.toLowerCase()) return 'taker';
  return null;
}

/// What the party's Shed holds, as a bundle to sign. Writes the request, runs the computation, and
/// returns the plan — including `empty: true` when there is nothing to move.
function withdrawPlan(offer, role) {
  const side = role === 'maker' ? offer.computed.makerBundle : offer.computed.takerBundle;
  fs.writeFileSync(
    path.join(ROOT, 'out-json', 'withdraw-request.json'),
    JSON.stringify(
      {
        shedFactory: CONFIG.shedFactory,
        shed: side.shed,
        owner: side.owner,
        // Both tokens: a trade can leave the sell side behind if it was not fully spent.
        tokens: [offer.computed.sellToken, offer.computed.buyToken],
      },
      null,
      2,
    ),
  );
  execFileSync('forge', ['script', 'script/Withdraw.s.sol', '--rpc-url', RPC], { cwd: ROOT, stdio: 'pipe' });
  const plan = JSON.parse(fs.readFileSync(path.join(ROOT, 'out-json', 'withdraw-computed.json'), 'utf8'));
  if (plan.empty) return { empty: true, shed: side.shed };
  return { ...plan, shed: side.shed, role };
}

/// Does this signature belong to `address` over this exact typed data?
///
/// Returns null when the question cannot be asked (no typed data, or a malformed signature), so the
/// caller can tell "verified false" apart from "not checked".
function verifies(typedData, signature, address) {
  if (!typedData || !/^0x[0-9a-fA-F]{130}$/.test(signature ?? '')) return null;
  const file = path.join(ROOT, 'out-json', 'verify.json');
  fs.writeFileSync(file, JSON.stringify(typedData));
  const res = spawnSync(
    'cast',
    ['wallet', 'verify', '--address', address, '--data', '--from-file', file, signature],
    { encoding: 'utf8' },
  );
  return res.status === 0;
}

/// Check a party's signatures before anything is relayed.
///
/// The relay verifies them too, but it can only report that a signature recovered to a different
/// address — which is true of every way of getting this wrong. Asking the question here, against the
/// message the page showed, distinguishes "signed the other prompt" from "signed something else
/// entirely", and the wallet's own account list is echoed back because the usual cause is a wallet
/// signing with an account other than the one that connected.
function preflight(offer, role, body) {
  const side = role === 'maker' ? offer.computed.makerBundle : offer.computed.takerBundle;
  const owner = side.owner;
  const problems = [];

  // Some wallets answer two prompts with one signature. Nothing verifies in that case, and the
  // symptom is otherwise identical to a wrong account.
  if (body.permitSignature && body.permitSignature === body.signature) {
    return {
      error: `The ${role}'s wallet returned the same signature for both prompts. Each prompt has to be approved separately.`,
      expectedSigner: owner,
      walletAccounts: body.accounts ?? null,
    };
  }

  if (side.permitKind !== 'none' && side.permitTypedData) {
    if (verifies(side.permitTypedData, body.permitSignature, owner) === false) {
      problems.push(
        verifies(side.bundleTypedData, body.permitSignature, owner)
          ? 'the permit signature is over the order authorisation, so the two prompts were answered in the wrong order'
          : `the permit signature is not a signature of the permit this page showed, by ${owner}`,
      );
    }
  }

  if (verifies(side.bundleTypedData, body.signature, owner) === false) {
    problems.push(`the order signature is not a signature of the authorisation this page showed, by ${owner}`);
  }

  if (!problems.length) return null;
  return {
    error: `The ${role}'s signatures do not match this trade: ${problems.join('; ')}.`,
    expectedSigner: owner,
    // Echoed so the reader can see which account the wallet is actually on.
    walletAccounts: body.accounts ?? null,
    hint: 'In the wallet, make the account above the active one — a wallet signs with whichever account is selected, not the one the page connected with.',
  };
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

/// The settlement transaction, looked up from the trade the order produced. A "settled" with no
/// transaction is not much of a receipt.
async function settlementTx(orderUid) {
  try {
    const res = await fetch(`${ORDERBOOK}/api/v1/trades?orderUid=${orderUid}`);
    if (!res.ok) return null;
    const trades = await res.json();
    return Array.isArray(trades) && trades.length ? trades[0].txHash : null;
  } catch {
    return null;
  }
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
    return { status: 'settled', orderUid: offer.orderUid, settlementTx: await settlementTx(offer.orderUid) };
  }
  const order = await orderStatus(offer.orderUid);
  const settled = order.status === 'fulfilled';
  return {
    status: settled ? 'settled' : 'settling',
    orderUid: offer.orderUid,
    settlementTx: settled ? await settlementTx(offer.orderUid) : null,
  };
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

    // Typed-data probes, simplest first. Every one of these is canonical EIP-712, so a wallet that
    // signs them all correctly and still cannot sign the bundle tells us the problem is one specific
    // feature of the struct — and if even the simplest fails, the wallet is not hashing what it shows.
    if (req.method === 'GET' && parts[0] === 'probes') {
      return json(res, 200, probes());
    }

    if (req.method === 'POST' && parts[0] === 'probes') {
      const body = await readBody(req);
      const results = body.signatures.map(({ name, signature, typedData }) => {
        const file = path.join(ROOT, 'out-json', 'probe.json');
        fs.writeFileSync(file, JSON.stringify(typedData));
        const res2 = spawnSync(
          'cast',
          ['wallet', 'verify', '--address', body.address, '--data', '--from-file', file, signature],
          { encoding: 'utf8' },
        );
        console.log('probe', name, res2.status === 0 ? 'OK' : 'FAIL', signature);
        return { name, ok: res2.status === 0 };
      });
      return json(res, 200, { address: body.address, results });
    }

    // A diagnostic: the wallet signs a message this service chose, and we recover the signer. It
    // separates "the wallet is on a different key" from "the wallet hashed a different message" —
    // a distinction no amount of guesswork about typed-data encodings can make.
    if (req.method === 'POST' && parts[0] === 'wallet-check') {
      const body = await readBody(req);
      const file = path.join(ROOT, 'out-json', 'wallet-check.json');
      fs.writeFileSync(file, JSON.stringify(body, null, 2));
      const out = execFileSync(
        'forge',
        ['script', 'script/Diagnose.s.sol', '--rpc-url', RPC],
        {
          cwd: ROOT,
          encoding: 'utf8',
          env: {
            ...process.env,
            DIAG_MESSAGE: body.message,
            DIAG_SIG_FILE: 'out-json/wallet-check.json',
            COMPOSABLE_COW_ADDRESS: CONFIG.composableCoW ?? '',
          },
        },
      );
      const recovered = (out.match(/recovered (0x[0-9a-fA-F]{40})/) ?? [])[1] ?? null;
      console.log('wallet-check', body.address, 'recovered', recovered, 'chainId', body.chainId, body.signature);
      return json(res, 200, {
        claimed: body.address,
        recovered,
        matches: recovered?.toLowerCase() === String(body.address).toLowerCase(),
      });
    }

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
        authoriser: CONFIG.authoriser,
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

    // Everything the party's Shed holds, ready to be moved to their wallet. Computing it needs the
    // chain, so it is the same Solidity that signs it.
    if (req.method === 'GET' && parts[2] === 'withdraw') {
      const who = (url.searchParams.get('address') ?? '').toLowerCase();
      const role = addressRole(offer, who);
      if (!role) return json(res, 403, { error: 'this link is for a specific wallet' });
      return json(res, 200, withdrawPlan(offer, role));
    }

    if (req.method === 'POST' && parts[2] === 'withdraw') {
      const body = await readBody(req);
      const role = addressRole(offer, String(body.address ?? '').toLowerCase());
      if (!role) return json(res, 403, { error: 'this link is for a specific wallet' });
      if (!/^0x[0-9a-fA-F]{130}$/.test(body.signature ?? '')) {
        return json(res, 400, { error: 'signature must be 65 bytes, r || s || v' });
      }

      // The computed plan is replayed, never recomputed: a fresh deadline would build a different
      // message and reject a signature that is valid for what was signed.
      const file = path.join(ROOT, 'out-json', 'withdraw-signature.json');
      fs.writeFileSync(file, JSON.stringify({ signature: body.signature }, null, 2));
      try {
        const out = execFileSync(
          'forge',
          ['script', 'script/Withdraw.s.sol', '--rpc-url', RPC, '--broadcast'],
          {
            cwd: ROOT,
            encoding: 'utf8',
            env: {
              ...process.env,
              WITHDRAW_SIGNATURE_FILE: 'out-json/withdraw-signature.json',
              RELAYER_PRIVATE_KEY: CONFIG.relayerKey,
            },
          },
        );
        const line = out.split('\n').map((l) => l.trim()).filter((l) => /withdrawn|already/.test(l));
        return json(res, 200, { moved: true, relay: line });
      } catch (err) {
        return json(res, 400, { error: relayReason(String(err.stderr ?? err.message ?? '')) });
      }
    }

      if (req.method === 'GET' && parts[2] === 'status') return json(res, 200, await status(offer));

      if (req.method === 'POST' && parts[2] === 'signature') {
        const body = await readBody(req);
        // Kept in the log because a signature that does not verify is otherwise unrecoverable:
        // it is the only artefact that says which message the wallet actually signed.
        console.log('signature', offer.id, body.role, JSON.stringify(body));
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
        const wrong = preflight(offer, body.role, body);
        if (wrong) return json(res, 400, wrong);

        offer.signatures[body.role] = body.signature;
        if (body.permitSignature) offer.permits[body.role] = body.permitSignature;
        saveOffer(offer);
        return json(res, 200, { id: offer.id, signed: Object.keys(offer.signatures) });
      }

      if (req.method === 'POST' && parts[2] === 'accept') {
        const body = await readBody(req);
        console.log('accept', offer.id, JSON.stringify(body));
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
        // Always check what is being submitted now, not what is already on file.
        const wrong = preflight(offer, 'taker', { ...body, signature });
        if (wrong) return json(res, 400, wrong);

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
