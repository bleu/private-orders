// Drives the whole private trade flow through the app, in a real browser.
//
// Two parties, two wallets, two pages: the maker describes a trade and gets a link, the taker opens
// it, both sign, the pair settles on-chain, and the receipt says so. Nothing here calls the service's
// trade endpoints directly — every step is a click, and the assertions read what the page shows.
//
// The wallets are the development wallet the service exposes when it is started with keys, so this
// needs no wallet extension. That is the only test-specific part: the signatures, the relay, the
// order and the settlement are all real.
//
// Usage: node scripts/app-e2e.mjs        (with the service running and dev keys configured)

import { execFileSync, spawn } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const SERVICE = process.env.SERVICE_URL ?? 'http://localhost:9200';
const RPC = process.env.RPC ?? 'http://localhost:8545';
const MAKER = process.env.APP_E2E_MAKER ?? '';
const TAKER = process.env.APP_E2E_TAKER ?? '';
const USDC = process.env.USDC_ADDRESS ?? '';
const DAI = process.env.DAI_ADDRESS ?? '';

const step = (message) => console.log(`\n==> ${message}`);
// Thrown rather than exited: `process.exit` skips `finally`, which leaks a headless browser per run.
class Failure extends Error {}
const fail = (message) => {
  throw new Failure(message);
};

// --- a browser, over CDP -------------------------------------------------------------------------

const CHROME =
  process.env.CHROME_PATH ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

async function launch() {
  const port = 9000 + Math.floor(Math.random() * 1000);
  const profile = mkdtempSync(join(tmpdir(), 'private-trade-e2e-'));
  const chrome = spawn(
    CHROME,
    [
      '--headless=new',
      `--remote-debugging-port=${port}`,
      `--user-data-dir=${profile}`,
      '--no-first-run',
      '--no-default-browser-check',
      'about:blank',
    ],
    { stdio: 'ignore' },
  );

  for (let i = 0; i < 60; i++) {
    try {
      const res = await fetch(`http://localhost:${port}/json/version`);
      if (res.ok) return { chrome, port, profile };
    } catch {
      /* not up yet */
    }
    await new Promise((r) => setTimeout(r, 250));
  }
  chrome.kill();
  fail('chrome did not start');
}

async function attach(port) {
  const version = await (await fetch(`http://localhost:${port}/json/version`)).json();
  const socket = new WebSocket(version.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    socket.onopen = resolve;
    socket.onerror = () => reject(new Error('could not attach to the browser'));
  });

  let nextId = 1;
  const pending = new Map();
  socket.onmessage = (event) => {
    const message = JSON.parse(event.data);
    if (message.id && pending.has(message.id)) {
      pending.get(message.id)(message);
      pending.delete(message.id);
    }
  };
  // `sessionId` belongs at the top level of the message, not inside `params`: put it in params and
  // every command silently goes to the browser target, which has no page domains.
  const send = (method, params = {}, session = undefined) =>
    new Promise((resolve, reject) => {
      const id = nextId++;
      pending.set(id, (message) => {
        // A CDP error is a reply, not a missing reply: swallowing it turns every failure into a
        // timeout further down.
        if (message.error) reject(new Error(`${method}: ${message.error.message}`));
        else resolve(message);
      });
      socket.send(JSON.stringify({ id, method, params, ...(session ? { sessionId: session } : {}) }));
    });

  // One page for the whole run: the flow moves between pages, and a second context would need its
  // own wallet.
  // `send` resolves the whole CDP message; the values are under `result`.
  const { result: page } = await send('Target.createTarget', { url: 'about:blank' });
  const { result: attached } = await send('Target.attachToTarget', { targetId: page.targetId, flatten: true });
  const { sessionId } = attached;
  if (!sessionId) fail('the browser did not give us a page session');
  const call = (method, params = {}) => send(method, params, sessionId);
  await call('Runtime.enable');
  await call('Page.enable');

  const evaluate = async (expression) => {
    const res = await call('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (res.result?.exceptionDetails) {
      throw new Error(res.result.exceptionDetails.exception?.description ?? 'the page threw');
    }
    return res.result?.result?.value;
  };

  const open = async (url) => {
    await call('Page.navigate', { url });
    let lastError = '';
    for (let i = 0; i < 120; i++) {
      const ready = await evaluate('document.readyState + ":" + (document.body ? "body" : "none")').catch(
        (err) => {
          lastError = err.message;
          return '';
        },
      );
      if (typeof ready === 'string' && ready.startsWith('complete') && ready.endsWith('body')) return;
      await new Promise((r) => setTimeout(r, 250));
    }
    fail(`the page at ${url} did not finish loading (${lastError || 'no reply from the page'})`);
  };

  /// Polls what the page says. The assertions are on rendered text, not on internal state.
  const waitForText = async (pattern, timeout = 180000) => {
    const deadline = Date.now() + timeout;
    let last = '';
    while (Date.now() < deadline) {
      last = await evaluate('document.body.innerText');
      if (typeof last === 'string' && last.includes(pattern)) return last;
      await new Promise((r) => setTimeout(r, 500));
    }
    fail(`the page never showed ${JSON.stringify(pattern)}. It said:\n${last}`);
  };

  /// Clicks the first button whose label matches, and reports what it did.
  const click = async (pattern) => {
    const result = await evaluate(`(() => {
      const button = [...document.querySelectorAll('button')].find((b) => ${pattern}.test(b.textContent));
      if (!button) return 'missing:' + ${pattern}.source;
      button.click();
      return 'clicked';
    })()`);
    if (String(result).startsWith('missing')) fail(`no button matching ${pattern} on the page`);
  };

  /// Waits for a step to finish, and treats a visible error as a failure.
  ///
  /// Checking for the error *after* the step raced the submit and missed it, which is how a broken
  /// maker signature first showed up as a five-minute wait for a settlement that could never come.
  const waitForOutcome = async (pattern, what, timeout = 180000) => {
    const deadline = Date.now() + timeout;
    let last = '';
    while (Date.now() < deadline) {
      const state = JSON.parse(
        await evaluate(`JSON.stringify([
          document.body.innerText,
          (document.querySelector('.note.warn') || {}).innerText || ''
        ])`),
      );
      const [text, warning] = state;
      last = text;
      if (warning) fail(`${what}: the page reported ${JSON.stringify(warning)}`);
      if (typeof text === 'string' && text.includes(pattern)) return text;
      await new Promise((r) => setTimeout(r, 300));
    }
    fail(`${what}: the page never showed ${JSON.stringify(pattern)}. It said:\n${last}`);
  };

  const fill = async (id, value) =>
    evaluate(`(() => { const field = document.getElementById(${JSON.stringify(id)}); field.value = ${JSON.stringify(value)}; return field.value; })()`);

  return { evaluate, open, waitForText, waitForOutcome, click, fill, close: () => socket.close() };
}

// --- balances -----------------------------------------------------------------------------------

const balanceOf = (token, holder) =>
  execFileSync('cast', ['call', token, 'balanceOf(address)(uint256)', holder, '--rpc-url', RPC], {
    encoding: 'utf8',
  })
    .trim()
    .split(' ')[0];

// --- the flow -----------------------------------------------------------------------------------

const browser = await launch();
const page = await attach(browser.port);

try {
  step('the maker describes a trade');
  await page.open(`${SERVICE}/?devwallet=${MAKER}`);
  await page.waitForText('Connect Development wallet');
  await page.click(/Connect /);
  await page.waitForText('Create the link');
  await page.fill('sellToken', USDC);
  await page.fill('sellAmount', '100000000');
  await page.fill('buyToken', DAI);
  await page.fill('buyAmount', '100000000000000000000');
  await page.fill('taker', TAKER);
  await page.fill('hours', '2');
  await page.click(/Create the link/);

  await page.waitForText('Sign and get the link');
  const url = await page.evaluate('location.href');
  const id = url.split('/o/')[1]?.split('?')[0];
  if (!id) fail(`the app did not land on an offer page (at ${url})`);
  console.log(`   offer ${id}`);

  step('the maker signs — no transaction');
  await page.click(/Sign and get the link/);
  await page.waitForOutcome('Send this to the other party', 'the maker could not sign');
  const link = await page.evaluate('document.querySelector(".link input").value');
  console.log(`   link ${link}`);

  step('the taker opens the link and signs');
  await page.open(`${link}?devwallet=${TAKER}`);
  await page.waitForText('Sign and settle');
  const before = { maker: balanceOf(DAI, MAKER), taker: balanceOf(USDC, TAKER) };
  await page.click(/Sign and settle/);

  step('waiting for settlement');
  // Assert on what the page reports about itself: the status pill, and the receipt it renders.
  // Looking for the word "Settled" missed a receipt that said "settled" in the pill and showed the
  // transaction underneath.
  await page.waitForOutcome('RECEIPT', 'the taker could not accept', 600000);
  const settled = await page.evaluate('document.getElementById("status").textContent');
  if (settled !== 'settled') fail(`the page's status pill says ${JSON.stringify(settled)}`);
  const receipt = await page.evaluate('document.getElementById("app").innerText');
  const tx = (receipt.match(/0x[0-9a-f]{64}/) ?? [''])[0];
  if (!tx) fail(`the receipt shows no transaction:\n${receipt}`);
  console.log(`   settled, tx ${tx}`);

  const after = { maker: balanceOf(DAI, MAKER), taker: balanceOf(USDC, TAKER) };
  if (BigInt(after.maker) <= BigInt(before.maker)) fail('the maker did not receive DAI');
  if (BigInt(after.taker) <= BigInt(before.taker)) fail('the taker did not receive USDC');

  console.log(`   maker received ${BigInt(after.maker) - BigInt(before.maker)} DAI`);
  console.log(`   taker received ${BigInt(after.taker) - BigInt(before.taker)} USDC`);
  console.log(`   neither party sent a transaction`);
  console.log('\nthe whole flow ran in the app');
} catch (err) {
  console.error(`\nFAILED: ${err.message}`);
  process.exitCode = 1;
} finally {
  page.close();
  browser.chrome.kill();
}
