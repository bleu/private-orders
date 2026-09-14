#!/usr/bin/env node
// Lifecycle tests for the link service, driven through its real HTTP surface.
//
// The service's job is bookkeeping around a chain it does not control, so the behaviour worth
// pinning — interleaving, restart, retries, duplicate acceptance, cancellation, expiry, recovery —
// is not contract behaviour and cannot be tested in Solidity. Testing it against a real chain would
// make the test slow and the failure ambiguous: "recovery failed" and "anvil was not up" would look
// the same.
//
// So this file runs the real `link-service/server.mjs`, over real HTTP, with two things replaced:
//
//   * `forge` and `cast` are fakes on PATH. They produce the same *shape* `LinkCompute` produces,
//     and they verify a signature only against the marker inside the typed data they were handed —
//     which is what makes a shared scratch file observable instead of invisible.
//   * the orderbook is an HTTP fixture this process controls, so "the orderbook rejected the order"
//     is a switch, not a timing accident.
//
// Everything else is the service as deployed: its router, its offer store, its relay retries.
//
//   node docs/review/service-lifecycle.mjs

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';

const ROOT = path.resolve(import.meta.dirname, '..', '..');
const SERVER = path.join(ROOT, 'link-service', 'server.mjs');

const WRAPPER = '0x04d7478fdf318c3c22cece62da9d78ff94807d77';
const SHED_FACTORY = '0x37d31345f164ab170b19bc35225abc98ce30b46a';
const USDC = '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48';
const DAI = '0x6b175474e89094c44da98b954eedeac495271d0f';
const MAKER = '0x70997970c51812dc3a010c7d01b50e0d17dc79c8';
const TAKER = '0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc';
const RELAYER_KEY = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const freePort = () =>
  new Promise((resolve) => {
    const server = net.createServer();
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });

// --- the fakes ------------------------------------------------------------------------------------

/// `forge`, with the four scripts the service runs. LinkCompute is the interesting one: it has to
/// produce every field the service reads, and the markers the tests sign over.
function forgeSource() {
  return `#!/usr/bin/env node
const fs = require('node:fs');
const crypto = require('node:crypto');

const args = process.argv.slice(2);
const root = process.env.PRIVATE_TRADE_ROOT;
const script = args[1] ?? '';
const marker = (label) => crypto.createHash('sha256').update(label).digest('hex');

function fail(message) { process.stderr.write('Error: ' + message + '\\n'); process.exit(1); }
function typedData(owner, kind, anchor, nonce, deadline) {
  return {
    marker: kind === 'bundle' ? anchor : marker(kind + ':' + anchor),
    owner,
    primaryType: 'ExecuteHooks',
    domain: { name: 'COWShed', version: '2.0.0', chainId: 1, verifyingContract: owner },
    types: {},
    message: { nonce, deadline },
  };
}
function side(owner, shed, nonce, sellToken, sellAmount, anchor, deadline) {
  return {
    owner, shed, nonce, deadline, sellToken, sellAmount, funded: true,
    permitKind: 'eip2612',
    permitDigest: '0x' + marker('permit-digest:' + anchor),
    permitNonce: 7,
    permitTypedDataAvailable: true,
    permitTypedData: typedData(owner, 'permit', anchor, nonce, deadline),
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
    makerShed: '0xcacbe323025f53d14d21bbb8ce2f62b51e1e0949',
    taker: request.taker,
    sellToken: request.sellToken,
    sellAmount: String(request.sellAmount),
    buyToken: request.buyToken,
    buyAmount: String(request.buyAmount),
    validTo: request.validFor > 0 ? Math.floor(Date.now() / 1000) - 1 + Number(request.validFor) : 0,
    makerCancellation: {
      owner: '${MAKER}',
      shed: '0xcacbe323025f53d14d21bbb8ce2f62b51e1e0949',
      nonce: '0x' + marker('cancel-nonce:' + anchor),
      deadline,
      bundleTypedData: typedData('${MAKER}', 'cancel', anchor, '0x' + marker('cancel-nonce:' + anchor), deadline),
      digest: '0x' + marker('cancel-digest:' + anchor),
    },
    makerBundle: side('${MAKER}', '0xcacbe323025f53d14d21bbb8ce2f62b51e1e0949', '0x' + marker('maker-nonce:' + anchor), request.sellToken, request.sellAmount, anchor, deadline),
    takerBundle: side(request.taker, '0x2a0d702a38971d3d801d2abeb2ea12b2e5d168d9', '0x' + marker('taker-nonce:' + anchor), request.buyToken, request.buyAmount, anchor, deadline),
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
  // One switch, so "the relay failed" is a decision the test makes rather than a race it waits for.
  if (fs.existsSync(root + '/relay-fault')) fail('the relay failed on purpose');
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

/// `cast`. `wallet verify` is the one that matters: it compares the signature's first 32 bytes with
/// the marker inside the typed-data file it was handed. A shared file shows up as a wrong-marker
/// rejection instead of passing quietly.
function castSource() {
  return `#!/usr/bin/env node
const fs = require('node:fs');
const root = process.env.PRIVATE_TRADE_ROOT;
const args = process.argv.slice(2);
const valueAfter = (flag) => args[args.indexOf(flag) + 1];
const chain = () => JSON.parse(fs.readFileSync(root + '/chain.json', 'utf8'));
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
  process.stdout.write('0x' + 'ab'.repeat(32) + 'cd'.repeat(32) + '1b');
  process.exit(0);
}

if (args[0] === 'receipt') {
  const receipts = chain().receipts ?? {};
  if (!receipts[args[1]]) fail('no receipt for ' + args[1]);
  process.stdout.write(JSON.stringify(receipts[args[1]]));
  process.exit(0);
}

if (args[0] === 'call') {
  const target = args[1];
  const signature = args[2];
  const state = chain();
  if (signature.startsWith('offerState')) {
    process.stdout.write(String(state.offerState?.[args[3]] ?? 0) + '\\n');
    process.exit(0);
  }
  if (signature.startsWith('symbol')) {
    process.stdout.write('"' + (state.tokens?.[target]?.symbol ?? 'TOKEN') + '"\\n');
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
}

fail('fake cast: unhandled invocation ' + args.join(' '));
`;
}

// --- the orderbook fixture -----------------------------------------------------------------------

async function startOrderbook() {
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
      const uid = url.searchParams.get('orderUid');
      const txHash = state.trades.get(uid);
      return send(200, txHash ? [{ txHash }] : []);
    }

    send(404, { error: 'not found' });
  });
  const port = await freePort();
  await new Promise((resolve) => server.listen(port, '127.0.0.1', resolve));
  return { state, url: `http://127.0.0.1:${port}`, close: () => new Promise((resolve) => server.close(resolve)) };
}

// --- the service under test ----------------------------------------------------------------------

const children = new Set();

async function startService({ root, port, orderbook }) {
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
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  children.add(child);
  let stderr = '';
  child.stderr.on('data', (chunk) => (stderr += chunk));

  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/health`);
      if (res.ok) return { port, stop: () => stop(child), stderr: () => stderr };
    } catch {
      // not listening yet
    }
    await sleep(50);
  }
  throw new Error(`the service did not start: ${stderr}`);
}

function stop(child) {
  return new Promise((resolve) => {
    if (child.exitCode !== null || child.signalCode !== null) return resolve();
    child.once('exit', resolve);
    child.kill('SIGKILL');
    children.delete(child);
  });
}

// --- fixture root --------------------------------------------------------------------------------

function makeRoot() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'private-trade-lifecycle.'));
  fs.mkdirSync(path.join(root, 'out-json', 'link'), { recursive: true });
  fs.mkdirSync(path.join(root, 'out-json', 'sub-solver-offers'), { recursive: true });
  fs.mkdirSync(path.join(root, 'bin'), { recursive: true });
  fs.writeFileSync(path.join(root, 'out-json', 'private-trade-deployed.json'), '{}');

  for (const [name, source] of [['forge', forgeSource()], ['cast', castSource()]]) {
    const file = path.join(root, 'bin', name);
    fs.writeFileSync(file, source);
    fs.chmodSync(file, 0o755);
  }

  setChain(root, {});
  return root;
}

function setChain(root, patch) {
  const file = path.join(root, 'chain.json');
  const chain = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : {};
  fs.writeFileSync(file, JSON.stringify({ ...chain, ...patch }));
}

const offerRecord = (root, id) => JSON.parse(fs.readFileSync(path.join(root, 'out-json', 'link', `${id}.json`), 'utf8'));
const markerOf = (typedData) => typedData.marker;
const signatureOver = (typedData) => `0x${markerOf(typedData)}${'0'.repeat(64)}1b`;
const offerIdOf = (marker) => `0x${marker}`;

// --- HTTP against the service ---------------------------------------------------------------------

async function call(port, method, route, body) {
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

async function createOffer(port, overrides = {}) {
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
  assert.equal(res.status, 201, `create failed: ${JSON.stringify(res.body)}`);
  return { id: res.body.id, offerId: res.body.offerId, request };
}

/// Both parties sign, in the order the flow requires: the maker's signature first, because accept
/// refuses to relay while a permit is missing.
async function signAs(port, id, role = 'maker') {
  const record = offerRecord(currentRoot, id);
  const side = role === 'maker' ? record.computed.makerBundle : record.computed.takerBundle;
  const res = await call(port, 'POST', `/offers/${record.id}/signature`, {
    role,
    signature: signatureOver(side.bundleTypedData),
    permitSignature: signatureOver(side.permitTypedData),
  });
  assert.equal(res.status, 200, `${role} signature rejected: ${JSON.stringify(res.body)}`);
  return { signature: signatureOver(side.bundleTypedData), permitSignature: signatureOver(side.permitTypedData) };
}

// --- tests ----------------------------------------------------------------------------------------

const tests = [];
const test = (name, fn) => tests.push({ name, fn });
let currentRoot = null;

const settledChain = (offerId) => ({
  offerState: { [offerId]: 1 },
});
const successfulReceipt = { status: '0x1', blockNumber: '0x10' };

test('two offers interleaved in one service keep their own digests and signatures', async () => {
  const root = currentRoot;
  const first = await createOffer(port, { sellAmount: '1' });
  const second = await createOffer(port, { sellAmount: '2' });
  assert.notEqual(first.offerId, second.offerId, 'two offers got the same identity');

  const firstRecord = offerRecord(root, first.id);
  const secondRecord = offerRecord(root, second.id);
  assert.notEqual(
    firstRecord.computed.makerBundle.digest,
    secondRecord.computed.makerBundle.digest,
    'two offers share a bundle digest',
  );
  assert.equal(
    markerOf(firstRecord.computed.makerBundle.bundleTypedData),
    first.offerId.slice(2),
    "the maker's typed data is not the offer's own",
  );

  // The two submissions overlap in time, and each must be checked against its own message.
  const [a, b] = await Promise.all([signAs(port, first.id), signAs(port, second.id)]);
  assert.deepEqual(offerRecord(root, first.id).signatures.maker, a.signature);
  assert.deepEqual(offerRecord(root, second.id).signatures.maker, b.signature);
  // A signature for the first offer must not be accepted as a signature for the second.
  const crossed = await call(port, 'POST', `/offers/${second.id}/signature`, {
    role: 'maker',
    signature: a.signature,
    permitSignature: a.permitSignature,
  });
  assert.equal(crossed.status, 400, 'one offer accepted another offer\u2019s signature');
});

test('two service instances sharing a store do not verify each other\u2019s messages', async () => {
  const root = currentRoot;
  const first = await createOffer(port, { sellAmount: '3' });
  const second = await createOffer(port, { sellAmount: '4' });

  const peerPort = await freePort();
  const peer = await startService({ root, port: peerPort, orderbook: orderbook.url });
  try {
    const loads = [];
    for (let round = 0; round < 12; round += 1) {
      loads.push(signAs(peerPort, first.id));
      loads.push(signAs(peerPort, second.id));
      loads.push(signAs(port, first.id));
      loads.push(signAs(port, second.id));
    }
    const results = await Promise.all(loads);
    assert.equal(results.length, 48);
    assert.ok(
      results.every((res) => res.signature),
      'a shared scratch file made one instance verify another instance\u2019s message',
    );
    assert.equal(offerRecord(root, first.id).signatures.maker, results[0].signature);
    assert.equal(offerRecord(root, second.id).signatures.maker, results[1].signature);
  } finally {
    await peer.stop();
  }
});

test('an offer survives a service restart with its signatures and identity', async () => {
  const root = currentRoot;
  const offer = await createOffer(port, { sellAmount: '5' });
  const signed = await signAs(port, offer.id);

  await service.stop();
  service = await startService({ root, port, orderbook: orderbook.url });
  const after = await call(port, 'GET', `/offers/${offer.id}`);
  assert.equal(after.status, 200);
  assert.equal(after.body.offerId, offer.offerId, 'the offer changed identity across a restart');
  assert.equal(after.body.makerSigned, true, 'the maker signature did not survive the restart');
  assert.equal(offerRecord(root, offer.id).signatures.maker, signed.signature);
});

test('accepting twice is refused and the first order is not duplicated', async () => {
  const root = currentRoot;
  const offer = await createOffer(port, { sellAmount: '6' });
  await signAs(port, offer.id);
  const taker = await signAs(port, offer.id, 'taker');

  const first = await call(port, 'POST', `/offers/${offer.id}/accept`, taker);
  assert.equal(first.status, 202, JSON.stringify(first.body));
  assert.ok(first.body.orderUid, 'accept did not return an order');

  const second = await call(port, 'POST', `/offers/${offer.id}/accept`, taker);
  assert.equal(second.status, 409, 'a duplicate acceptance was relayed');
  assert.equal(second.body.orderUid, first.body.orderUid);
  assert.equal(offerRecord(root, offer.id).orderUid, first.body.orderUid);
  assert.equal(orderbook.state.posts, 1, 'the order was posted more than once');
});

test('two simultaneous acceptances relay and post once', async () => {
  const root = currentRoot;
  const offer = await createOffer(port, { sellAmount: '6' });
  await signAs(port, offer.id);
  const taker = await signAs(port, offer.id, 'taker');

  // Fired together, with no await between them: whatever the handler yields on, the second request
  // must not start a second relay or post a second order.
  const [first, second] = await Promise.all([
    call(port, 'POST', `/offers/${offer.id}/accept`, taker),
    call(port, 'POST', `/offers/${offer.id}/accept`, taker),
  ]);
  const accepted = [first, second].filter((res) => res.status === 202);
  const refused = [first, second].filter((res) => res.status === 409);
  assert.equal(accepted.length, 1, `expected one acceptance, got ${first.status} and ${second.status}`);
  assert.equal(refused.length, 1, 'the second concurrent acceptance was not refused');
  assert.equal(orderbook.state.posts, 1, 'two concurrent acceptances posted the order twice');
  assert.equal(offerRecord(root, offer.id).orderUid, accepted[0].body.orderUid);
});

test('a failure after funding reports recovery, and a retry converges', async () => {
  const root = currentRoot;
  const offer = await createOffer(port, { sellAmount: '7' });
  await signAs(port, offer.id);
  const taker = await signAs(port, offer.id, 'taker');

  orderbook.state.rejectOrders = true;
  const failed = await call(port, 'POST', `/offers/${offer.id}/accept`, taker);
  assert.equal(failed.status, 502, JSON.stringify(failed.body));
  assert.equal(failed.body.status, 'recovery_available');

  const status = await call(port, 'GET', `/offers/${offer.id}/status`);
  assert.equal(status.body.status, 'recovery_available', 'a funded-only failure was reported as settled');

  // The party can still get its money out of the Shed while the offer is stuck.
  const withdraw = await call(port, 'GET', `/offers/${offer.id}/withdraw?address=${MAKER}`);
  assert.equal(withdraw.status, 200);
  assert.equal(withdraw.body.empty, undefined);

  // The retry must not fail on the already-relayed Shed, and must not lose the offer.
  orderbook.state.rejectOrders = false;
  const retried = await call(port, 'POST', `/offers/${offer.id}/accept`, taker);
  assert.equal(retried.status, 202, `the retry did not converge: ${JSON.stringify(retried.body)}`);
  assert.ok(retried.body.orderUid);
  assert.equal(offerRecord(root, offer.id).acceptance.phase, 'settling');
});

test('an offer past its deadline reports expired, not open', async () => {
  const offer = await createOffer(port, { sellAmount: '8', validFor: 1 });
  await sleep(1200);

  const status = await call(port, 'GET', `/offers/${offer.id}/status`);
  assert.equal(status.body.status, 'expired', 'an expired offer still invites a signature');
});

test('cancellation is maker-only, must be signed, and outranks settlement', async () => {
  const root = currentRoot;
  const offer = await createOffer(port, { sellAmount: '9' });
  const record = offerRecord(root, offer.id);

  const refused = await call(port, 'GET', `/offers/${offer.id}/cancel?address=${TAKER}`);
  assert.equal(refused.status, 403);

  const unsigned = await call(port, 'POST', `/offers/${offer.id}/cancel`, {
    address: MAKER,
    signature: `0x${'11'.repeat(65)}`,
  });
  assert.equal(unsigned.status, 400, 'an unsigned cancellation was relayed');

  const planned = await call(port, 'GET', `/offers/${offer.id}/cancel?address=${MAKER}`);
  assert.equal(planned.status, 200);
  assert.equal(planned.body.typedData.marker, markerOf(record.computed.makerCancellation.bundleTypedData));

  const cancelled = await call(port, 'POST', `/offers/${offer.id}/cancel`, {
    address: MAKER,
    signature: signatureOver(record.computed.makerCancellation.bundleTypedData),
  });
  assert.equal(cancelled.status, 200, JSON.stringify(cancelled.body));
  assert.equal(cancelled.body.status, 'cancelled');

  setChain(root, { offerState: { [offer.offerId]: 2 } });
  const status = await call(port, 'GET', `/offers/${offer.id}/status`);
  assert.equal(status.body.status, 'cancelled');
});

test('settled requires a fulfilled order, a successful receipt, and consumed wrapper state', async () => {
  const root = currentRoot;
  const offer = await createOffer(port, { sellAmount: '10' });
  await signAs(port, offer.id);
  const taker = await signAs(port, offer.id, 'taker');

  const accepted = await call(port, 'POST', `/offers/${offer.id}/accept`, taker);
  const orderUid = accepted.body.orderUid;

  // The order is filled, but the wrapper has not consumed the offer and there is no receipt yet.
  orderbook.state.orders.set(orderUid, 'fulfilled');
  const thin = await call(port, 'GET', `/offers/${offer.id}/status`);
  assert.equal(thin.body.status, 'settling', 'a filled order alone was reported as settled');
  assert.equal(thin.body.evidence.receiptSucceeded, null);

  orderbook.state.trades.set(orderUid, '0xtransaction');
  const noReceipt = await call(port, 'GET', `/offers/${offer.id}/status`);
  assert.equal(noReceipt.body.status, 'settling', 'a missing receipt was reported as settled');

  setChain(root, { receipts: { '0xtransaction': successfulReceipt } });
  const noWrapper = await call(port, 'GET', `/offers/${offer.id}/status`);
  assert.equal(noWrapper.body.status, 'settling', 'an unconsumed offer was reported as settled');

  setChain(root, settledChain(offer.offerId));
  const settled = await call(port, 'GET', `/offers/${offer.id}/status`);
  assert.equal(settled.body.status, 'settled');
  assert.equal(settled.body.settlementTx, '0xtransaction');
  assert.equal(settled.body.evidence.receiptSucceeded, true);
});

// --- runner ---------------------------------------------------------------------------------------

let port = null;
let service = null;
let orderbook = null;

async function main() {
  let failed = 0;
  for (const { name, fn } of tests) {
    currentRoot = makeRoot();
    orderbook = await startOrderbook();
    port = await freePort();
    service = await startService({ root: currentRoot, port, orderbook: orderbook.url });
    try {
      await fn();
      console.log(`PASS  ${name}`);
    } catch (err) {
      failed += 1;
      console.log(`FAIL  ${name}`);
      console.log(`      ${err.message.split('\n').join('\n      ')}`);
    } finally {
      await service.stop();
      await orderbook.close();
      fs.rmSync(currentRoot, { recursive: true, force: true });
    }
  }

  for (const child of children) child.kill('SIGKILL');
  console.log(`\n${tests.length - failed}/${tests.length} lifecycle tests passed`);
  process.exit(failed === 0 ? 0 : 1);
}

await main();
