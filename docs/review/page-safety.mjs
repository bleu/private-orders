#!/usr/bin/env node
// Browser checks for the trade page, in a real browser.
//
// The page is a program that builds another program and renders whatever the service and a token
// contract hand it. That makes two classes of defect invisible to `node --check` and to a
// function-level test:
//
//   * untrusted text becoming markup — a token's symbol is chosen by whoever deployed the token
//   * the wallet flow itself — which prompt is asked for, on which chain, for which allowance
//
// So this runs the real page in headless Chrome over the Chrome DevTools Protocol, against the real
// service and the fixtures in `fixtures.mjs`. No dependency: Node's global `WebSocket` is the client.
//
//   node docs/review/page-safety.mjs
//   CHROME_PATH=/path/to/chrome node docs/review/page-safety.mjs

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';

import {
  MAKER,
  MAKER_SHED,
  TAKER,
  TAKER_SHED,
  USDC,
  call,
  createOffer,
  freePort,
  killAll,
  makeRoot,
  offerRecord,
  setChain,
  sleep,
  startOrderbook,
  startService,
} from './fixtures.mjs';

const MAKER_KEY = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d';
const TAKER_KEY = '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a';
const MALICIOUS_SYMBOL = '<img src=x onerror="window.__pwned=1">';

const CHROME_CANDIDATES = [
  process.env.CHROME_PATH,
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
  '/usr/bin/google-chrome',
  '/usr/bin/chromium',
  '/usr/bin/chromium-browser',
].filter(Boolean);

const chromePath = CHROME_CANDIDATES.find((candidate) => fs.existsSync(candidate));

// --- a very small CDP client ----------------------------------------------------------------------

class Devtools {
  constructor(url) {
    this.socket = new WebSocket(url);
    this.nextId = 0;
    this.pending = new Map();
    this.waiting = new Map();
    this.socket.addEventListener('message', (event) => {
      const message = JSON.parse(event.data);
      if (message.id && this.pending.has(message.id)) {
        const { resolve, reject } = this.pending.get(message.id);
        this.pending.delete(message.id);
        if (message.error) reject(new Error(JSON.stringify(message.error)));
        else resolve(message.result);
        return;
      }
      const handlers = this.waiting.get(message.method) ?? [];
      this.waiting.set(message.method, []);
      for (const handler of handlers) handler(message.params);
    });
  }

  ready() {
    return new Promise((resolve, reject) => {
      this.socket.addEventListener('open', () => resolve());
      this.socket.addEventListener('error', () => reject(new Error('could not reach the browser')));
    });
  }

  send(method, params = {}) {
    const id = (this.nextId += 1);
    this.socket.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      setTimeout(() => {
        if (this.pending.delete(id)) reject(new Error(`${method} timed out`));
      }, 30000);
    });
  }

  once(method) {
    return new Promise((resolve) => {
      const handlers = this.waiting.get(method) ?? [];
      handlers.push(resolve);
      this.waiting.set(method, handlers);
    });
  }

  close() {
    this.socket.close();
  }
}

async function launchChrome() {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'private-trade-chrome.'));
  const child = spawn(
    chromePath,
    [
      '--headless=new',
      '--remote-debugging-port=0',
      `--user-data-dir=${profile}`,
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-extensions',
      '--disable-gpu',
      '--disable-dev-shm-usage',
      '--allow-insecure-localhost',
      // Containers that run as root need this; local machines do not, and it is not the default.
      ...(process.env.CHROME_NO_SANDBOX === '1' ? ['--no-sandbox'] : []),
      'about:blank',
    ],
    { stdio: ['ignore', 'pipe', 'pipe'] },
  );

  const endpoint = await new Promise((resolve, reject) => {
    let buffer = '';
    const timer = setTimeout(() => reject(new Error('the browser never reported a debugging endpoint')), 20000);
    child.stderr.on('data', (chunk) => {
      buffer += chunk;
      const match = buffer.match(/DevTools listening on (ws:\/\/\S+)/);
      if (match) {
        clearTimeout(timer);
        resolve(match[1]);
      }
    });
    child.once('exit', () => reject(new Error('the browser exited before it was ready')));
  });

  // The page target, not the browser target: this only needs one tab.
  const host = endpoint.replace(/^ws:\/\//, '').replace(/\/.*$/, '');
  let pageSocket = null;
  for (let attempt = 0; attempt < 60 && !pageSocket; attempt += 1) {
    try {
      const targets = await (await fetch(`http://${host}/json/list`)).json();
      pageSocket = targets.find((t) => t.type === 'page' && t.webSocketDebuggerUrl)?.webSocketDebuggerUrl ?? null;
    } catch {
      // not up yet
    }
    if (!pageSocket) await sleep(100);
  }
  if (!pageSocket) throw new Error('no page target in the browser');

  const client = new Devtools(pageSocket);
  await client.ready();
  await client.send('Page.enable');
  await client.send('Runtime.enable');

  const evaluate = async (expression) => {
    const result = await client.send('Runtime.evaluate', {
      expression,
      awaitPromise: true,
      returnByValue: true,
    });
    if (result.exceptionDetails) {
      throw new Error(`the page threw: ${result.exceptionDetails.exception?.description ?? 'unknown'}`);
    }
    return result.result.value;
  };

  const waitFor = async (expression, what, tries = 120) => {
    for (let attempt = 0; attempt < tries; attempt += 1) {
      if (await evaluate(expression)) return;
      await sleep(100);
    }
    throw new Error(`the page never showed ${what}`);
  };

  return {
    client,
    host,
    close: () => {
      client.close();
      child.kill('SIGKILL');
      try {
        fs.rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
      } catch {
        // the browser's own files are not the assertion
      }
    },
    /// Navigate and wait for the page's own render to settle.
    async open(url) {
      const loaded = client.once('Page.loadEventFired');
      await client.send('Page.navigate', { url });
      await loaded;
    },
    evaluate,
    waitFor,
  };
}

// --- fixture setup --------------------------------------------------------------------------------

/// `chain` is applied before anything is created, because the service remembers an owner's kind per
/// address and the create response already asks which funding mode applies.
async function serviceWith(extraEnv, chain = {}) {
  const root = makeRoot();
  const orderbook = await startOrderbook();
  const port = await freePort();
  const service = await startService({
    root,
    port,
    orderbook: orderbook.url,
    extraEnv: {
      PRIVATE_TRADE_DEV_KEYS: `${MAKER}=${MAKER_KEY},${TAKER}=${TAKER_KEY}`,
      ...extraEnv,
    },
  });
  setChain(root, {
    tokens: {
      [USDC]: { symbol: 'USDC', decimals: 6, balances: { [MAKER]: '100000000', [TAKER]: '100000000' } },
    },
    ...chain,
  });
  return { root, orderbook, port, service, stop: async () => { await service.stop(); await orderbook.close(); } };
}

const offerUrl = (port, id, extra = '') =>
  `http://127.0.0.1:${port}/o/${id}?devwallet=${MAKER}${extra}`;

const tests = [];
const test = (name, fn) => tests.push({ name, fn });

test('a token symbol cannot become markup on the signing page', async () => {
  const fixture = await serviceWith({});
  const browser = await launchChrome();
  try {
    setChain(fixture.root, {
      tokens: { [USDC]: { symbol: MALICIOUS_SYMBOL, decimals: 6, balances: { [MAKER]: '100000000' } } },
    });
    const offer = await createOffer(fixture.port, { sellAmount: '100000000' });
    await browser.open(offerUrl(fixture.port, offer.id));
    await browser.waitFor("document.body.innerText.toLowerCase().includes('your part')", 'the trade page');

    const pwned = await browser.evaluate('window.__pwned ?? null');
    assert.equal(pwned, null, 'the symbol executed as script');

    const images = await browser.evaluate("document.querySelectorAll('img').length");
    assert.equal(images, 0, 'the symbol became an element');

    // It is still readable: the fix is escaping, not hiding.
    const shown = await browser.evaluate('document.body.innerText.includes(' + JSON.stringify(MALICIOUS_SYMBOL) + ')');
    assert.equal(shown, true, 'the symbol was not shown as text');

    const escaped = await browser.evaluate(
      "document.documentElement.innerHTML.includes('&lt;img src=x onerror=')",
    );
    assert.equal(escaped, true, 'the symbol did not reach the DOM as escaped text');
  } finally {
    browser.close();
    await fixture.stop();
  }
});

test('the page refuses to sign when the wallet is on another chain', async () => {
  // The trade is signed for chain 10; the development wallet reports chain 1.
  const fixture = await serviceWith({ FIXTURE_CHAIN_ID: '10' });
  const browser = await launchChrome();
  try {
    const offer = await createOffer(fixture.port, { sellAmount: '100000000' });
    await browser.open(offerUrl(fixture.port, offer.id));
    await browser.waitFor("document.body.innerText.toLowerCase().includes('your part')", 'the trade page');

    const warning = await browser.evaluate("document.body.innerText.toLowerCase().includes('your wallet is on chain 1')");
    assert.equal(warning, true, 'no chain mismatch was reported');

    const disabled = await browser.evaluate(
      "[...document.querySelectorAll('button')].filter((b) => /Sign and/.test(b.textContent)).every((b) => b.disabled)",
    );
    assert.equal(disabled, true, 'the signing button was live on the wrong chain');
  } finally {
    browser.close();
    await fixture.stop();
  }
});

test('a token with no permit is funded by an approve transaction, then signed', async () => {
  const fixture = await serviceWith({ FIXTURE_PERMIT_KIND: 'none' });
  const browser = await launchChrome();
  try {
    const offer = await createOffer(fixture.port, { sellAmount: '100000000' });
    await browser.open(offerUrl(fixture.port, offer.id));
    await browser.waitFor("document.body.innerText.toLowerCase().includes('your part')", 'the trade page');

    const step = await browser.evaluate("document.body.innerText.toLowerCase().includes('approve your shed')");
    assert.equal(step, true, 'the approve path was not shown');

    const said = await browser.evaluate(
      "document.body.innerText.toLowerCase().includes('no permit')",
    );
    assert.equal(said, true, 'the page did not say why an approval is needed');

    await browser.evaluate(
      "[...document.querySelectorAll('button')].find((b) => b.textContent.includes('Approve and sign')).click()",
    );
    await browser.waitFor(
      `fetch('/offers/${offer.id}').then((r) => r.json()).then((o) => o.makerSigned === true)`,
      'the maker signature to be accepted',
    );

    // The page sent exactly the approval the server described: approve(shed, amount).
    const approvals = JSON.parse(fs.readFileSync(path.join(fixture.root, 'chain.json'), 'utf8')).approvals ?? {};
    const granted = approvals[USDC]?.[MAKER_SHED];
    assert.equal(granted, '100000000', `the approval granted ${granted}, not the trade amount`);

    const record = offerRecord(fixture.root, offer.id);
    assert.ok(record.signatures.maker, 'the authorisation was not stored');
    assert.equal(record.permits.maker, undefined, 'an approve-funded side stored a permit signature');
  } finally {
    browser.close();
    await fixture.stop();
  }
});

test('a wallet that switched accounts cannot sign for this trade', async () => {
  const fixture = await serviceWith({});
  const browser = await launchChrome();
  try {
    const offer = await createOffer(fixture.port, { sellAmount: '100000000' });
    await browser.open(offerUrl(fixture.port, offer.id));
    await browser.waitFor("document.body.innerText.toLowerCase().includes('your part')", 'the trade page');

    // The reader switches to another account in the wallet after connecting, which is the case the
    // page's check exists for: a signature from the wrong account is otherwise only discovered by the
    // relay, several steps later.
    await browser.evaluate(`window.__devWallet.useAccount('${TAKER}')`);
    await browser.evaluate(
      "[...document.querySelectorAll('button')].find((b) => b.textContent.includes('Sign and')).click()",
    );
    await browser.waitFor(
      "document.body.innerText.toLowerCase().includes('the active account in your wallet is')",
      'the account mismatch to be reported',
    );

    const stored = offerRecord(fixture.root, offer.id).signatures?.maker;
    assert.equal(stored, undefined, 'a signature was stored from the wrong account');
  } finally {
    browser.close();
    await fixture.stop();
  }
});

test('the other side is shown as their order contract, not as the person', async () => {
  const fixture = await serviceWith({});
  const browser = await launchChrome();
  try {
    const offer = await createOffer(fixture.port, { sellAmount: '100000000' });
    await browser.open(offerUrl(fixture.port, offer.id));
    await browser.waitFor("document.body.innerText.toLowerCase().includes('your part')", 'the trade page');

    // The maker's counterparty is the taker's Shed, which is derivable from the taker's address by
    // anyone who has it — so the page must not present it as if it were the taker.
    const shown = await browser.evaluate(`document.body.innerText.includes('${TAKER_SHED}')`);
    assert.equal(shown, true, 'the counterparty Shed was not shown');

    const labelled = await browser.evaluate(
      "document.body.innerText.toLowerCase().includes('their order owner') && " +
      "document.body.innerText.toLowerCase().includes('not their wallet')",
    );
    assert.equal(labelled, true, 'the address was presented as the counterparty rather than their order contract');

    const claimsShed = await browser.evaluate("document.body.innerText.toLowerCase().includes('cow shed')");
    assert.equal(claimsShed, true, 'the page did not say what kind of contract it is');
  } finally {
    browser.close();
    await fixture.stop();
  }
});

test('the page says a DAI-style permit is unlimited instead of claiming an exact amount', async () => {
  const fixture = await serviceWith({ FIXTURE_PERMIT_KIND: 'dai' });
  const browser = await launchChrome();
  try {
    const offer = await createOffer(fixture.port, { sellAmount: '100000000' });
    await browser.open(offerUrl(fixture.port, offer.id));
    await browser.waitFor("document.body.innerText.toLowerCase().includes('your part')", 'the trade page');

    const honest = await browser.evaluate(
      "document.body.innerText.toLowerCase().includes('any amount of this token, until you revoke it')",
    );
    assert.equal(honest, true, 'the unlimited allowance was not disclosed');

    const claim = await browser.evaluate(
      "/exactly/.test(document.querySelectorAll('.step')[0].textContent)",
    );
    assert.equal(claim, false, 'the page still claimed the DAI-style permit grants exactly this amount');
  } finally {
    browser.close();
    await fixture.stop();
  }
});

test('the page says how many prompts there are, and that nothing has moved yet', async () => {
  const fixture = await serviceWith({});
  const browser = await launchChrome();
  try {
    const offer = await createOffer(fixture.port, { sellAmount: '100000000' });
    await browser.open(offerUrl(fixture.port, offer.id));
    await browser.waitFor("document.body.innerText.toLowerCase().includes('your part')", 'the trade page');

    const counted = await browser.evaluate(
      "document.body.innerText.toLowerCase().includes('your wallet will ask two signatures')",
    );
    assert.equal(counted, true, 'the page did not say how many prompts to expect');

    const which = await browser.evaluate(
      "document.body.innerText.toLowerCase().includes('the second is the trade itself')",
    );
    assert.equal(which, true, 'the page did not say which prompt is the trade');

    // Sign, then the scariest moment in the flow: it must say that nothing has happened yet.
    await browser.evaluate(
      "[...document.querySelectorAll('button')].find((b) => b.textContent.includes('Sign and')).click()",
    );
    await browser.waitFor(
      "document.body.innerText.toLowerCase().includes('nothing has moved yet')",
      'the after-signing note',
    );
    const share = await browser.evaluate(
      "document.body.innerText.toLowerCase().includes('send this to the other party')",
    );
    assert.equal(share, true, 'the link was not offered after signing');
  } finally {
    browser.close();
    await fixture.stop();
  }
});

test('an offer that cannot settle disables the button and says why', async () => {
  // The wrapper holds no solver seat, so nothing can ever submit this settlement.
  const fixture = await serviceWith({}, { unallowlisted: true });
  const browser = await launchChrome();
  try {
    const offer = await createOffer(fixture.port, { sellAmount: '100000000' });
    await browser.open(offerUrl(fixture.port, offer.id));
    await browser.waitFor("document.body.innerText.toLowerCase().includes('your part')", 'the trade page');

    const warned = await browser.evaluate(
      "document.body.innerText.toLowerCase().includes('cannot settle as it stands')",
    );
    assert.equal(warned, true, 'the page did not warn that the offer cannot settle');

    const reason = await browser.evaluate(
      "document.body.innerText.toLowerCase().includes('not allowlisted')",
    );
    assert.equal(reason, true, 'the page did not say what is wrong');

    const disabled = await browser.evaluate(
      "[...document.querySelectorAll('button')].filter((b) => /Sign and/.test(b.textContent)).every((b) => b.disabled)",
    );
    assert.equal(disabled, true, 'the signing button was live for an offer that cannot settle');
  } finally {
    browser.close();
    await fixture.stop();
  }
});

test('a cancelled offer offers the way back out of the Shed', async () => {
  // A cancellation is the one dead end that can arrive *after* funding: the maker can cancel once the
  // taker's bundles have been relayed, which puts tokens in the taker's Shed. Before this branch
  // existed, a cancelled offer rendered a status pill and nothing else — no way to move them back.
  const fixture = await serviceWith();
  const browser = await launchChrome();
  try {
    const offer = await createOffer(fixture.port, { sellAmount: '100000000' });
    // The wrapper's answer is what decides the status, so the chain state is what makes it cancelled.
    setChain(fixture.root, { offerState: { [offer.offerId]: 2 } });

    await browser.open(offerUrl(fixture.port, offer.id));
    // Wait for the branch itself, not for the status pill: the pill is drawn before the wallet is
    // connected, and the page renders only "connect a wallet" until it is.
    await browser.waitFor(
      "document.body.innerText.toLowerCase().includes('the maker cancelled this offer')",
      'the cancelled-offer page',
    );

    const said = await browser.evaluate(
      "document.body.innerText.toLowerCase().includes('the maker cancelled this offer')",
    );
    assert.equal(said, true, 'the page did not say the offer was cancelled');

    // Either answer about the Shed is acceptable — what is not acceptable is saying nothing about it.
    const shed = await browser.evaluate(
      "const t = document.body.innerText.toLowerCase(); t.includes('still in your shed') || t.includes('your shed is empty')",
    );
    assert.equal(shed, true, 'the page said nothing about what the Shed holds');
  } finally {
    browser.close();
    await fixture.stop();
  }
});

test('a smart contract account is told what it is and funds by approval', async () => {
  const fixture = await serviceWith({}, { contracts: [MAKER] });
  const browser = await launchChrome();
  try {
    const offer = await createOffer(fixture.port, { sellAmount: '100000000' });
    await browser.open(offerUrl(fixture.port, offer.id));
    await browser.waitFor("document.body.innerText.toLowerCase().includes('your part')", 'the trade page');

    const said = await browser.evaluate(
      "document.body.innerText.toLowerCase().includes('smart contract account')",
    );
    assert.equal(said, true, 'the page did not explain that this wallet is a contract account');

    // A permit is impossible for a contract account, so the page must not offer one.
    const mode = await browser.evaluate(
      "document.body.innerText.toLowerCase().includes('approve your shed') && " +
        "document.body.innerText.toLowerCase().includes('a transaction, then a signature')",
    );
    assert.equal(mode, true, 'a contract account was offered the permit path');
  } finally {
    browser.close();
    await fixture.stop();
  }
});

test('a smart contract account approves a hash instead of being handed a message', async () => {
  // The fixture answers for the empty blob the page submits, which is how an account that has approved
  // a hash answers its own ERC-1271 check.
  const fixture = await serviceWith({}, { contracts: [MAKER], signatures: { [MAKER]: '0x' } });
  const browser = await launchChrome();
  try {
    const offer = await createOffer(fixture.port, { sellAmount: '100000000' });
    await browser.open(offerUrl(fixture.port, offer.id));
    await browser.waitFor("document.body.innerText.toLowerCase().includes('your part')", 'the trade page');

    // The hash is the account's own, computed from its domain separator — and a page once built that
    // message itself, which produced a signature the account refused.
    const shown = await browser.evaluate('/0x[0-9a-f]{64}/.test(document.body.innerText)');
    assert.equal(shown, true, 'the page did not show the hash the account must approve');
    const explains = await browser.evaluate(
      "document.body.innerText.toLowerCase().includes('authorises by approving a hash')",
    );
    assert.equal(explains, true, 'the page did not explain how a contract account authorises');

    await browser.evaluate(
      "[...document.querySelectorAll('button')].find((b) => b.textContent.includes('Approve and sign')).click()",
    );
    for (let attempt = 0; attempt < 60; attempt += 1) {
      const view = await call(fixture.port, 'GET', `/offers/${offer.id}`);
      if (view.body.makerSigned) break;
      await sleep(100);
    }

    const record = offerRecord(fixture.root, offer.id);
    assert.equal(record.signatures.maker, '0x', 'the page did not send the empty signature the account expects');
    const fabricated = await browser.evaluate(
      "(window.__signedTypedData || []).some((d) => d.primaryType === 'SafeMessage')",
    );
    assert.equal(fabricated, false, 'the page built the account a message it cannot verify');
  } finally {
    browser.close();
    await fixture.stop();
  }
});

// --- runner ---------------------------------------------------------------------------------------

async function main() {
  if (!chromePath) {
    console.log('SKIP  no Chrome or Chromium found; set CHROME_PATH to run the page checks');
    process.exit(0);
  }

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

  killAll();
  console.log(`\n${tests.length - failed}/${tests.length} page checks passed`);
  process.exit(failed === 0 ? 0 : 1);
}

await main();
