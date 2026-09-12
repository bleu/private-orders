// The trade page.
//
// One page serves both parties and decides what to show from the wallet that connects:
//
//   no wallet      the terms, and an invitation to connect
//   not a party    the terms, and no counterparty: the link is a bearer token, so nothing here is
//                  addressed to whoever happens to hold it
//   maker          sign, then share the link
//   taker          sign, then settle
//
// It never shows a raw digest as the primary action. Signing goes through `eth_signTypedData_v4`,
// so the wallet displays the amount, the spender and the calls instead of a hex blob — the typed
// data is produced by the same Solidity that produces the digest, and the end-to-end script proves
// the two are the same message by signing both and comparing signatures.
//
// Wallets are discovered by EIP-6963 as well as `window.ethereum`. With more than one wallet
// installed, `window.ethereum` is whichever won the injection race, which is not necessarily the one
// the reader wants, and a wallet that only announces itself is invisible to a page that reads
// `window.ethereum` alone.

export const render = (id) => `<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Private trade</title>
<style>
  :root{--ink:#111;--muted:#666;--line:#e7e7e7;--bg:#fff;--accent:#0b6cff;--ok:#1b7f4b;--warn:#b25b00}
  @media (prefers-color-scheme:dark){:root{--ink:#f2f2f2;--muted:#9a9a9a;--line:#2a2a2a;--bg:#111}}
  *{box-sizing:border-box}
  body{font:16px/1.55 system-ui,-apple-system,sans-serif;color:var(--ink);background:var(--bg);
       max-width:32rem;margin:0 auto;padding:1.5rem 1rem 4rem}
  h1{font-size:1.2rem;margin:0 0 .25rem}
  h2{font-size:.8rem;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin:1.75rem 0 .5rem}
  .sub{color:var(--muted);font-size:.85rem;margin:0}
  .pill{display:inline-block;padding:.1rem .5rem;border-radius:999px;background:#eef4ff;color:var(--accent);
        font-size:.75rem;font-weight:600}
  .pill.ok{background:#e8f6ee;color:var(--ok)} .pill.warn{background:#fff3e4;color:var(--warn)}
  .trade{border:1px solid var(--line);border-radius:14px;padding:1rem 1.1rem;margin-top:1rem}
  .row{display:flex;justify-content:space-between;align-items:baseline;gap:1rem;padding:.5rem 0}
  .row+.row{border-top:1px solid var(--line)}
  .amt{font-variant-numeric:tabular-nums;font-weight:650;font-size:1.05rem}
  small,.muted{color:var(--muted)}
  .addr{font-family:ui-monospace,monospace;font-size:.8rem;color:var(--muted);word-break:break-all}
  button{font:inherit;font-weight:600;border:0;border-radius:10px;padding:.7rem 1rem;background:var(--accent);
         color:#fff;width:100%;cursor:pointer;margin-top:.8rem}
  button:disabled{background:var(--line);color:var(--muted);cursor:default}
  button.ghost{background:transparent;color:var(--accent);border:1px solid var(--line)}
  .step{border:1px solid var(--line);border-radius:12px;padding:.85rem 1rem;margin:.6rem 0}
  .step.done{border-color:var(--ok)} .step.done .n{background:var(--ok)}
  .n{display:inline-flex;width:1.35rem;height:1.35rem;border-radius:50%;background:var(--ink);color:var(--bg);
     align-items:center;justify-content:center;font-size:.75rem;font-weight:700;margin-right:.5rem}
  .link{display:flex;gap:.5rem;margin-top:.5rem}
  .link input{flex:1;font:inherit;padding:.6rem .7rem;border:1px solid var(--line);border-radius:10px;
              background:transparent;color:var(--ink)}
  .note{background:#f6f6f6;border-radius:10px;padding:.7rem .9rem;margin-top:1rem;font-size:.88rem}
  @media (prefers-color-scheme:dark){.note{background:#1c1c1c}}
  details{margin-top:1.5rem} summary{cursor:pointer;color:var(--muted);font-size:.85rem}
  .ok{color:var(--ok)} .warn{color:var(--warn)}
  .bar{height:4px;border-radius:2px;background:var(--line);overflow:hidden;margin-top:1rem}
  .bar>i{display:block;height:100%;width:35%;background:var(--accent);animation:slide 1.4s ease-in-out infinite}
  @keyframes slide{0%{transform:translateX(-100%)}100%{transform:translateX(300%)}}
</style>

<h1>Private trade</h1>
<p class="sub"><span id="status" class="pill">loading</span> <span class="pill ok">you pay no gas</span></p>

<div id="app"></div>

<script>
const id = ${JSON.stringify(id)};

// A fragment, so a caller can pass several top-level nodes. Anything needing a handle on a single
// element asks for it with node().
const frag = (h) => { const t = document.createElement('template'); t.innerHTML = h.trim(); return t.content; };
const node = (h) => frag(h).firstElementChild;
const get = async (p) => (await fetch(p)).json();
const post = async (p, body) => {
  const res = await fetch(p, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
  const out = await res.json();
  if (!res.ok) throw new Error(out.error || res.statusText);
  return out;
};

let offer = null, me = null, account = null, usable = null, walletName = null, failure = null;
let permitSig = null, bundleSig = null;

// --- wallet discovery ---------------------------------------------------------------------------

const discovered = [];
window.addEventListener('eip6963:announceProvider', (event) => {
  if (!discovered.some((d) => d.info.uuid === event.detail.info.uuid)) {
    discovered.push(event.detail);
    render();
  }
});
window.dispatchEvent(new Event('eip6963:requestProvider'));

function wallets() {
  if (discovered.length) {
    return discovered.map((d) => ({ name: d.info.name, provider: d.provider }));
  }
  const injected = window.ethereum;
  if (!injected) return [];
  const name = injected.isRabby ? 'Rabby' : injected.isMetaMask ? 'MetaMask' : 'Browser wallet';
  return [{ name, provider: injected }];
}

async function connect(wallet) {
  try {
    failure = null;
    const accounts = await wallet.provider.request({ method: 'eth_requestAccounts' });
    if (!accounts || !accounts.length) throw new Error('the wallet returned no accounts');
    usable = wallet.provider;
    walletName = wallet.name;
    account = accounts[0];
    // Temporary diagnostic, run once per connect: it is the only way to tell a wallet that is on a
    // different key from one that hashed a different message.
    try {
      const message = 'private-trade wallet check';
      const signature = await usable.request({ method: 'personal_sign', params: [message, account] });
      check = await post('/wallet-check', { address: account, message, signature });
    } catch {
      check = null;
    }

    usable.on?.('accountsChanged', (list) => { account = list[0] ?? null; me = null; loadRole(); });
    usable.on?.('chainChanged', () => loadRole());
    await loadRole();
  } catch (err) {
    failure = describe(err);
    render();
  }
}

// Errors from wallets are worth showing verbatim: "user rejected" and "not connected" need
// different responses from the reader, and swallowing either one leaves a dead button.
function describe(err) {
  const code = err && err.code ? ' (code ' + err.code + ')' : '';
  const text = err && (err.message || err.reason) ? err.message || err.reason : String(err);
  if (/rejected|denied/i.test(text)) return 'The request was declined in ' + (walletName || 'the wallet') + '.' + code;
  return text + code;
}

// --- rendering ----------------------------------------------------------------------------------

function amount(raw, decimals) {
  const s = String(raw).padStart(decimals + 1, '0');
  const whole = s.slice(0, s.length - decimals).replace(/\\B(?=(\\d{3})+(?!\\d))/g, ',');
  const frac = s.slice(s.length - decimals).replace(/0+$/, '');
  return frac ? whole + '.' + frac : whole;
}
const short = (a) => a.slice(0, 6) + '…' + a.slice(-4);
const until = (iso) => {
  const ms = new Date(iso).getTime() - Date.now();
  if (ms < 0) return 'expired';
  const m = Math.floor(ms / 60000);
  if (m < 60) return 'in ' + m + ' min';
  const h = Math.floor(m / 60);
  return h < 48 ? 'in ' + h + ' hours' : 'in ' + Math.floor(h / 24) + ' days';
};

async function load() {
  offer = await get('/offers/' + id);
  document.getElementById('status').textContent = offer.status;
  document.getElementById('status').className = 'pill' + (offer.status === 'settled' ? ' ok' : '');
  render();
  // A wallet that is already authorised is restored without a prompt.
  const existing = wallets()[0];
  if (existing) {
    try {
      const [first] = await existing.provider.request({ method: 'eth_accounts' });
      if (first) { usable = existing.provider; walletName = existing.name; account = first; await loadRole(); }
    } catch { /* a wallet that refuses this is still connectable by button */ }
  }
}

async function loadRole() {
  if (!account) return render();
  me = await get('/offers/' + id + '/role?address=' + account);
  render();
}

// The public view is written from the maker's side. Until we know who is asking, the labels stay
// neutral; once we do, they are the reader's own.
function terms() {
  const t = offer.terms;
  const mine = me && me.role;
  const pay = mine === 'taker' ? [t.buyAmount, t.buyDecimals, t.buySymbol] : [t.sellAmount, t.sellDecimals, t.sellSymbol];
  const get_ = mine === 'taker' ? [t.sellAmount, t.sellDecimals, t.sellSymbol] : [t.buyAmount, t.buyDecimals, t.buySymbol];
  const [payLabel, getLabel] = mine ? ['You pay', 'You receive'] : ['One side gives', 'The other gives'];
  return frag(\`
    <div class="trade">
      <div class="row"><span>\${payLabel}</span><span class="amt">\${amount(pay[0], pay[1])} \${pay[2]}</span></div>
      <div class="row"><span>\${getLabel}</span><span class="amt">\${amount(get_[0], get_[1])} \${get_[2]}</span></div>
      <div class="row"><small>Expires</small><small>\${until(t.expiresAt)}</small></div>
    </div>\`);
}

function render() {
  const app = document.getElementById('app');
  app.replaceChildren();
  if (!offer) return;
  app.append(terms());
  if (failure) app.append(frag('<div class="note warn">' + failure + '</div>'));

  if (!account) {
    const found = wallets();
    app.append(frag('<div class="step"><b>Connect the wallet this trade is with.</b>' +
      '<p class="sub" style="margin:.4rem 0 0">The terms above are public to anyone holding the link. ' +
      'Your side of it appears once the wallet is connected.</p></div>'));
    for (const wallet of found) {
      const b = node('<button>Connect ' + wallet.name + '</button>');
      b.onclick = () => connect(wallet);
      app.append(b);
    }
    if (!found.length) {
      app.append(frag('<div class="note warn">No wallet detected on this page.' +
        '<p class="sub" style="margin:.5rem 0 0">If one is installed, check that the extension can reach ' +
        'this site — some wallets are disabled on <code>localhost</code> until allowed — or open the link ' +
        'inside the wallet\\'s own browser.</p>' +
        '<p class="sub" style="margin:.5rem 0 0">EIP-6963 announcements seen: ' + discovered.length + '.</p></div>'));
    }
    return;
  }

  app.append(frag('<div class="note">Connected as <span class="addr">' + short(account) + '</span>' +
    (walletName ? ' with ' + walletName : '') +
    (check
      ? '<br>Signs as <span class="addr">' + (check.recovered ? short(check.recovered) : 'unreadable') + '</span> ' +
        (check.matches ? '<span class="ok">— matches</span>' : '<span class="warn">— DIFFERENT from the connected account</span>')
      : '') +
    '</div>'));

  if (!me || !me.role) {
    app.append(frag('<div class="note warn">This wallet is not a party to the trade. ' +
      'Switch accounts in the wallet if that is unexpected.</div>'));
    return;
  }

  if (me.role === 'taker' && !me.makerSigned) {
    app.append(frag('<div class="note warn">Waiting for the other party to sign. The link is ready — ' +
      'nothing happens until they do.</div>'));
  }

  app.append(frag('<h2>Counterparty</h2><div class="trade"><div class="row">' +
    '<span class="addr">' + me.counterparty + '</span></div></div>'));

  const funded = BigInt(me.balance) >= BigInt(me.permit.amount);

  app.append(frag('<h2>Your part</h2>'));
  app.append(frag('<div class="step' + (permitSig ? ' done' : '') + '"><span class="n">1</span><b>Allow ' +
    amount(me.permit.amount, me.permit.decimals) + ' ' + me.permit.symbol + '</b>' +
    '<p class="sub" style="margin:.4rem 0 0">Signs a permit so your own Shed can hold the tokens. ' +
    'It cannot move them anywhere else, and anyone may submit it.</p></div>'));
  app.append(frag('<div class="step' + (bundleSig ? ' done' : '') + '"><span class="n">2</span><b>Authorise the trade</b>' +
    '<p class="sub" style="margin:.4rem 0 0">Creates the order for exactly this pair, at exactly these amounts. ' +
    'Nothing else can fill it.</p></div>'));
  app.append(frag('<div class="note">Your wallet holds ' + amount(me.balance, me.permit.decimals) + ' ' +
    me.permit.symbol + (funded ? ' <span class="ok">— enough</span>'
      : ' <span class="warn">— you need ' + amount(me.permit.amount, me.permit.decimals) + '</span>') + '</div>'));

  if (offer.status === 'settled') {
    app.append(frag('<div class="note ok">Settled.' +
      (offer.orderUid ? ' Order <span class="addr">' + short(offer.orderUid) + '</span>' : '') + '</div>'));
    return;
  }

  const go = node('<button>' + (me.role === 'maker' ? 'Sign and get the link' : 'Sign and settle') + '</button>');
  go.disabled = !funded;
  go.onclick = async () => {
    go.disabled = true;
    try {
      failure = null;
      go.textContent = 'Check your wallet…';

      // Wallets sign with whatever account is *active*, which is not necessarily the one this page
      // connected with — Rabby will happily sign with a different account and the signature then
      // recovers to someone else. Re-read it here, so the mismatch is a sentence rather than a
      // failed relay several steps later.
      const [active] = await usable.request({ method: 'eth_accounts' });
      if (!active || active.toLowerCase() !== account.toLowerCase()) {
        throw new Error(
          'The active account in your wallet is ' + (active ? short(active) : 'not set') +
          ', but this trade is with ' + short(account) + '. Switch the wallet to that account and try again.'
        );
      }
      permitSig = me.permit.typedDataAvailable && me.permit.typedData
        ? await signTyped(me.permit.typedData)
        : await usable.request({ method: 'personal_sign', params: [me.permit.digest, account] });
      go.textContent = 'One more signature…';
      bundleSig = await signTyped(me.bundle.typedData);
      go.textContent = 'Submitting…';
      // The wallet's own account list travels with the signatures: a mismatch is almost always a
      // wallet signing with an account other than the one it reported, and the answer names it.
      const accounts = await usable.request({ method: 'eth_accounts' }).catch(() => null);
      const body = { signature: bundleSig, permitSignature: permitSig, accounts };
      if (me.role === 'maker') await post('/offers/' + id + '/signature', { role: 'maker', ...body });
      else await post('/offers/' + id + '/accept', body);
      await load();
      if (me.role === 'taker') poll();
    } catch (err) {
      failure = describe(err);
      go.disabled = false;
      go.textContent = 'Try again';
      render();
    }
  };
  app.append(go);

  if (me.role === 'maker') {
    const share = window.location.href;
    app.append(frag('<div class="step"><b>Send this to the other party</b>' +
      '<div class="link"><input readonly value="' + share + '">' +
      '<button class="ghost" style="width:auto">Copy</button></div></div>'));
    app.querySelector('.link button').onclick = (event) =>
      navigator.clipboard.writeText(share).then(() => (event.target.textContent = 'Copied'));
  }

  if (offer.status === 'settling' || offer.orderUid) {
    app.append(frag('<div class="note">Order is with the solvers.<div class="bar"><i></i></div></div>'));
  }

  app.append(frag('<details><summary>Verify independently</summary>' +
    '<p class="addr">offer ' + id + ' · order owner ' + me.bundle.typedData.domain.verifyingContract + '</p>' +
    '<p class="addr">bundle digest ' + me.bundle.digest + '</p>' +
    (me.permit.digest ? '<p class="addr">permit digest ' + me.permit.digest + '</p>' : '') +
    '</details>'));
}

function signTyped(typedData) {
  return usable.request({ method: 'eth_signTypedData_v4', params: [account, JSON.stringify(typedData)] });
}

function poll() {
  const timer = setInterval(async () => {
    const s = await get('/offers/' + id + '/status');
    document.getElementById('status').textContent = s.status;
    if (s.status === 'settled') { clearInterval(timer); load(); }
  }, 3000);
}

load();
</script>
</html>`;
