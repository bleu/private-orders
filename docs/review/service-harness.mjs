// A harness that drives the service's real request handler with controlled interleaving.
//
// The HTTP-level tests in `service-lifecycle.mjs` fire requests with `fetch`, and Node answers them one
// at a time: two `/signature` calls never overlap, so a lost-update defect between them cannot be
// reproduced that way. Several defects live exactly there — a handler loads the offer, awaits the
// request body, then writes the whole record back.
//
// So this loads the real `server.mjs` in a VM with the chain stubbed, captures the `http.createServer`
// callback, and lets a caller enter a request and deliver its body later. Two requests can therefore be
// in flight at once, which is the state a browser with two tabs, or two API clients, produces for real.
//
//   const service = await loadService({ root, state });
//   const maker = await service.open('POST', `/offers/${id}/signature`);
//   const taker = await service.open('POST', `/offers/${id}/signature`);
//   await taker.deliver(takerBody);   // both handlers are now in flight
//   await maker.deliver(makerBody);

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { EventEmitter } from 'node:events';

const ROOT = path.resolve(import.meta.dirname, '..', '..');
const SERVER = path.join(ROOT, 'link-service', 'server.mjs');

/// Default chain answers. A test overrides only the facts it is about.
export function chainState(patch = {}) {
  return {
    code: '0x',
    failCode: false,
    balances: {},
    allowance: '0',
    wrapperState: '0',
    orderState: 'open',
    authenticator: '0x00000000000000000000000000000000000000a1',
    solver: true,
    signatures: {},
    thresholds: {},
    owners: {},
    nonces: {},
    ...patch,
  };
}

export async function loadService({ root, state = chainState() }) {
  let handleRequest = null;
  const calls = [];

  const execFileSync = (bin, args, options = {}) => {
    calls.push([bin, ...args]);
    // The service passes each script its own file paths through the call's environment, not the
    // process's, so the stub has to read them from there.
    const env = options.env ?? process.env;
    if (bin === 'forge') {
      // The withdrawal plan is computed by a script, so the stub has to produce the file the service
      // reads back — otherwise only the paths that do not call `forge` can be driven here.
      if (String(args[1] ?? '').endsWith('Withdraw.s.sol') && env.WITHDRAW_REQUEST_FILE) {
        const request = JSON.parse(fs.readFileSync(env.WITHDRAW_REQUEST_FILE, 'utf8'));
        const plan = state.withdrawPlan === false
          ? { empty: true }
          : {
              shed: request.shed,
              owner: request.owner,
              targets: request.tokens,
              amounts: ['1'],
              nonce: `0x${'7'.repeat(64)}`,
              deadline: 4102444800,
              digest: `0x${'8'.repeat(64)}`,
              bundleTypedData: { marker: 'withdraw', owner: request.owner },
            };
        fs.writeFileSync(env.WITHDRAW_COMPUTED_FILE, JSON.stringify(plan));
      }
      return Buffer.from('bundles relayed');
    }
    if (bin !== 'cast') return Buffer.from('');
    if (args[0] === 'code') {
      if (state.failCode) throw new Error('the chain could not be read');
      return state.code;
    }
    const method = String(args[2] ?? '');
    if (method.startsWith('balanceOf')) {
      return String(state.balances[String(args[3]).toLowerCase()] ?? '0');
    }
    if (method.startsWith('allowance')) return state.allowance;
    if (method.startsWith('offerState')) return state.wrapperState;
    if (method.startsWith('nonces')) return state.nonces[args[3]] ? 'true' : 'false';
    if (method.startsWith('AUTHENTICATOR')) return state.authenticator;
    if (method.startsWith('isSolver')) return state.solver ? 'true' : 'false';
    if (method.startsWith('getThreshold')) return String(state.thresholds[String(args[1]).toLowerCase()] ?? 1);
    if (method.startsWith('getOwners')) return `[${(state.owners[String(args[1]).toLowerCase()] ?? [args[1]]).join(', ')}]`;
    if (method.startsWith('isValidSignature')) {
      const expected = state.signatures[String(args[1]).toLowerCase()];
      return expected && String(args[4]).toLowerCase() === expected.toLowerCase() ? '0x1626ba7e' : '0xffffffff';
    }
    return '';
  };

  let source = fs
    .readFileSync(SERVER, 'utf8')
    .replace(/^import .*;\n/gm, '')
    .replaceAll('import.meta.dirname', JSON.stringify(path.join(ROOT, 'link-service')));
  source += '\nglobalThis.api = { status, checksBeforeSigning, signatureProblem, verifies, hasCode, funding, saveOffer, codeCache, recordSignature, offerQueues };';

  const context = {
    fs,
    path,
    crypto,
    execFileSync,
    spawnSync: () => ({ status: 0 }),
    http: {
      createServer: (fn) => {
        handleRequest = fn;
        return { listen() {} };
      },
    },
    process: { ...process, env: { ...process.env, PRIVATE_TRADE_ROOT: root, PRIVATE_TRADE_WRAPPER: '0x00000000000000000000000000000000000000f0' } },
    console,
    URL,
    Buffer,
    Date,
    fetch: async () => ({ ok: true, json: async () => ({ status: state.orderState }), text: async () => '{}' }),
    render: () => '',
    renderCreate: () => '',
  };
  vm.runInNewContext(source, context);
  const api = context.api;
  if (!handleRequest) throw new Error('the service did not register a request handler');

  /// Enter a request. The handler runs until it awaits the body, then this returns.
  const open = (method, url) =>
    new Promise((resolve) => {
      const req = new EventEmitter();
      req.method = method;
      req.url = url;
      req.headers = {};
      let settled = null;
      const res = {
        writeHead(status) {
          settled = { status };
          return this;
        },
        end(text) {
          settled = { status: settled.status, body: text ? JSON.parse(text) : null };
          resolve({ ...settled, deliver: () => Promise.resolve(settled) });
          return this;
        },
      };
      const pending = handleRequest(req, res);
      // Give the handler a turn to reach its `await`, so two opens really are in flight together.
      setImmediate(() => {
        resolve({
          deliver: async (body) => {
            if (body !== undefined) req.emit('data', typeof body === 'string' ? body : JSON.stringify(body));
            req.emit('end');
            await pending;
            return settled;
          },
        });
      });
    });

  return { api, open, calls, state };
}
