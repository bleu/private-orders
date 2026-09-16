#!/usr/bin/env node
// The maker's cancellation against an acceptance that is already in flight.
//
// The acceptance validates, then relays, then publishes to the sub-solver feed, then waits on the
// orderbook, then records. A cancellation can land at any of those points, because cancelling is the
// right the maker keeps after publishing. Before this test existed, the acceptance wrote its terminal
// state from the snapshot it loaded when the request arrived: it republished the feed for a cancelled
// offer, recorded `settling` beside `cancelledAt`, and answered 202 for a trade that cannot happen.
// The wrapper still refused to settle it, so no money was at risk — the answer and the stale feed
// entry were the defects.
//
// Two windows are covered, and they need different machinery:
//   * before the relay — reachable by parking the request at its body read, as the concurrency tests do
//   * during the orderbook round trip — needs a delayed orderbook, so the harness can hold it there
//
//   node docs/review/service-cancellation-race.mjs

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { chainState, loadService } from './service-harness.mjs';

const MAKER = `0x${'aa'.repeat(20)}`;
const TAKER = `0x${'bb'.repeat(20)}`;
const DAI = `0x${'cc'.repeat(20)}`;
const WRAPPER = `0x${'f0'.repeat(20)}`;
const OFFER_ID = `0x${'ab'.repeat(32)}`;
const SIG = (c) => `0x${c.repeat(65)}`;
const MAKER_SIG = SIG('11');
const TAKER_SIG = SIG('22');
const CANCEL_SIG = SIG('33');
const NOW = Math.floor(Date.now() / 1000);
const LATER = NOW + 86400;

const tests = [];
const test = (name, fn) => tests.push({ name, fn });

/// A store and a feed directory, with one live offer. Each test gets its own.
function fixture({ orderbookDelayMs = 0 } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'private-orders-cancel-race.'));
  const store = path.join(root, 'out-json', 'link');
  fs.mkdirSync(store, { recursive: true });

  const bundle = (owner) => ({
    owner,
    bundleTypedData: { marker: 'bundle', owner },
    digest: OFFER_ID,
    sellToken: DAI,
    sellAmount: '1000000',
    shed: `0x${'dd'.repeat(20)}`,
    nonce: OFFER_ID,
    permitKind: 'none',
  });
  fs.writeFileSync(
    path.join(store, 'test-offer.json'),
    JSON.stringify(
      {
        id: 'test-offer',
        request: { maker: MAKER, taker: TAKER, sellToken: DAI },
        signatures: { maker: MAKER_SIG, taker: TAKER_SIG },
        permits: {},
        computed: {
          offerId: OFFER_ID,
          maker: MAKER,
          taker: TAKER,
          wrapper: WRAPPER,
          wrapperData: '0x',
          validTo: LATER,
          makerBundle: bundle(MAKER),
          takerBundle: bundle(TAKER),
          takerOrder: { sellToken: DAI, buyToken: DAI },
          makerCancellation: {
            owner: MAKER,
            digest: OFFER_ID,
            bundleTypedData: { marker: 'cancel', owner: MAKER },
            deadline: LATER,
          },
        },
      },
      null,
      2,
    ),
  );

  const record = () => JSON.parse(fs.readFileSync(path.join(store, 'test-offer.json'), 'utf8'));
  const feed = path.join(root, 'out-json', 'sub-solver-offers', 'test-offer.json');
  const state = chainState({
    wrapperState: '0',
    orderbookDelayMs,
    balances: { [MAKER]: '1000000000', [TAKER]: '1000000000', [DAI]: '1000000000' },
    signatures: { [MAKER]: CANCEL_SIG, [TAKER]: TAKER_SIG },
  });
  return { root, state, record, feed };
}

const clean = (root) => fs.rmSync(root, { recursive: true, force: true });

/// Wait for a condition the handler reaches on its own, so a test never has to guess a duration.
async function until(predicate, what, { tries = 400, every = 5 } = {}) {
  for (let i = 0; i < tries; i += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, every));
  }
  throw new Error(`timed out waiting for ${what}`);
}

test('a cancellation that lands before the relay stops the acceptance there', async () => {
  const { root, state, record, feed } = fixture();
  const { open, calls } = await loadService({ root, state });

  // Both requests in flight, each parked at its body read.
  const acceptReq = await open('POST', '/offers/test-offer/accept');
  const cancelReq = await open('POST', '/offers/test-offer/cancel');

  const cancel = await cancelReq.deliver({ address: MAKER, signature: CANCEL_SIG });
  assert.equal(cancel.status, 200, JSON.stringify(cancel.body));
  assert.ok(record().cancelledAt, 'the cancellation was not recorded');
  assert.ok(!fs.existsSync(feed), 'the cancellation did not remove the feed entry');
  const forgeCallsAfterCancel = calls.filter(([bin]) => bin === 'forge').length;

  const accept = await acceptReq.deliver({ taker: TAKER, signature: TAKER_SIG });

  assert.equal(accept.status, 409, `the acceptance answered as if the offer were live: ${JSON.stringify(accept.body)}`);
  assert.match(accept.body.error, /cancelled/);
  assert.equal(record().orderUid, undefined, 'the acceptance recorded an order uid for a cancelled offer');
  assert.notEqual(record().acceptance?.phase, 'settling', 'the acceptance recorded itself as settling');
  assert.ok(!fs.existsSync(feed), 'the acceptance put the cancelled offer back in the sub-solver feed');
  assert.equal(
    calls.filter(([bin]) => bin === 'forge').length,
    forgeCallsAfterCancel,
    'the acceptance relayed on chain for an offer that was already cancelled',
  );
  clean(root);
});

test('a cancellation that lands during the orderbook round trip stops the acceptance there', async () => {
  const { root, state, record, feed } = fixture({ orderbookDelayMs: 400 });
  const { open } = await loadService({ root, state });

  const acceptReq = await open('POST', '/offers/test-offer/accept');
  const accepting = acceptReq.deliver({ taker: TAKER, signature: TAKER_SIG });

  // The feed entry appears immediately before the orderbook call, so seeing it means the acceptance is
  // inside the delayed round trip — the window this test is about.
  await until(() => fs.existsSync(feed), 'the acceptance to publish the feed entry');

  const cancelReq = await open('POST', '/offers/test-offer/cancel');
  const cancel = await cancelReq.deliver({ address: MAKER, signature: CANCEL_SIG });
  assert.equal(cancel.status, 200, JSON.stringify(cancel.body));

  const accept = await accepting;

  assert.equal(accept.status, 409, `the acceptance answered as if the offer were live: ${JSON.stringify(accept.body)}`);
  assert.match(accept.body.error, /cancelled/);
  // The order did reach the book, so the uid is reported rather than discarded — it is the only way to
  // find a dead order the sub-solver may still hold.
  assert.ok(accept.body.orderUid, 'the 409 did not report the order uid that was posted');
  assert.equal(record().orderUid, undefined, 'the acceptance recorded the order uid for a cancelled offer');
  assert.notEqual(record().acceptance?.phase, 'settling', 'the acceptance recorded itself as settling');
  assert.ok(record().cancelledAt, 'the cancellation was lost');
  assert.ok(!fs.existsSync(feed), 'the acceptance left the cancelled offer in the sub-solver feed');
  clean(root);
});

test('a signature for a cancelled offer is refused instead of recorded', async () => {
  const { root, state, record, feed } = fixture();
  const { open } = await loadService({ root, state });

  const cancelReq = await open('POST', '/offers/test-offer/cancel');
  assert.equal((await cancelReq.deliver({ address: MAKER, signature: CANCEL_SIG })).status, 200);

  const sign = await open('POST', '/offers/test-offer/signature');
  const signed = await sign.deliver({ role: 'taker', signature: TAKER_SIG });

  assert.equal(signed.status, 409, `a dead offer accepted a signature: ${JSON.stringify(signed.body)}`);
  assert.match(signed.body.error, /cancelled/);
  assert.ok(!fs.existsSync(feed), 'the feed entry came back');
  assert.equal(record().cancelledAt !== undefined, true);
  clean(root);
});

let failed = 0;
for (const { name, fn } of tests) {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (err) {
    failed += 1;
    console.log(`FAIL  ${name}`);
    console.log(`      ${err.message.split('\n').join('\n      ')}`);
  }
}
console.log(`\n${tests.length - failed}/${tests.length} cancellation race checks passed`);
process.exit(failed === 0 ? 0 : 1);
