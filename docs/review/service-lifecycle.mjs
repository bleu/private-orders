#!/usr/bin/env node
// Lifecycle tests for the link service, driven through its real HTTP surface.
//
// The service's job is bookkeeping around a chain it does not control, so the behaviour worth
// pinning — interleaving, restart, retries, duplicate acceptance, cancellation, expiry, recovery —
// is not contract behaviour and cannot be tested in Solidity. Testing it against a real chain would
// make the test slow and the failure ambiguous: "recovery failed" and "anvil was not up" would look
// the same.
//
// So this file runs the real `link-service/server.mjs`, over real HTTP, against the fixtures in
// `fixtures.mjs`: a fake `forge`/`cast` on PATH and a fake orderbook. Everything else is the service
// as deployed — its router, its offer store, its relay retries.
//
//   node docs/review/service-lifecycle.mjs

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

import {
  MAKER,
  TAKER,
  call,
  createOffer,
  freePort,
  killAll,
  makeRoot,
  markerOf,
  offerRecord,
  setChain,
  signatureOver,
  sleep,
  startOrderbook,
  startService,
} from './fixtures.mjs';

const tests = [];
const test = (name, fn) => tests.push({ name, fn });

let currentRoot = null;
let port = null;
let service = null;
let orderbook = null;

/// Both parties sign, in the order the flow requires: the maker's signature first, because accept
/// refuses to relay while a permit is missing.
async function signAs(servicePort, id, role = 'maker') {
  const record = offerRecord(currentRoot, id);
  const side = role === 'maker' ? record.computed.makerBundle : record.computed.takerBundle;
  const res = await call(servicePort, 'POST', `/offers/${record.id}/signature`, {
    role,
    signature: signatureOver(side.bundleTypedData),
    permitSignature: signatureOver(side.permitTypedData),
  });
  assert.equal(res.status, 200, `${role} signature rejected: ${JSON.stringify(res.body)}`);
  return { signature: signatureOver(side.bundleTypedData), permitSignature: signatureOver(side.permitTypedData) };
}

const settledChain = (offerId) => ({ offerState: { [offerId]: 1 } });
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
  assert.equal(offerRecord(root, first.id).signatures.maker, a.signature);
  assert.equal(offerRecord(root, second.id).signatures.maker, b.signature);

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

  killAll();
  console.log(`\n${tests.length - failed}/${tests.length} lifecycle tests passed`);
  process.exit(failed === 0 ? 0 : 1);
}

await main();