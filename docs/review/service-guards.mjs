#!/usr/bin/env node
// Route guards that are not about interleaving, driven through the real request handler.
//
// `service-lifecycle.mjs` covers the flow and `service-concurrency.mjs` covers two requests in flight.
// This is for the refusals whose whole value is the sentence: a route that used to answer with
// something the chain would reject, where the fix is to answer with an explanation instead.
//
//   node docs/review/service-guards.mjs

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { chainState, loadService } from './service-harness.mjs';

const OWNER = (n) => `0x${String(n).repeat(40)}`;

function fixture({ cancellationDeadline }) {
  const root = fs.mkdtempSync('/tmp/private-orders-guards.');
  fs.mkdirSync(path.join(root, 'out-json', 'link'), { recursive: true });
  fs.writeFileSync(
    path.join(root, 'out-json', 'link', 'offer.json'),
    JSON.stringify({
      id: 'offer',
      computed: {
        maker: OWNER(1),
        validTo: Math.floor(Date.now() / 1000) + 3600,
        makerCancellation: {
          owner: OWNER(1),
          deadline: cancellationDeadline,
          bundleTypedData: { marker: 'c'.repeat(64) },
          digest: `0x${'8'.repeat(64)}`,
        },
        makerBundle: { owner: OWNER(1), shed: OWNER(3), sellAmount: '100' },
        takerBundle: { owner: OWNER(2), shed: OWNER(4), sellAmount: '100' },
      },
      request: { taker: OWNER(2) },
      signatures: {},
      permits: {},
    }),
  );
  return root;
}

const tests = [];
const test = (name, fn) => tests.push({ name, fn });

test('a cancellation window that has closed is refused with the sentence that says where the tokens are', async () => {
  const root = fixture({ cancellationDeadline: Math.floor(Date.now() / 1000) - 60 });
  const service = await loadService({ root, state: chainState() });

  const asked = await service.open('GET', `/offers/offer/cancel?address=${OWNER(1)}`);
  assert.equal(asked.status, 409, 'a closed window still returned a plan the Shed will refuse');
  assert.match(asked.body.error, /cancellation window/);
  assert.match(asked.body.error, /Shed/, 'the refusal does not say where the tokens are');

  const posted = await service.open('POST', '/offers/offer/cancel');
  const postedResult = await posted.deliver({ address: OWNER(1), signature: `0x${'11'.repeat(65)}` });
  assert.equal(postedResult.status, 409, 'a closed window still accepted a cancellation signature');
  fs.rmSync(root, { recursive: true, force: true });
});

test('a cancellation window that is still open is not refused', async () => {
  const root = fixture({ cancellationDeadline: Math.floor(Date.now() / 1000) + 3600 });
  const service = await loadService({ root, state: chainState() });
  const asked = await service.open('GET', `/offers/offer/cancel?address=${OWNER(1)}`);
  assert.equal(asked.status, 200, JSON.stringify(asked.body));
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
console.log(`\n${tests.length - failed}/${tests.length} route guard checks passed`);
process.exit(failed === 0 ? 0 : 1);
