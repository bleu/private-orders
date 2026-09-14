import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import path from 'node:path';

const source = fs.readFileSync(new URL('../../link-service/server.mjs', import.meta.url), 'utf8');
const statusFn = source.slice(
  source.indexOf('async function status(offer)'),
  source.indexOf('/// What a party must do before signing.'),
);
const statusContext = {
  balanceOf: () => '0',
  settlementTx: async () => null,
  orderStatus: async () => ({ status: 'open' }),
};
vm.createContext(statusContext);
vm.runInContext(statusFn + '\nthis.run = status;', statusContext);
const result = await statusContext.run({
  orderUid: 'unfilled-order',
  computed: { sellToken: 'token', makerShed: 'shed' },
  makerBalanceAtAccept: '100',
});
assert.equal(result.status, 'settled');
assert.equal(result.settlementTx, null);
console.log('REPRODUCED: a withdrawn balance reports settled while the order remains open and has no transaction');

const relayFn = source.slice(source.indexOf('function relay(computed, signatures)'), source.indexOf('const PROBE_DOMAIN'));
const files = new Map([['/fixture/out-json/link-computed.json', JSON.stringify({ offerId: 'B' })]]);
let observed;
const relayContext = {
  RPC: 'mock-rpc',
  Buffer,
  relayReason: (value) => value,
  ROOT: '/fixture',
  path,
  process: { env: {} },
  CONFIG: { relayerKey: 'mock' },
  fs: { writeFileSync: (file, value) => files.set(file, value) },
  execFileSync: () => {
    observed = JSON.parse(files.get('/fixture/out-json/link-computed.json'));
    return Buffer.from('bundles relayed');
  },
};
vm.createContext(relayContext);
vm.runInContext(relayFn + '\nthis.run = relay;', relayContext);
relayContext.run({ offerId: 'A' }, { maker: 'maker-A', taker: 'taker-A' });
assert.equal(observed.offerId, 'B');
console.log('REPRODUCED: relaying offer A invokes Forge with the previously computed offer B');
