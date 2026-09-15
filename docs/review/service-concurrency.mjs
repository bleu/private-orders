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
