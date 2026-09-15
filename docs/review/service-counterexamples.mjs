import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import path from 'node:path';

const source = fs.readFileSync(new URL('../../link-service/server.mjs', import.meta.url), 'utf8');
const statusFn = source.slice(
  source.indexOf('async function status(offer)'),
  source.indexOf('/// What a party must do before signing.'),
);
let orderResult = { status: 'open' };
let txResult = null;
let receiptResult = null;
let chainState = 'available';
const statusContext = {
  settlementTx: async () => txResult,
  orderStatus: async () => orderResult,
  wrapperOfferState: () => chainState,
  transactionReceipt: () => receiptResult,
  receiptSucceeded: (receipt) => receipt?.status === '0x1',
  // `status` remembers a settlement once it has seen one, so the extraction needs the same write path
  // the service uses. Each call runs immediately and the record is kept in memory, which is what the
  // assertions below read.
  stored: null,
  loadOffer: () => statusContext.stored,
  saveOffer: (offer) => {
    statusContext.stored = offer;
  },
  serialize: (_id, run) => run(),
};
vm.createContext(statusContext);
vm.runInContext(statusFn + '\nthis.run = status;', statusContext);
const result = await statusContext.run({
  orderUid: 'unfilled-order',
  computed: { sellToken: 'token', makerShed: 'shed', validTo: String(Math.floor(Date.now() / 1000) + 3600) },
  makerBalanceAtAccept: '100',
});
assert.equal(result.status, 'settling');
assert.equal(result.settlementTx, null);
console.log('REGRESSION: a withdrawn balance cannot report settlement without order and receipt evidence');

orderResult = { status: 'fulfilled' };
txResult = '0xtransaction';
chainState = 'consumed';
const missingReceipt = await statusContext.run({
  orderUid: 'fulfilled-order',
  computed: { offerId: '0xoffer', validTo: String(Math.floor(Date.now() / 1000) + 3600) },
});
assert.equal(missingReceipt.status, 'settling');

receiptResult = { status: '0x1', blockNumber: '0x10' };
const proven = await statusContext.run({
  orderUid: 'fulfilled-order',
  computed: { offerId: '0xoffer', validTo: String(Math.floor(Date.now() / 1000) + 3600) },
});
assert.equal(proven.status, 'settled');
console.log('REGRESSION: fulfilled requires matching transaction, successful receipt, and consumed wrapper state');

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
  attemptFiles: () => '/fixture/attempt',
  fs: { writeFileSync: (file, value) => files.set(file, value), rmSync: () => {} },
  execFileSync: (_command, _args, options) => {
    observed = JSON.parse(files.get(options.env.LINK_COMPUTED_FILE));
    return Buffer.from('bundles relayed');
  },
};
vm.createContext(relayContext);
vm.runInContext(relayFn + '\nthis.run = relay;', relayContext);
relayContext.run({ offerId: 'A' }, { maker: 'maker-A', taker: 'taker-A' });
assert.equal(observed.offerId, 'A');
console.log('REGRESSION: relaying offer A materializes and invokes Forge with offer A');
