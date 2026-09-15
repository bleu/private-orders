#!/usr/bin/env node
// Interleaving tests for the link service, driven through its real request handler.
//
// `service-lifecycle.mjs` fires requests with `fetch`, and Node answers those one at a time — so two
// handlers never overlap and a lost update between them cannot be reproduced. This drives the same
// handler through `service-harness.mjs`, which enters two requests and delivers their bodies
// afterwards, which is what two browser tabs or two API clients produce for real.
//
// Only routes with an `await` between loading an offer and writing it back can lose an update. That is
// the signature route (`await readBody`) and not the withdrawal route, which runs to completion inside
// one turn of the event loop — checked by removing that route's guards and watching this file still
// pass.
//
//   node docs/review/service-concurrency.mjs

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { chainState, loadService } from './service-harness.mjs';
import { signatureOver } from './fixtures.mjs';

const OWNER = (n) => `0x${String(n).repeat(40)}`;
const SHED = (n) => `0x${String(n + 2).repeat(40)}`;
const TOKEN = (n) => `0x${String(n + 4).repeat(40)}`;
const SIG = `0x${'11'.repeat(65)}`;

const side = (n) => ({
  owner: OWNER(n),
  shed: SHED(n),
  sellToken: TOKEN(n),
  sellAmount: '100',
  nonce: `0x${String(n).repeat(64)}`,
  deadline: Math.floor(Date.now() / 1000) + 3600,
  permitKind: 'none',
  permitTypedDataAvailable: false,
  digest: `0x${String(n).repeat(64)}`,
  permitDigest: `0x${String(n).repeat(64)}`,
  bundleTypedData: {},
  permitTypedData: null,
});

function makeRoot() {
  const root = fs.mkdtempSync('/tmp/private-orders-concurrency.');
  fs.mkdirSync(path.join(root, 'out-json', 'link'), { recursive: true });
  const offer = {
    id: 'offer',
    computed: {
      wrapper: `0x${'f'.repeat(40)}`,
      wrapperData: '0x',
      offerId: `0x${'3'.repeat(64)}`,
      validTo: Math.floor(Date.now() / 1000) + 3600,
      maker: OWNER(1),
      makerCancellation: {
        owner: OWNER(1),
        shed: SHED(1),
        nonce: `0x${'9'.repeat(64)}`,
        deadline: Math.floor(Date.now() / 1000) + 3600,
        bundleTypedData: { marker: 'c'.repeat(64) },
        digest: `0x${'8'.repeat(64)}`,
      },
      makerBundle: side(1),
      takerBundle: side(2),
      takerOrder: {},
    },
    request: { taker: OWNER(2) },
    signatures: {},
    permits: {},
  };
  fs.writeFileSync(path.join(root, 'out-json', 'link', 'offer.json'), JSON.stringify(offer, null, 2));
  return { root, offer };
}

const record = (root) => JSON.parse(fs.readFileSync(path.join(root, 'out-json', 'link', 'offer.json'), 'utf8'));

const tests = [];
const test = (name, fn) => tests.push({ name, fn });
let id = 0;

async function fixture({ withdrawPlan } = {}) {
  const { root, offer } = makeRoot();
  const service = await loadService({
    root,
    state: chainState({ balances: { [OWNER(1)]: '100', [OWNER(2)]: '100' } }),
  });
  if (withdrawPlan === 'held') {
    // A non-empty plan for both roles, without running the withdrawal script.
    service.api.saveOffer({ ...offer, withdrawals: { maker: { empty: false, shed: SHED(1) } } });
  }
  return { root, service, offer };
}

test('two parties signing at once both keep their signature', async () => {
  const { root, service } = await fixture();
  id += 1;
  // Entered together: both handlers have loaded the offer and are waiting for their body.
  const maker = await service.open('POST', '/offers/offer/signature');
  const taker = await service.open('POST', '/offers/offer/signature');
  const takerResult = await taker.deliver({ role: 'taker', signature: SIG });
  const makerResult = await maker.deliver({ role: 'maker', signature: SIG });

  assert.equal(makerResult.status, 200, JSON.stringify(makerResult.body));
  assert.equal(takerResult.status, 200, JSON.stringify(takerResult.body));
  assert.deepEqual(
    Object.keys(record(root).signatures).sort(),
    ['maker', 'taker'],
    'one party was told its signature was saved and the other request wrote it away',
  );
  fs.rmSync(root, { recursive: true, force: true });
});

// The signature route was the first writer found to lose an update. It was not the only one: the
// cancellation and acceptance routes each waited for a request body (and, for acceptance, for the
// orderbook) and then saved the snapshot they had loaded when the request arrived. Both are
// reachable in the ordinary two-tab flow this design creates — one party signs while the other
// cancels or accepts — so both are checked here, not just repaired in the source.

test('a cancellation that overlaps a signature does not write the signature away', async () => {
  const { root, service } = await fixture();
  const offer = record(root);
  const maker = await service.open('POST', '/offers/offer/signature');
  const cancel = await service.open('POST', '/offers/offer/cancel');

  const signed = await maker.deliver({ role: 'maker', signature: SIG });
  const cancelled = await cancel.deliver({
    address: OWNER(1),
    signature: signatureOver(offer.computed.makerCancellation.bundleTypedData),
  });

  assert.equal(signed.status, 200, JSON.stringify(signed.body));
  assert.equal(cancelled.status, 200, JSON.stringify(cancelled.body));
  assert.equal(
    record(root).signatures.maker,
    SIG,
    'the cancellation was relayed but its save erased a signature that had already been accepted',
  );
  assert.ok(record(root).cancelledAt, 'the cancellation was not recorded');
  fs.rmSync(root, { recursive: true, force: true });
});

test('an acceptance that overlaps a signature does not restore the older record', async () => {
  const { root, service } = await fixture({ withdrawPlan: 'held' });
  const taker = await service.open('POST', '/offers/offer/accept');
  const maker = await service.open('POST', '/offers/offer/signature');

  const signed = await maker.deliver({ role: 'maker', signature: SIG });
  const accepted = await taker.deliver({ address: OWNER(2), signature: SIG });

  assert.equal(signed.status, 200, JSON.stringify(signed.body));
  assert.ok(accepted.status < 300 || accepted.status === 502, JSON.stringify(accepted.body));
  const stored = record(root);
  assert.equal(
    stored.signatures.maker,
    SIG,
    'the acceptance saved the record it loaded before posting the order, losing a signature written since',
  );
  assert.ok(
    stored.withdrawals?.maker,
    'the acceptance saved the record it loaded before posting the order, losing a withdrawal plan written since',
  );
  fs.rmSync(root, { recursive: true, force: true });
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
console.log(`\n${tests.length - failed}/${tests.length} concurrency checks passed`);
process.exit(failed === 0 ? 0 : 1);
