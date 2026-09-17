#!/usr/bin/env node
// Hygiene checks for the unauthenticated surface: the routes that need no signature, no wallet,
// and no chain to answer a request.
//
//   * the dev endpoints are a signing and broadcast oracle, so they are off unless enabled
//   * a 500 discloses the reason, not the command line and the child's stderr
//   * the offer create route has a window, because it takes no signature and runs a forge script
//   * a page value cannot close the script block it is embedded in
//   * the sub-solver caps a request body and logs a sample of it, and listens on loopback
//   * the faucet funds an address once
//
// The first three drive the real request handler through the harness; the last three spawn the
// real scripts and talk to them over HTTP.
//
//   node docs/review/service-hygiene.mjs

import assert from 'node:assert/strict';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';

import { freePort, sleep } from './fixtures.mjs';
import { chainState, loadService } from './service-harness.mjs';

const DEV_ADDRESS = '0x2ed529d9214665c8f2f8e45695d0d5615becfde1';
const DEV_KEY = '0x59c6995e998f97a5a0044966f098545901ffd4e5ca34431b3e537bd75162a323';

const tests = [];
const test = (name, fn) => tests.push({ name, fn });

/// Spawn a script with the environment a test needs, wait until it listens, and kill it after.
async function withScript(file, env, fn) {
  const port = await freePort();
  const logFile = fs.mkdtempSync(path.join(os.tmpdir(), 'private-orders-hygiene.')).concat('out.log');
  const child = spawn(process.execPath, [file], {
    env: { ...process.env, PORT: String(port), ...env },
    stdio: ['ignore', fs.openSync(logFile, 'w'), fs.openSync(logFile, 'w')],
  });
  const base = `http://127.0.0.1:${port}`;
  try {
    await until(() =>
      fetch(base).then((r) => r.status < 500).catch(() => false),
    );
    await fn(base, logFile, port);
  } finally {
    child.kill();
    await sleep(50);
  }
}

const until = async (probe, tries = 100) => {
  for (let i = 0; i < tries; i++) {
    if (await probe()) return;
    await sleep(50);
  }
  throw new Error('did not become ready in time');
};

/// The host's non-loopback IPv4, when it has one. A connection to it is how a test proves a
/// listener is on loopback only; without such an interface the proof is not possible, so the
/// check is skipped rather than guessed.
const externalIp = () => {
  for (const list of Object.values(os.networkInterfaces())) {
    for (const entry of list ?? []) {
      if (entry.family === 'IPv4' && !entry.internal) return entry.address;
    }
  }
  return null;
};

const refused = (host, port) =>
  new Promise((resolve) => {
    const socket = net.connect({ host, port });
    socket.once('connect', () => {
      socket.destroy();
      resolve(false);
    });
    socket.once('error', () => resolve(true));
  });

test('the dev endpoints are off while development keys are set but not enabled', async () => {
  process.env.PRIVATE_TRADE_DEV_KEYS = `${DEV_ADDRESS}=${DEV_KEY}`;
  delete process.env.DEV_ENDPOINTS;
  try {
    const root = fs.mkdtempSync('/tmp/private-orders-hygiene.');
    fs.mkdirSync(path.join(root, 'out-json', 'link'), { recursive: true });
    const service = await loadService({ root, state: chainState() });

    const sign = await service.open('POST', '/dev/sign');
    const signed = await sign.deliver({ address: DEV_ADDRESS, message: 'hi' });
    assert.equal(signed.status, 404, 'keys set without the flag still signed');

    const send = await service.open('POST', '/dev/send');
    const sent = await send.deliver({
      from: DEV_ADDRESS,
      to: '0x00000000000000000000000000000000000000f0',
      data: '0x',
    });
    assert.equal(sent.status, 404, 'keys set without the flag still broadcast');
  } finally {
    delete process.env.PRIVATE_TRADE_DEV_KEYS;
  }
});

test('the dev endpoints answer only when the flag is set as well', async () => {
  process.env.PRIVATE_TRADE_DEV_KEYS = `${DEV_ADDRESS}=${DEV_KEY}`;
  process.env.DEV_ENDPOINTS = '1';
  try {
    const root = fs.mkdtempSync('/tmp/private-orders-hygiene.');
    fs.mkdirSync(path.join(root, 'out-json', 'link'), { recursive: true });
    const service = await loadService({ root, state: chainState() });

    const sign = await service.open('POST', '/dev/sign');
    const signed = await sign.deliver({ address: DEV_ADDRESS, message: 'hi' });
    assert.equal(signed.status, 200, 'the flag is set and the key is known, so it signs');

    const send = await service.open('POST', '/dev/send');
    const sent = await send.deliver({
      from: DEV_ADDRESS,
      to: '0x00000000000000000000000000000000000000f0',
      data: '0x095ea7b3',
    });
    assert.notEqual(sent.status, 404, 'the flag is set and the key is known, so it does not 404');
  } finally {
    delete process.env.PRIVATE_TRADE_DEV_KEYS;
    delete process.env.DEV_ENDPOINTS;
  }
});

test('a 500 discloses the reason, not the command line and the child stderr', async () => {
  const root = fs.mkdtempSync('/tmp/private-orders-hygiene.');
  fs.mkdirSync(path.join(root, 'out-json', 'link'), { recursive: true });
  const service = await loadService({
    root,
    state: chainState({
      forgeFail: { rpc: 'http://internal:8545', stderr: 'Error: RT-STDERR-MARKER at http://internal:8545' },
    }),
  });

  const opened = await service.open('POST', '/offers');
  const result = await opened.deliver({
    maker: '0x70997970c51812dc3a010c7d01b50e0d17dc79c8',
    taker: '0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc',
  });
  assert.equal(result.status, 500);
  const text = JSON.stringify(result.body);
  assert.doesNotMatch(text, /RT-STDERR-MARKER/, 'the child stderr reached the client');
  assert.doesNotMatch(text, /--rpc-url/, 'the command line reached the client');
  assert.doesNotMatch(text, /internal:8545/, 'the rpc endpoint reached the client');
  assert.doesNotMatch(text, /Command failed/, 'the invocation reached the client');
  assert.equal('stderr' in result.body, false, 'a raw stderr field is still returned');
  assert.match(result.body.error, /./, 'the client still gets a reason');
  fs.rmSync(root, { recursive: true, force: true });
});

test('the offer create route turns requests away past its window', async () => {
  process.env.OFFERS_PER_HOUR = '2';
  try {
    const root = fs.mkdtempSync('/tmp/private-orders-hygiene.');
    fs.mkdirSync(path.join(root, 'out-json', 'link'), { recursive: true });
    const service = await loadService({ root, state: chainState() });
    const body = {
      maker: '0x70997970c51812dc3a010c7d01b50e0d17dc79c8',
      taker: '0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc',
    };
    const results = [];
    for (let i = 0; i < 3; i++) {
      const opened = await service.open('POST', '/offers');
      results.push(await opened.deliver(body));
    }
    assert.equal(results[2].status, 429, 'the third request in the window was not refused');
    assert.match(results[2].body.error, /limit/);
    assert.notEqual(results[0].status, 429);
    assert.notEqual(results[1].status, 429);
  } finally {
    delete process.env.OFFERS_PER_HOUR;
  }
});

test('a closing script tag in a page value cannot end the block', async () => {
  const { renderCreate, render } = await import('../../link-service/page.mjs');
  const evil = {
    sellToken: 'USDC</script><script>document.title=\'RT-BREAKOUT\'</script>',
    buyToken: '<img src=x onerror="window.__pwned=1">',
  };
  const page = renderCreate({ devWallet: false, defaults: evil });
  assert.doesNotMatch(page, /<script>document\.title/, 'a value closed the block and opened a script');
  assert.doesNotMatch(page, /<img src=x/, 'a value became markup');
  assert.match(page, /\\u003c\/script>/, 'the closing tag is encoded, not present');

  const trade = render('abcdef0123456789abcdef0123456789', { devWallet: false });
  assert.match(trade, /const id = "abcdef0123456789abcdef0123456789"/);
});

test('the sub-solver refuses a body past its cap and logs a sample of a big one', async () => {
  const offersDir = fs.mkdtempSync('/tmp/private-orders-hygiene-offers.');
  const logFile = fs.mkdtempSync('/tmp/private-orders-hygiene.').concat('solve.log');
  await withScript(
    path.resolve(import.meta.dirname, '..', '..', 'subsolver', 'private-trade-solver.mjs'),
    { OFFERS_DIR: offersDir, SOLVE_LOG: logFile },
    async (base) => {
      const big = JSON.stringify({ id: 'big', orders: [], pad: 'x'.repeat(6e6) });
      const bigRes = await fetch(`${base}/`, { method: 'POST', body: big });
      assert.equal(bigRes.status, 413, 'a body past the cap was accepted');

      const orders = Array.from({ length: 500 }, (_, i) => ({
        uid: `0x${String(i).padStart(56, '0')}`,
        owner: '0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc',
        appData: `0x${(i % 256).toString(16).padStart(64, '0')}`,
        sellToken: '0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc',
        buyToken: '0x70997970c51812dc3a010c7d01b50e0d17dc79c8',
        sellAmount: '1',
        buyAmount: '1',
        fullSellAmount: '1',
        fullBuyAmount: '1',
        kind: 0,
        partiallyFillable: true,
      }));
      const smallRes = await fetch(`${base}/`, {
        method: 'POST',
        body: JSON.stringify({ id: 'auction', orders }),
      });
      assert.equal(smallRes.status, 200);
      assert.deepEqual(await smallRes.json(), { solutions: [] });

      await sleep(50);
      const lines = fs.readFileSync(logFile, 'utf8').trim().split('\n');
      const last = JSON.parse(lines.at(-1));
      assert.equal(last.orderCount, 500, 'the log does not say how many orders arrived');
      assert.equal(last.orders.length, 200, 'the log copied the whole order list');
      assert.ok(lines.at(-1).length < 100_000, 'one request wrote a log line over 100kb');
    },
  );
  fs.rmSync(offersDir, { recursive: true, force: true });
});

test('the sub-solver and the faucet listen on loopback by default', async () => {
  const external = externalIp();
  if (!external) return; // no non-loopback interface: the proof is not possible here

  const offersDir = fs.mkdtempSync('/tmp/private-orders-hygiene-offers.');
  await withScript(
    path.resolve(import.meta.dirname, '..', '..', 'subsolver', 'private-trade-solver.mjs'),
    { OFFERS_DIR: offersDir },
    async (base, logFile, port) => {
      assert.equal(await refused(external, port), true, 'the sub-solver answers on the host interface');
      assert.equal(await refused('127.0.0.1', port), false, 'the sub-solver is not on loopback at all');
    },
  );
  fs.rmSync(offersDir, { recursive: true, force: true });

  await withScript(
    path.resolve(import.meta.dirname, '..', '..', 'scripts', 'demo-faucet.mjs'),
    {
      DAI: '0x6b175474e89094c44da98b954eedeac495271d0f',
      USDC: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48',
      RPC: 'http://127.0.0.1:1',
      FUNDER_KEY: '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80',
    },
    async (base, logFile, port) => {
      assert.equal(await refused(external, port), true, 'the faucet answers on the host interface');
      assert.equal(await refused('127.0.0.1', port), false, 'the faucet is not on loopback at all');
    },
  );
});

test('the faucet funds an address once', async () => {
  await withScript(
    path.resolve(import.meta.dirname, '..', '..', 'scripts', 'demo-faucet.mjs'),
    {
      DAI: '0x6b175474e89094c44da98b954eedeac495271d0f',
      USDC: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48',
      RPC: 'http://127.0.0.1:1', // dead: the funding attempt fails, which is what the cap is about
      FUNDER_KEY: '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80',
    },
    async (base) => {
      const who = '0x70997970c51812dc3a010c7d01b50e0d17dc79c8';
      const first = await fetch(`${base}/?address=${who}`);
      assert.equal(first.status, 500, 'a dead chain funds nothing, so the first attempt reports a failure');
      assert.match(await first.text(), /Could not fund/);

      const second = await fetch(`${base}/?address=${who}`);
      assert.equal(second.status, 200);
      assert.match(await second.text(), /already funded/, 'a second attempt for the same address was not refused');
    },
  );
});

let failed = 0;
for (const { name, fn } of tests) {
  try {
    await fn();
    console.log(`ok    ${name}`);
  } catch (err) {
    failed += 1;
    console.error(`FAIL  ${name}`);
    console.error(err);
  }
}
if (failed) {
  console.error(`${failed} of ${tests.length} hygiene checks failed`);
  process.exit(1);
}
console.log(`all ${tests.length} hygiene checks passed`);
