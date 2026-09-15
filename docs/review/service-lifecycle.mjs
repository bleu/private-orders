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
  DAI,
  MAKER,
  TAKER,
  USDC,
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

test('a refused acceptance does not wedge the offer', async () => {
  const root = currentRoot;
  const offer = await createOffer(port, { sellAmount: '6' });
  await signAs(port, offer.id);
  const taker = await signAs(port, offer.id, 'taker');

  // Every one of these returns before the work starts. If the in-flight lock is taken any earlier,
  // the offer reports "already in flight" for the rest of its life and nothing says why.
  const wrongTaker = await call(port, 'POST', `/offers/${offer.id}/accept`, {
    taker: '0x0000000000000000000000000000000000000001',
    ...taker,
  });
  assert.equal(wrongTaker.status, 403, JSON.stringify(wrongTaker.body));

  const shortSignature = await call(port, 'POST', `/offers/${offer.id}/accept`, { signature: '0x1234' });
  assert.equal(shortSignature.status, 400, JSON.stringify(shortSignature.body));

  const accepted = await call(port, 'POST', `/offers/${offer.id}/accept`, taker);
  assert.equal(accepted.status, 202, `the offer was wedged: ${JSON.stringify(accepted.body)}`);
  assert.ok(accepted.body.orderUid);
});

test('the relay is simulated before anything is broadcast', async () => {
  const root = currentRoot;
  const offer = await createOffer(port, { sellAmount: '6' });
  await signAs(port, offer.id);
  const taker = await signAs(port, offer.id, 'taker');

  const broadcasts = () =>
    Number(fs.existsSync(path.join(root, 'broadcasts')) ? fs.readFileSync(path.join(root, 'broadcasts'), 'utf8') : '0');

  // The dry run is the pass without `--broadcast`: forge applies the whole script against current
  // state and stops at the first call that would fail. Make only that pass fail.
  fs.writeFileSync(path.join(root, 'dry-run-fault'), '');
  const refused = await call(port, 'POST', `/offers/${offer.id}/accept`, taker);
  assert.equal(refused.status, 502, JSON.stringify(refused.body));
  assert.match(refused.body.error, /dry run failed on purpose/, JSON.stringify(refused.body));
  assert.equal(broadcasts(), 0, 'the relay was broadcast even though its simulation failed');
  assert.equal(orderbook.state.posts, 0, 'the order was posted after a failed simulation');
  assert.equal(offerRecord(root, offer.id).acceptance.phase, 'failed');

  // With the cause gone the same offer proceeds, and the broadcast pass is what runs.
  fs.rmSync(path.join(root, 'dry-run-fault'));
  const accepted = await call(port, 'POST', `/offers/${offer.id}/accept`, taker);
  assert.equal(accepted.status, 202, JSON.stringify(accepted.body));
  assert.equal(broadcasts(), 1, 'the relay was broadcast more than once');
});

test('an offer that cannot settle is refused before a signature is taken', async () => {
  const root = currentRoot;
  const offer = await createOffer(port, { sellAmount: '6' });

  // Not allowlisted as a solver: nothing can ever submit the settlement, and the party would only
  // discover it after two prompts and a failed relay.
  setChain(root, { unallowlisted: true });
  const refused = await signAs(port, offer.id).catch((err) => err);
  assert.ok(refused instanceof Error, 'a signature was taken for an offer that could never settle');
  assert.match(refused.message, /not allowlisted/, refused.message);

  // The role view says the same thing, so the page can say it before the button is pressed.
  const view = await call(port, 'GET', `/offers/${offer.id}/role?address=${MAKER}`);
  assert.equal(view.body.ready.ok, false);
  assert.ok(view.body.ready.problems.some((p) => /not allowlisted/.test(p)), JSON.stringify(view.body.ready.problems));
  assert.ok(view.body.ready.checks.length >= 4, 'the checks were not reported');

  // Clearing the cause lets the same offer proceed: nothing was consumed by the refusal.
  setChain(root, { unallowlisted: false });
  const accepted = await signAs(port, offer.id);
  assert.ok(accepted.signature);
});

test('a party with nothing to sell is told before signing, not after', async () => {
  const root = currentRoot;
  const offer = await createOffer(port, { sellAmount: '500000000000' });
  setChain(root, { tokens: { [USDC]: { symbol: 'USDC', decimals: 6, balances: {} } } });

  const view = await call(port, 'GET', `/offers/${offer.id}/role?address=${MAKER}`);
  assert.equal(view.body.ready.ok, false);
  assert.ok(
    view.body.ready.problems.some((p) => /must hold/.test(p)),
    JSON.stringify(view.body.ready.problems),
  );
});

test('a smart contract account funds by approval, not by a permit', async () => {
  const root = currentRoot;

  // A token permit is verified by `ecrecover` inside the token, so a contract account cannot produce
  // one. Offering the prompt would cost a signature and then fail on the allowance.
  //
  // Set before the offer is created: the service remembers an owner's kind per address, and the
  // create response already asks funding(), which asks this.
  setChain(root, { contracts: [MAKER] });
  const offer = await createOffer(port, { sellAmount: '6' });
  const view = await call(port, 'GET', `/offers/${offer.id}/role?address=${MAKER}`);
  assert.equal(view.body.owner.isContract, true);
  assert.equal(view.body.funding.mode, 'approve');
  assert.match(view.body.funding.reason, /smart contract account/);
  assert.match(view.body.funding.approve.data, /^0x095ea7b3/);

  // And its signature is checked by asking it, not by recovering: the fixture answers for exactly the
  // blob the test placed there, so a different blob is refused the way the account would refuse it.
  const blob = `0x${'ab'.repeat(65)}`;
  setChain(root, { signatures: { [MAKER]: blob } });
  const accepted = await call(port, 'POST', `/offers/${offer.id}/signature`, { role: 'maker', signature: blob });
  assert.equal(accepted.status, 200, JSON.stringify(accepted.body));

  const other = await call(port, 'POST', `/offers/${offer.id}/signature`, {
    role: 'maker',
    signature: `0x${'cd'.repeat(65)}`,
  });
  assert.equal(other.status, 400, JSON.stringify(other.body));
  assert.match(other.body.error, /not a signature of the authorisation/);
});

test('a contract account decides its own threshold, and its blob is taken as it comes', async () => {
  const root = currentRoot;
  setChain(root, { contracts: [MAKER], thresholds: { [MAKER]: 2 }, owners: { [MAKER]: [MAKER, TAKER] } });
  const offer = await createOffer(port, { sellAmount: '6' });

  // Gathering the owners is the account's job, not the service's: it is reported so the page can say
  // what to expect, and it must not block anything.
  const view = await call(port, 'GET', `/offers/${offer.id}/role?address=${MAKER}`);
  assert.equal(view.body.ready.account.threshold, 2);
  assert.equal(view.body.ready.account.owners, 2);
  assert.equal(view.body.ready.ok, true, JSON.stringify(view.body.ready.problems));

  // The blob a multi-owner account returns is longer than one signature, and it is opaque here: the
  // account is asked whether it is valid, and the service never inspects its shape.
  const blob = `0x${'ab'.repeat(130)}`;
  setChain(root, { signatures: { [MAKER]: blob } });
  const accepted = await call(port, 'POST', `/offers/${offer.id}/signature`, { role: 'maker', signature: blob });
  assert.equal(accepted.status, 200, JSON.stringify(accepted.body));
});

test('a funded side can retry even though its wallet is now empty', async () => {
  const root = currentRoot;
  const offer = await createOffer(port, { sellAmount: '6' });
  await signAs(port, offer.id);
  const taker = await signAs(port, offer.id, 'taker');

  // The taker holds exactly what it is selling, so funding leaves its wallet empty — which is the
  // state the retry has to cope with, and the one a wallet-balance check would refuse.
  setChain(root, { tokens: { [DAI]: { symbol: 'DAI', decimals: 18, balances: { [TAKER]: '100000000000000000000' } } } });

  // Funding succeeded, publishing or posting did not.
  orderbook.state.rejectOrders = true;
  const failed = await call(port, 'POST', `/offers/${offer.id}/accept`, taker);
  assert.equal(failed.status, 502, JSON.stringify(failed.body));
  assert.equal(failed.body.status, 'recovery_available');

  // The relay moved both sides' sell tokens into their Sheds, so the taker's wallet is empty. Asking
  // the wallet whether it can fund would refuse the retry for having already funded.
  const view = await call(port, 'GET', `/offers/${offer.id}/role?address=${TAKER}`);
  assert.equal(view.body.balance, '0', 'the fixture did not move the tokens, so this test proves nothing');
  assert.equal(view.body.ready.ok, true, JSON.stringify(view.body.ready.problems));
  assert.ok(
    view.body.ready.checks.some((entry) => /funded/.test(entry.name)),
    JSON.stringify(view.body.ready.checks.map((entry) => entry.name)),
  );

  orderbook.state.rejectOrders = false;
  const retried = await call(port, 'POST', `/offers/${offer.id}/accept`, taker);
  assert.equal(retried.status, 202, `recovery is advertised but blocked: ${JSON.stringify(retried.body)}`);
});

test('a contract owner may return a signature that is not 65 bytes', async () => {
  const root = currentRoot;
  // The Shed itself accepts whatever its owner's ERC-1271 implementation accepts, and a one-byte
  // signature is a shape a real account can use. The service must not impose a length on it.
  setChain(root, { contracts: [MAKER], signatures: { [MAKER]: '0x01' } });
  const offer = await createOffer(port, { sellAmount: '6' });

  const accepted = await call(port, 'POST', `/offers/${offer.id}/signature`, { role: 'maker', signature: '0x01' });
  assert.equal(accepted.status, 200, JSON.stringify(accepted.body));

  const wrong = await call(port, 'POST', `/offers/${offer.id}/signature`, { role: 'maker', signature: '0x02' });
  assert.equal(wrong.status, 400, 'the account accepted a signature it should have refused');
});

test('one unreadable chain read is not remembered as a fact', async () => {
  const root = currentRoot;
  // Written before anything reads this account, because the first read happens while the offer is
  // created — and a read that failed is the one that must not be remembered.
  fs.writeFileSync(path.join(root, 'code-fault'), '');
  const offer = await createOffer(port, { sellAmount: '6' });
  const during = await call(port, 'GET', `/offers/${offer.id}/role?address=${MAKER}`);
  assert.equal(during.body.owner.isContract, true, 'an unreadable read should answer conservatively');

  fs.rmSync(path.join(root, 'code-fault'));
  const after = await call(port, 'GET', `/offers/${offer.id}/role?address=${MAKER}`);
  assert.equal(after.body.owner.isContract, false, 'the failed read was cached as a fact about the account');
  assert.equal(after.body.funding.mode, 'permit', 'the owner is still being treated as a contract account');
});

test('an order that can no longer fill is reported expired, not settling', async () => {
  const root = currentRoot;
  const offer = await createOffer(port, { sellAmount: '6' });
  await signAs(port, offer.id);
  const taker = await signAs(port, offer.id, 'taker');
  const accepted = await call(port, 'POST', `/offers/${offer.id}/accept`, taker);
  assert.equal(accepted.status, 202, JSON.stringify(accepted.body));
  assert.equal((await call(port, 'GET', `/offers/${offer.id}/status`)).body.status, 'settling');

  // Wind the deadline past. The chain would refuse this order now, so "settling" would invite a wait
  // that can never end — and would hide the withdrawal the party may need.
  const record = offerRecord(root, offer.id);
  record.computed.validTo = Math.floor(Date.now() / 1000) - 60;
  fs.writeFileSync(path.join(root, 'out-json', 'link', `${offer.id}.json`), JSON.stringify(record, null, 2));

  const dead = await call(port, 'GET', `/offers/${offer.id}/status`);
  assert.equal(dead.body.status, 'expired', JSON.stringify(dead.body));
  assert.equal(dead.body.wrapperState, 'available');
  assert.equal(dead.body.orderUid, accepted.body.orderUid, 'the evidence should still be reported');

  // But a consumed offer past its deadline is a settlement in flight, not a dead one.
  setChain(root, { offerState: { [offer.offerId]: 1 } });
  const consumed = await call(port, 'GET', `/offers/${offer.id}/status`);
  assert.equal(consumed.body.status, 'settling', 'a consumed offer was reported as expired');
});

test('two parties signing at once both keep their signature', async () => {
  const root = currentRoot;
  const offer = await createOffer(port, { sellAmount: '6' });
  const record = offerRecord(root, offer.id);
  const bundleSig = (side) => ({
    signature: signatureOver(side.bundleTypedData),
    permitSignature: signatureOver(side.permitTypedData),
  });

  // Fired together, with no await between them. Each request loads the offer, awaits its body, then
  // writes the whole record back — so a whole-record write from one would silently drop the other,
  // while both were told 200.
  const [a, b] = await Promise.all([
    call(port, 'POST', `/offers/${offer.id}/signature`, { role: 'maker', ...bundleSig(record.computed.makerBundle) }),
    call(port, 'POST', `/offers/${offer.id}/signature`, { role: 'taker', ...bundleSig(record.computed.takerBundle) }),
  ]);
  assert.equal(a.status, 200, JSON.stringify(a.body));
  assert.equal(b.status, 200, JSON.stringify(b.body));
  assert.deepEqual(
    Object.keys(offerRecord(root, offer.id).signatures).sort(),
    ['maker', 'taker'],
    'one signature was written away by the other request',
  );
});

test('a standing allowance means the permit does not have to be signed again', async () => {
  const root = currentRoot;
  const offer = await createOffer(port, { sellAmount: '6' });
  const side = offerRecord(root, offer.id).computed.makerBundle;
  setChain(root, { allowances: { [USDC]: { [MAKER]: { [side.shed]: side.sellAmount } } } });

  const view = await call(port, 'GET', `/offers/${offer.id}/role?address=${MAKER}`);
  assert.equal(view.body.funding.mode, 'permit', 'this test needs a permit-capable side');
  assert.equal(view.body.allowance, side.sellAmount, 'the fixture did not record the allowance');

  // The authorisation alone. The relay skips a permit whose allowance is already in place, so asking
  // for the permit again would refuse a party who has done nothing wrong.
  const accepted = await call(port, 'POST', `/offers/${offer.id}/signature`, {
    role: 'maker',
    signature: signatureOver(side.bundleTypedData),
  });
  assert.equal(accepted.status, 200, JSON.stringify(accepted.body));

  // Without an allowance the permit is still required.
  const second = await createOffer(port, { sellAmount: '7' });
  const secondSide = offerRecord(root, second.id).computed.makerBundle;
  const refused = await call(port, 'POST', `/offers/${second.id}/signature`, {
    role: 'maker',
    signature: signatureOver(secondSide.bundleTypedData),
  });
  assert.equal(refused.status, 400, JSON.stringify(refused.body));
  assert.match(refused.body.error, /permitSignature is required/);
});

test('an attempt that stopped is reported as needing recovery, not as current', async () => {
  const root = currentRoot;
  const offer = await createOffer(port, { sellAmount: '6' });
  await signAs(port, offer.id);

  // What a crash or a restart leaves behind: a phase written by an attempt that is no longer running.
  const record = offerRecord(root, offer.id);
  record.acceptance = { attemptId: 'gone', startedAt: new Date().toISOString(), phase: 'funding' };
  fs.writeFileSync(path.join(root, 'out-json', 'link', `${offer.id}.json`), JSON.stringify(record, null, 2));

  const status = await call(port, 'GET', `/offers/${offer.id}/status`);
  assert.equal(status.body.status, 'recovery_available', JSON.stringify(status.body));
  assert.match(status.body.error, /stopped without finishing/);
});

test('a settled trade stays settled when the evidence stops being readable', async () => {
  const root = currentRoot;
  const offer = await createOffer(port, { sellAmount: '6' });
  await signAs(port, offer.id);
  const taker = await signAs(port, offer.id, 'taker');
  const accepted = await call(port, 'POST', `/offers/${offer.id}/accept`, taker);
  const orderUid = accepted.body.orderUid;

  orderbook.state.orders.set(orderUid, 'fulfilled');
  orderbook.state.trades.set(orderUid, '0xtx');
  setChain(root, { receipts: { '0xtx': { status: '0x1', blockNumber: '0x10' } }, offerState: { [offer.offerId]: 1 } });
  assert.equal((await call(port, 'GET', `/offers/${offer.id}/status`)).body.status, 'settled');

  // The orderbook forgets and the wrapper state stops reading. It still happened, and walking a settled
  // trade back to `settling` is a worse answer than a stale one.
  orderbook.state.orders.clear();
  setChain(root, { offerState: {} });
  const after = await call(port, 'GET', `/offers/${offer.id}/status`);
  assert.equal(after.body.status, 'settled', 'a settled trade was walked back to settling');
  assert.equal(after.body.terminal, true);
});

test('an order already on the book is adopted rather than lost', async () => {
  const root = currentRoot;
  const offer = await createOffer(port, { sellAmount: '6' });
  await signAs(port, offer.id);
  const taker = await signAs(port, offer.id, 'taker');

  // The first post reached the book and its response was lost, so the retry reports a duplicate. An
  // order nobody holds the identifier for cannot be waited on, withdrawn around, or cancelled.
  const uid = `0x${'ab'.repeat(56)}`;
  orderbook.state.duplicateUid = uid;
  const accepted = await call(port, 'POST', `/offers/${offer.id}/accept`, taker);
  assert.equal(accepted.status, 202, JSON.stringify(accepted.body));
  assert.equal(accepted.body.orderUid, uid, 'the order already on the book was not adopted');
  assert.equal(offerRecord(root, offer.id).orderUid, uid);
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