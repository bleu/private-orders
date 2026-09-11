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
  .tick{color:var(--ok);font-weight:700}
  small,.muted{color:var(--muted)}
  .addr{font-family:ui-monospace,monospace;font-size:.8rem;color:var(--muted);word-break:break-all}
  button{font:inherit;font-weight:600;border:0;border-radius:10px;padding:.7rem 1rem;background:var(--accent);
         color:#fff;width:100%;cursor:pointer}
  button{margin-top:.8rem}
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
<p class="sub"><span id="status" class="pill">loading</span> <span id="gas"></span></p>

<div id="app"></div>

<script>
const id = ${JSON.stringify(id)};
// Returns a fragment, not a single element: several callers pass more than one top-level node and
// dropping the rest is a silent way to lose a whole section.
const el = (h) => { const t = document.createElement('template'); t.innerHTML = h.trim(); return t.content; };
const get = async (p) => (await fetch(p)).json();
const post = async (p, body) => {
  const res = await fetch(p, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
  const out = await res.json();
  if (!res.ok) throw new Error(out.error || res.statusText);
  return out;
};

let offer = null, me = null, account = null, permitSig = null, bundleSig = null;

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
  document.getElementById('gas').innerHTML = '<span class="pill ok">you pay no gas</span>';
  render();
  if (account) await loadRole();
}

async function loadRole() {
  me = await get('/offers/' + id + '/role?address=' + account);
  render();
}

function connect() {
  if (!window.ethereum) return window.alert('No wallet found. Open this link in a wallet browser, or install one.');
  window.ethereum.request({ method: 'eth_requestAccounts' }).then(([a]) => { account = a; loadRole(); });
}

const signTyped = (typedData) =>
  window.ethereum.request({ method: 'eth_signTypedData_v4', params: [account, JSON.stringify(typedData)] });

// The public view is written from the maker's side. Until we know who is asking, the labels stay
// neutral; once we do, they are the reader's own.
function terms() {
  const t = offer.terms;
  const mine = me && me.role;
  const pay = mine === 'taker' ? [t.buyAmount, t.buyDecimals, t.buySymbol] : [t.sellAmount, t.sellDecimals, t.sellSymbol];
  const get_ = mine === 'taker' ? [t.sellAmount, t.sellDecimals, t.sellSymbol] : [t.buyAmount, t.buyDecimals, t.buySymbol];
  const label = (mine) => (mine ? ['You pay', 'You receive'] : ['One side gives', 'The other gives']);
  const [payLabel, getLabel] = label(mine);
  return el(\`
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

  if (!account) {
    app.append(el('<div class="step"><b>Connect the wallet this trade is with.</b>' +
      '<p class="sub" style="margin:.4rem 0 .8rem">The terms above are public to anyone holding the link. ' +
      'Your side of it appears once the wallet is connected.</p></div>'));
    const b = el('<button>Connect wallet</button>');
    b.onclick = connect;
    app.append(b);
    return;
  }

  if (!me || !me.role) {
    app.append(el('<div class="note">Connected as <span class="addr">' + short(account) + '</span>, ' +
      'which is not a party to this trade. Switch accounts if that is unexpected.</div>'));
    return;
  }

  if (me.role === 'taker' && !me.makerSigned) {
    app.append(el('<div class="note warn">Waiting for the other party to sign. The link is ready — ' +
      'nothing happens until they do.</div>'));
  }

  // The counterparty, once we know who is asking.
  app.append(el('<h2>Counterparty</h2><div class="trade"><div class="row">' +
    '<span class="addr">' + me.counterparty + '</span></div></div>'));

  const side = me.role;
  const funded = BigInt(me.balance) >= BigInt(me.permit.amount);

  app.append(el('<h2>Your part</h2>'));
  app.append(el('<div class="step"><span class="n">1</span><b>Allow ' +
    amount(me.permit.amount, me.permit.decimals) + ' ' + me.permit.symbol + '</b>' +
    '<p class="sub" style="margin:.4rem 0 0">Signs a permit so your own Shed can hold the tokens. ' +
    'It cannot move them anywhere else, and anyone may submit it.</p></div>'));

  app.append(el('<div class="step"><span class="n">2</span><b>Authorise the trade</b>' +
    '<p class="sub" style="margin:.4rem 0 0">Creates the order for exactly this pair, at exactly these amounts. ' +
    'Nothing else can fill it.</p></div>'));

  app.append(el('<div class="note">Your wallet holds ' +
    amount(me.balance, me.permit.decimals) + ' ' + me.permit.symbol +
    (funded ? ' <span class="ok">— enough</span>' : ' <span class="warn">— you need ' +
      amount(me.permit.amount, me.permit.decimals) + '</span>') + '</div>'));

  if (offer.status === 'settled') {
    app.append(el('<div class="note">Settled. ' + (offer.orderUid ? 'Order <span class="addr">' + short(offer.orderUid) + '</span>' : '') + '</div>'));
    return;
  }

  const go = el('<button>' + (side === 'maker' ? 'Sign and get the link' : 'Sign and settle') + '</button>');
  go.disabled = !funded;
  go.onclick = async () => {
    go.disabled = true; go.textContent = 'Waiting for your wallet…';
    try {
      permitSig = me.permit.typedDataAvailable && me.permit.typedData
        ? await signTyped(me.permit.typedData)
        : await window.ethereum.request({ method: 'personal_sign', params: [me.permit.digest, account] });
      go.textContent = 'Second signature…';
      bundleSig = await signTyped(me.bundle.typedData);
      go.textContent = 'Submitting…';
      const body = { signature: bundleSig, permitSignature: permitSig };
      if (side === 'maker') await post('/offers/' + id + '/signature', { role: 'maker', ...body });
      else await post('/offers/' + id + '/accept', body);
      await load();
      if (side === 'taker') poll();
    } catch (err) {
      go.disabled = false; go.textContent = 'Try again';
      app.append(el('<div class="note warn">' + err.message + '</div>'));
    }
  };
  app.append(go);

  if (side === 'maker') {
    const share = window.location.href;
    app.append(el('<div class="step"><b>Send this to the other party</b>' +
      '<div class="link"><input readonly value="' + share + '"><button class="ghost" style="width:auto">Copy</button></div></div>'));
    app.querySelector('.link button').onclick = (e) => navigator.clipboard.writeText(share).then(() => (e.target.textContent = 'Copied'));
  }

  if (offer.status === 'settling' || offer.orderUid) {
    app.append(el('<div class="note">Order is with the solvers.' +
      '<div class="bar"><i></i></div></div>'));
  }

  const details = el('<details><summary>Verify independently</summary>' +
    '<p class="addr">offer ' + id + ' · order owner ' + me.bundle.typedData.domain.verifyingContract + '</p>' +
    '<p class="addr">bundle digest ' + me.bundle.digest + '</p>' +
    (me.permit.digest ? '<p class="addr">permit digest ' + me.permit.digest + '</p>' : '') +
    '</details>');
  app.append(details);
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
