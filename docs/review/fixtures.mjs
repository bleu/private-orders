// Shared fixtures for the service-level review checks.
//
// The link service is bookkeeping around a chain it does not control, so the interesting behaviour —
// lifecycle, rendering, interleaving — cannot be exercised by Solidity tests and should not need a
// real chain. Two things stand in for the chain:
//
//   * `forge` and `cast` are fakes on PATH. They produce the same *shape* the real scripts produce,
//     and `cast wallet verify` compares a signature against the marker inside the typed data it was
//     handed — which is what makes a shared scratch file observable instead of invisible.
//   * the orderbook is an HTTP fixture the test process controls, so "the orderbook rejected the
//     order" is a switch rather than a timing accident.
//
// Everything else is the service as deployed: its router, its offer store, its page.
//
// Knobs, all read from the environment of the service process so a test can change one fact at a time:
//
//   FIXTURE_CHAIN_ID      chain id the trade is signed for (default 1)
//   FIXTURE_PERMIT_KIND   eip2612 | dai | none (default eip2612)
//   relay-fault file      makes the relay script fail
//   nothing-to-withdraw   makes the withdrawal plan empty

import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';

export const ROOT = path.resolve(import.meta.dirname, '..', '..');
export const SERVER = path.join(ROOT, 'link-service', 'server.mjs');

export const WRAPPER = '0x04d7478fdf318c3c22cece62da9d78ff94807d77';
export const SHED_FACTORY = '0x37d31345f164ab170b19bc35225abc98ce30b46a';
export const USDC = '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48';
export const DAI = '0x6b175474e89094c44da98b954eedeac495271d0f';
export const MAKER = '0x70997970c51812dc3a010c7d01b50e0d17dc79c8';
export const MAKER_SHED = '0xcacbe323025f53d14d21bbb8ce2f62b51e1e0949';
export const TAKER = '0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc';
export const TAKER_SHED = '0x2a0d702a38971d3d801d2abeb2ea12b2e5d168d9';
export const RELAYER_KEY = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export const freePort = () =>
  new Promise((resolve) => {
    const server = net.createServer();
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });

// --- the fake `forge` ------------------------------------------------------------------------------

export function forgeSource() {
  return `#!/usr/bin/env node
const fs = require('node:fs');
const crypto = require('node:crypto');

const args = process.argv.slice(2);
const root = process.env.PRIVATE_TRADE_ROOT;
const script = args[1] ?? '';
const chainId = Number(process.env.FIXTURE_CHAIN_ID ?? 1);
const permitKind = process.env.FIXTURE_PERMIT_KIND ?? 'eip2612';
const marker = (label) => crypto.createHash('sha256').update(label).digest('hex');

function fail(message) { process.stderr.write('Error: ' + message + '\\n'); process.exit(1); }
function typedData(owner, kind, anchor, nonce, deadline) {
  return {
    marker: kind === 'bundle' ? anchor : marker(kind + ':' + anchor),
    owner,
    primaryType: 'ExecuteHooks',
    domain: { name: 'COWShed', version: '2.0.0', chainId, verifyingContract: owner },
    types: {},
    message: { nonce, deadline },
  };
}
function permitTypedData(owner, anchor, nonce, deadline) {
  const data = typedData(owner, 'permit', anchor, nonce, deadline);
  data.primaryType = permitKind === 'dai' ? 'Permit' : 'Permit';
  data.fields = permitKind === 'dai' ? ['holder', 'spender', 'nonce', 'expiry', 'allowed'] : ['owner', 'spender', 'value', 'nonce', 'deadline'];
  return data;
}
function side(owner, shed, nonce, sellToken, sellAmount, anchor, deadline) {
  const usable = permitKind !== 'none';
  return {
    owner, shed, nonce, deadline, sellToken, sellAmount, funded: true,
    permitKind: usable ? permitKind : 'none',
    permitDigest: usable ? '0x' + marker('permit-digest:' + anchor) : '0x' + '0'.repeat(64),
    permitNonce: 7,
    permitTypedDataAvailable: usable,
    permitTypedData: usable ? permitTypedData(owner, anchor, nonce, deadline) : null,
    bundleTypedData: typedData(owner, 'bundle', anchor, nonce, deadline),
    digest: '0x' + marker('bundle-digest:' + anchor),
  };
}

if (script.endsWith('LinkCompute.s.sol')) {
  const request = JSON.parse(fs.readFileSync(process.env.LINK_REQUEST_FILE, 'utf8'));
  // Deterministic in the request: a restart must not change an offer's identity.
  const anchor = marker(JSON.stringify(request));
  const offerId = '0x' + anchor;
  const deadline = 4102444800;
  const computed = {
    wrapper: '${WRAPPER}',
    fund: true,
    offerId,
    appDataHash: '0x' + marker('app-data:' + anchor),
    appDataDocument: '{}',
    wrapperData: '0x',
    maker: '${MAKER}',
    makerShed: '${MAKER_SHED}',
    taker: request.taker,
    sellToken: request.sellToken,
    sellAmount: String(request.sellAmount),
    buyToken: request.buyToken,
    buyAmount: String(request.buyAmount),
    validTo: Number(request.validFor) > 0 ? Math.floor(Date.now() / 1000) - 1 + Number(request.validFor) : 0,
    makerCancellation: {
      owner: '${MAKER}',
      shed: '${MAKER_SHED}',
      nonce: '0x' + marker('cancel-nonce:' + anchor),
      deadline,
      bundleTypedData: typedData('${MAKER}', 'cancel', anchor, '0x' + marker('cancel-nonce:' + anchor), deadline),
      digest: '0x' + marker('cancel-digest:' + anchor),
    },
    makerBundle: side('${MAKER}', '${MAKER_SHED}', '0x' + marker('maker-nonce:' + anchor), request.sellToken, request.sellAmount, anchor, deadline),
    takerBundle: side(request.taker, '${TAKER_SHED}', '0x' + marker('taker-nonce:' + anchor), request.buyToken, request.buyAmount, anchor, deadline),
    makerJitOrder: { sellToken: request.sellToken, buyToken: request.buyToken, validTo: deadline },
    takerOrder: {
      sellToken: request.buyToken, buyToken: request.sellToken, receiver: request.taker,
      sellAmount: String(request.buyAmount), buyAmount: String(request.sellAmount),
      validTo: deadline, appData: '0x' + marker('app-data:' + anchor), feeAmount: '0',
      kind: 'sell', partiallyFillable: false, sellTokenBalance: 'erc20', buyTokenBalance: 'erc20',
      signingScheme: 'eip1271', signature: '0x', from: request.taker,
    },
    prices: { [request.sellToken]: String(request.buyAmount), [request.buyToken]: String(request.sellAmount) },
  };
  fs.writeFileSync(process.env.LINK_COMPUTED_FILE, JSON.stringify(computed));
  process.stdout.write('offerId ' + offerId + '\\n');
  process.exit(0);
}

if (script.endsWith('LinkRelay.s.sol')) {
  if (fs.existsSync(root + '/relay-fault')) fail('the relay failed on purpose');
  const broadcasting = args.includes('--broadcast');
  // A switch that fails only the dry run, so a test can prove the simulation happens and that
  // nothing was broadcast when it does not pass.
  if (!broadcasting && fs.existsSync(root + '/dry-run-fault')) fail('the dry run failed on purpose');
  if (broadcasting) {
    const file = root + '/broadcasts';
    fs.writeFileSync(file, String(Number(fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '0') + 1));
  }
  process.stdout.write('bundles relayed\\n');
  process.exit(0);
}

if (script.endsWith('LinkCancel.s.sol')) {
  process.stdout.write('cancellation relayed\\n');
  process.exit(0);
}

if (script.endsWith('Withdraw.s.sol')) {
  if (process.env.WITHDRAW_SIGNATURE_FILE) {
    process.stdout.write('withdrawn\\n');
    process.exit(0);
  }
  const request = JSON.parse(fs.readFileSync(process.env.WITHDRAW_REQUEST_FILE, 'utf8'));
  const plan = fs.existsSync(root + '/nothing-to-withdraw')
    ? { empty: true }
    : {
        shed: request.shed, owner: request.owner, targets: request.tokens, amounts: ['1'],
        nonce: '0x' + marker('withdraw:' + request.shed), deadline: 4102444800,
        digest: '0x' + marker('withdraw-digest:' + request.shed),
        bundleTypedData: { marker: marker('withdraw:' + request.shed), owner: request.owner },
      };
  fs.writeFileSync(process.env.WITHDRAW_COMPUTED_FILE, JSON.stringify(plan));
  process.exit(0);
}

process.stdout.write('');
`;
}

// --- the fake `cast` -------------------------------------------------------------------------------

/// `wallet verify` compares the signature's first 32 bytes with the marker inside the typed-data file
/// it was handed, so a shared file shows up as a wrong-marker rejection instead of passing quietly.
export function castSource() {
  return `#!/usr/bin/env node
const fs = require('node:fs');
const crypto = require('node:crypto');
const root = process.env.PRIVATE_TRADE_ROOT;
const args = process.argv.slice(2);
const valueAfter = (flag) => args[args.indexOf(flag) + 1];
const chainFile = root + '/chain.json';
const chain = () => JSON.parse(fs.readFileSync(chainFile, 'utf8'));
const save = (value) => fs.writeFileSync(chainFile, JSON.stringify(value));
const fail = (message) => { process.stderr.write(message + '\\n'); process.exit(1); };

if (args[0] === 'wallet' && args[1] === 'verify') {
  const file = valueAfter('--from-file');
  const address = String(valueAfter('--address')).toLowerCase();
  const signature = args[args.length - 1];
  let data;
  try { data = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (err) { fail('unreadable typed data: ' + err.message); }
  if (!data || typeof data.marker !== 'string') fail('the typed data has no marker');
  if (data.marker !== signature.slice(2, 66)) fail('signature is not over this message');
  if (String(data.owner ?? '').toLowerCase() !== address) fail('signature is not by ' + address);
  process.exit(0);
}

if (args[0] === 'wallet' && args[1] === 'sign') {
  // Signed over the typed data it was handed, marker and all, exactly as a wallet would sign the
  // message it was shown. A constant here would make every signature check fail for the wrong reason:
  // the server verifies against the marker, and this fake is what stands in for the wallet.
  const file = args.includes('--from-file') ? valueAfter('--from-file') : null;
  if (file) {
    const data = JSON.parse(fs.readFileSync(file, 'utf8'));
    // The trade's own messages carry a marker, so a signature can be tied to the message it is for.
    // A Safe message does not: the page asks for that wrapping on purpose, and the account is what
    // decides whether the result is valid, so the fixture answers with the one blob it is told to
    // expect (chain.json signatures).
    if (typeof data.marker === 'string') {
      process.stdout.write('0x' + data.marker + '0'.repeat(64) + '1b');
      process.exit(0);
    }
    process.stdout.write('0x' + '42'.repeat(65));
    process.exit(0);
  }
  process.stdout.write('0x' + 'ab'.repeat(32) + 'cd'.repeat(32) + '1b');
  process.exit(0);
}

if (args[0] === 'receipt') {
  const receipts = chain().receipts ?? {};
  if (!receipts[args[1]]) fail('no receipt for ' + args[1]);
  process.stdout.write(JSON.stringify(receipts[args[1]]));
  process.exit(0);
}

// A development approve, broadcast on a chain that has no chain. The test asserts the calldata the
// page sent; this records the effect, so the allowance the page reads afterwards is the real one.
if (args[0] === 'send') {
  const to = String(args[1]).toLowerCase();
  const data = String(args[2]);
  if (!data.startsWith('0x095ea7b3')) fail('fake cast: only approve is supported for send');
  const spender = '0x' + data.slice(34, 74);
  const amount = BigInt('0x' + data.slice(74, 138)).toString();
  const state = chain();
  state.approvals ??= {};
  state.approvals[to] ??= {};
  state.approvals[to][spender] = amount;
  save(state);
  process.stdout.write(JSON.stringify({ transactionHash: '0x' + crypto.createHash('sha256').update(data).digest('hex') }) + '\\n');
  process.exit(0);
}

if (args[0] === 'code') {
  const state = chain();
  const address = String(args[1]).toLowerCase();
  process.stdout.write((state.contracts ?? []).includes(address) ? '0x60806040' : '0x');
  process.exit(0);
}

if (args[0] === 'call') {
  const target = args[1];
  const signature = args[2];
  const state = chain();

  // The checks the service makes before a party is asked to sign. Each has a switch, so a test can
  // assert that the failure is reported before the prompt rather than after it.
  if (signature.startsWith('validateWrapperData')) {
    if (state.wrapperRejects) fail('the wrapper refuses this offer');
    process.stdout.write('0x1626ba7e');
    process.exit(0);
  }
  if (signature.startsWith('AUTHENTICATOR')) {
    process.stdout.write(state.authenticator ?? '0x00000000000000000000000000000000000000a1');
    process.exit(0);
  }
  if (signature.startsWith('isSolver')) {
    process.stdout.write(state.unallowlisted ? 'false' : 'true');
    process.exit(0);
  }
  if (signature.startsWith('getThreshold')) {
    process.stdout.write(String(state.thresholds?.[String(target).toLowerCase()] ?? 1));
    process.exit(0);
  }
  if (signature.startsWith('getOwners')) {
    const owners = state.owners?.[String(target).toLowerCase()] ?? [target];
    process.stdout.write('[' + owners.join(', ') + ']');
    process.exit(0);
  }
  // A contract owner is asked over ERC-1271. The fake answers for exactly the blob the test put
  // there, so a wrong signature is refused the way an account would refuse it.
  if (signature.startsWith('isValidSignature')) {
    const expected = state.signatures?.[String(target).toLowerCase()];
    if (!expected) fail('no signature is expected for ' + target);
    process.stdout.write(String(args[4]).toLowerCase() === expected.toLowerCase() ? '0x1626ba7e' : '0xffffffff');
    process.exit(0);
  }
  if (signature.startsWith('offerState')) {
    process.stdout.write(String(state.offerState?.[args[3]] ?? 0) + '\\n');
    process.exit(0);
  }
  if (signature.startsWith('symbol')) {
    process.stdout.write(JSON.stringify(state.tokens?.[target]?.symbol ?? 'TOKEN') + '\\n');
    process.exit(0);
  }
  if (signature.startsWith('decimals')) {
    process.stdout.write(String(state.tokens?.[target]?.decimals ?? 18) + '\\n');
    process.exit(0);
  }
  if (signature.startsWith('balanceOf')) {
    process.stdout.write(String(state.tokens?.[target]?.balances?.[String(args[3]).toLowerCase()] ?? '0') + '\\n');
    process.exit(0);
  }
  if (signature.startsWith('allowance')) {
    const owner = String(args[3]).toLowerCase();
    const spender = String(args[4]).toLowerCase();
    process.stdout.write(String(state.allowances?.[target]?.[owner]?.[spender] ?? state.approvals?.[target]?.[spender] ?? '0') + '\\n');
    process.exit(0);
  }
}

fail('fake cast: unhandled invocation ' + args.join(' '));
`;
}

// --- the orderbook fixture -------------------------------------------------------------------------

export async function startOrderbook() {
  const state = { posts: 0, rejectOrders: false, orders: new Map(), trades: new Map() };
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://orderbook');
    const send = (status, body) => res.writeHead(status, { 'content-type': 'application/json' }).end(JSON.stringify(body));

    if (req.method === 'POST' && url.pathname === '/api/v1/orders') {
      let raw = '';
      req.on('data', (chunk) => (raw += chunk));
      req.on('end', () => {
        state.posts += 1;
        if (state.rejectOrders) return send(500, { error: 'the orderbook rejected the order' });
        const uid = `0x${crypto.createHash('sha256').update(raw).digest('hex').slice(0, 56)}`;
        state.orders.set(uid, 'open');
        send(201, uid);
      });
      return;
    }

    const order = url.pathname.match(/^\/api\/v1\/orders\/(.+)$/);
    if (req.method === 'GET' && order) return send(200, { status: state.orders.get(order[1]) ?? 'unknown' });

    if (req.method === 'GET' && url.pathname === '/api/v1/trades') {
      const uid = url.searchParams.get('uid') ?? url.searchParams.get('orderUid');
      const txHash = state.trades.get(uid);
      return send(200, txHash ? [{ txHash }] : []);
    }

    send(404, { error: 'not found' });
  });
  const port = await freePort();
  await new Promise((resolve) => server.listen(port, '127.0.0.1', resolve));
  return { state, url: `http://127.0.0.1:${port}`, close: () => new Promise((resolve) => server.close(resolve)) };
}

// --- the service under test ------------------------------------------------------------------------

/// One root per test: an offer store, the two fakes, and the chain the fakes read.
export function makeRoot() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'private-trade-fixture.'));
  fs.mkdirSync(path.join(root, 'out-json', 'link'), { recursive: true });
  fs.mkdirSync(path.join(root, 'out-json', 'sub-solver-offers'), { recursive: true });
  fs.mkdirSync(path.join(root, 'bin'), { recursive: true });
  fs.writeFileSync(path.join(root, 'out-json', 'private-trade-deployed.json'), '{}');

  for (const [name, source] of [['forge', forgeSource()], ['cast', castSource()]]) {
    const file = path.join(root, 'bin', name);
    fs.writeFileSync(file, source);
    fs.chmodSync(file, 0o755);
  }

  // Both parties hold what they are selling, because the service now refuses to take a signature for
  // a side that could not fund its Shed. Without this the harness would exercise a state the chain
  // can never be in.
  setChain(root, {
    tokens: {
      [USDC]: { symbol: 'USDC', decimals: 6, balances: { [MAKER]: '1000000000000' } },
      [DAI]: { symbol: 'DAI', decimals: 18, balances: { [TAKER]: '1000000000000000000000000' } },
    },
  });
  return root;
}

export function setChain(root, patch) {
  const file = path.join(root, 'chain.json');
  const chain = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : {};
  fs.writeFileSync(file, JSON.stringify({ ...chain, ...patch }));
}

const children = new Set();

export async function startService({ root, port, orderbook, extraEnv = {} }) {
  const child = spawn(process.execPath, [SERVER], {
    cwd: ROOT,
    env: {
      ...process.env,
      PATH: `${path.join(root, 'bin')}${path.delimiter}${process.env.PATH}`,
      PRIVATE_TRADE_ROOT: root,
      PORT: String(port),
      PUBLIC_URL: `http://127.0.0.1:${port}`,
      RPC: 'http://127.0.0.1:1',
      ORDERBOOK_URL: orderbook,
      SUBSOLVER_OFFERS_DIR: path.join(root, 'out-json', 'sub-solver-offers'),
      PRIVATE_TRADE_WRAPPER: WRAPPER,
      COWSHED_COMPOSABLE_COW_FACTORY_ADDRESS: SHED_FACTORY,
      RELAYER_PRIVATE_KEY: RELAYER_KEY,
      PRIVATE_TRADE_DEV_KEYS: '',
      ...extraEnv,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  children.add(child);
  let stderr = '';
  child.stderr.on('data', (chunk) => (stderr += chunk));

  for (let attempt = 0; attempt < 120; attempt += 1) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/health`);
      if (res.ok) return { port, child, stop: () => stop(child), stderr: () => stderr };
    } catch {
      // not listening yet
    }
    await sleep(50);
  }
  throw new Error(`the service did not start: ${stderr}`);
}

export function stop(child) {
  return new Promise((resolve) => {
    children.delete(child);
    if (child.exitCode !== null || child.signalCode !== null) return resolve();
    child.once('exit', resolve);
    child.kill('SIGKILL');
  });
}

export function killAll() {
  for (const child of children) child.kill('SIGKILL');
  children.clear();
}

// --- HTTP against the service ----------------------------------------------------------------------

export async function call(port, method, route, body) {
  const res = await fetch(`http://127.0.0.1:${port}${route}`, {
    method,
    headers: body ? { 'content-type': 'application/json' } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let parsed;
  try {
    parsed = text ? JSON.parse(text) : null;
  } catch {
    parsed = text;
  }
  return { status: res.status, body: parsed };
}

export const offerRecord = (root, id) =>
  JSON.parse(fs.readFileSync(path.join(root, 'out-json', 'link', `${id}.json`), 'utf8'));

export const markerOf = (typedData) => typedData.marker;
export const signatureOver = (typedData) => `0x${markerOf(typedData)}${'0'.repeat(64)}1b`;

export async function createOffer(port, overrides = {}) {
  const request = {
    maker: MAKER,
    taker: TAKER,
    sellToken: USDC,
    sellAmount: '100000000',
    buyToken: DAI,
    buyAmount: '100000000000000000000',
    validFor: 86400,
    ...overrides,
  };
  const res = await call(port, 'POST', '/offers', request);
  if (res.status !== 201) throw new Error(`create failed: ${JSON.stringify(res.body)}`);
  return { id: res.body.id, offerId: res.body.offerId, request };
}