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

/// Both pages share one stylesheet.
const CSS = `
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
`;

/// A wallet that asks the service to sign with a key it was given, so the flow can be driven in a
/// browser without an extension. Off unless the service was started with development keys, and it
/// will only sign for the addresses it holds.
const devWalletShim = (enabled) => (enabled ? `
<script>
(function () {
  // The dev-wallet shim reports the chain the trade should be on, so a chain mismatch is testable
  // without a second chain: '?chain=0x1' against a trade signed for another one.
  const account = new URLSearchParams(location.search).get('devwallet');
  const chain = new URLSearchParams(location.search).get('chain') || '0x1';
  if (!account) return;
  // Which account the wallet will sign with. Switched by a test through useAccount, the way a
  // reader switches it in the wallet itself.
  let current = account;
  const sign = async (body) => {
    const res = await fetch('/dev/sign', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
    const out = await res.json();
    if (!res.ok) throw new Error(out.error || 'the development wallet could not sign');
    return out.signature;
  };
  const provider = {
    isDevWallet: true,
    on() {},
    // A development affordance, the same shape as a real wallet holding several keys: the page's
    // pre-signature account check exists because a wallet signs with whichever account is selected.
    useAccount(next) { current = next; },
    request: async ({ method, params }) => {
      if (method === 'eth_requestAccounts' || method === 'eth_accounts') return [current];
      if (method === 'eth_chainId') return chain;
      if (method === 'eth_signTypedData_v4') return sign({ address: current, typedData: JSON.parse(params[1]) });
      if (method === 'personal_sign') return sign({ address: current, message: params[0] });
      if (method === 'eth_sendTransaction') {
        const tx = params[0];
        const res = await fetch('/dev/send', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ from: tx.from, to: tx.to, data: tx.data }) });
        const out = await res.json();
        if (!res.ok) throw new Error(out.error || 'the development wallet could not send that transaction');
        return out.transactionHash;
      }
      throw new Error('the development wallet does not implement ' + method);
    },
  };
  const announce = () => window.dispatchEvent(new CustomEvent('eip6963:announceProvider', {
    detail: { info: { uuid: 'dev-wallet', name: 'Development wallet' }, provider },
  }));
  window.addEventListener('eip6963:requestProvider', announce);
  window.__devWallet = provider;
})();
</script>` : '');

export const render = (id, options = {}) => `<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Private trade</title>
<style>${CSS}</style>

<h1>Private trade</h1>
<p class="sub"><span id="status" class="pill">loading</span> <span class="pill ok">you pay no gas</span></p>

<div id="app"></div>
${devWalletShim(options.devWallet)}
<script>
const id = ${JSON.stringify(id)};

// A fragment, so a caller can pass several top-level nodes. Anything needing a handle on a single
// element asks for it with node().
const frag = (h) => { const t = document.createElement('template'); t.innerHTML = h.trim(); return t.content; };
const node = (h) => frag(h).firstElementChild;

// Everything on this page that came from outside — a token's symbol, a wallet's name, an error
// string, an address, a transaction hash — arrives as text, through here. The page exists to show a
// reader what they are about to sign, and a token's symbol is chosen by whoever deployed the token:
// unescaped, an image tag in a symbol is a script running on a signing page.
const esc = (value) =>
  String(value).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const get = async (p) => (await fetch(p)).json();
let synthetic = [];
let probeCache = [];
get('/probes').then((list) => { synthetic = list; });
const post = async (p, body) => {
  const res = await fetch(p, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
  const out = await res.json();
  if (!res.ok) throw new Error(out.error || res.statusText);
  return out;
};

// Declared up front: a read of an undeclared name throws, while an assignment to one silently
// creates a global — so a missing declaration shows up as a broken render, not a missing value.
let offer = null, me = null, account = null, usable = null, walletName = null, failure = null;
let check = null, probeResults = [], plan = null, moved = null;
let permitSig = null, bundleSig = null, walletChain = null;

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
    usable.on?.('accountsChanged', (list) => { account = list[0] ?? null; me = null; loadRole(); });
    usable.on?.('chainChanged', (hex) => { walletChain = hex ?? null; loadRole(); });
    // Read once at connect, so a wallet on the wrong network is a sentence before the first
    // signature rather than a rejected order several steps later.
    walletChain = await usable.request({ method: 'eth_chainId' }).catch(() => null);
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
  // Always merge the status: the settlement transaction exists only once it is settled.
  offer = { ...offer, ...(await get('/offers/' + id + '/status')) };
  document.getElementById('status').textContent = offer.status;
  document.getElementById('status').className = 'pill' + (offer.status === 'settled' ? ' ok' : '');
  render();
  // A wallet that is already authorised is restored without a prompt.
  const existing = wallets()[0];
  if (existing) {
    try {
      const [first] = await existing.provider.request({ method: 'eth_accounts' });
      if (first) {
        usable = existing.provider; walletName = existing.name; account = first;
        walletChain = await usable.request({ method: 'eth_chainId' }).catch(() => null);
        await loadRole();
      }
    } catch { /* a wallet that refuses this is still connectable by button */ }
  }
}

async function loadRole() {
  if (!account) return render();
  me = await get('/offers/' + id + '/role?address=' + account);
  // What is sitting in this party's Shed, so a settled trade can end with the money in their wallet
  // rather than in a contract they have no way to reach.
  plan = me.role
    ? await get('/offers/' + id + '/withdraw?address=' + account).catch(() => null)
    : null;
  render();
}

/// Poll the role view until the Shed's allowance covers the trade. The approve transaction's hash is
/// not evidence that it worked — the allowance is, and a replaced or dropped approval shows up here
/// as the allowance that never arrived.
async function waitForAllowance() {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const fresh = await get('/offers/' + id + '/role?address=' + account).catch(() => null);
    if (fresh) {
      me = fresh;
      if (BigInt(fresh.allowance ?? '0') >= BigInt(fresh.permit.amount)) return true;
    }
    await new Promise((resume) => setTimeout(resume, 1500));
  }
  return false;
}

/// Symbol and decimals for a token address, using what the trade already told us about its two.
function tokenOf(address) {
  const t = offer.terms;
  if (address.toLowerCase() === t.sellToken.toLowerCase()) return { symbol: t.sellSymbol, decimals: t.sellDecimals };
  if (address.toLowerCase() === t.buyToken.toLowerCase()) return { symbol: t.buySymbol, decimals: t.buyDecimals };
  return { symbol: address.slice(0, 6) + '…', decimals: 18 };
}

// The public view is written from the maker's side. Until we know who is asking, the labels stay
// neutral; once we do, they are the reader's own.
function terms() {
  const t = offer.terms;
  const mine = me && me.role;
  const pay = mine === 'taker' ? [t.buyAmount, t.buyDecimals, t.buySymbol] : [t.sellAmount, t.sellDecimals, t.sellSymbol];
  const get_ = mine === 'taker' ? [t.sellAmount, t.sellDecimals, t.sellSymbol] : [t.buyAmount, t.buyDecimals, t.buySymbol];
  const settled = offer.status === 'settled';
  const [payLabel, getLabel] = settled
    ? ['You paid', 'You received']
    : mine
      ? ['You pay', 'You receive']
      : ['One side gives', 'The other gives'];
  return frag(\`
    <div class="trade">
      <div class="row"><span>\${payLabel}</span><span class="amt">\${esc(amount(pay[0], pay[1]))} \${esc(pay[2])}</span></div>
      <div class="row"><span>\${getLabel}</span><span class="amt">\${esc(amount(get_[0], get_[1]))} \${esc(get_[2])}</span></div>
      \${settled ? '' : '<div class="row"><small>Expires</small><small>' + esc(until(t.expiresAt)) + '</small></div>'}
    </div>\`);
}

function render() {
  const app = document.getElementById('app');
  app.replaceChildren();
  if (!offer) return;
  app.append(terms());
  if (failure) app.append(frag('<div class="note warn">' + esc(failure) + '</div>'));

  if (!account) {
    const found = wallets();
    app.append(frag('<div class="step"><b>Connect the wallet this trade is with.</b>' +
      '<p class="sub" style="margin:.4rem 0 0">The terms above are public to anyone holding the link. ' +
      'Your side of it appears once the wallet is connected.</p></div>'));
    for (const wallet of found) {
      const b = node('<button>Connect ' + esc(wallet.name) + '</button>');
      b.onclick = () => connect(wallet);
      app.append(b);
    }
    if (!found.length) {
      app.append(frag('<div class="note warn">No wallet detected on this page.' +
        '<p class="sub" style="margin:.5rem 0 0">If one is installed, check that the extension can reach ' +
        'this site — some wallets are disabled on <code>localhost</code> until allowed — or open the link ' +
        'inside the wallet\\'s own browser.</p>' +
        '<p class="sub" style="margin:.5rem 0 0">EIP-6963 announcements seen: ' + esc(discovered.length) + '.</p></div>'));
    }
    return;
  }

  app.append(frag('<div class="note">Connected as <span class="addr">' + esc(short(account)) + '</span>' +
    (walletName ? ' with ' + esc(walletName) : '') +
    (check
      ? '<br>Signs as <span class="addr">' + esc(check.recovered ? short(check.recovered) : 'unreadable') + '</span> ' +
        (check.matches ? '<span class="ok">— matches</span>' : '<span class="warn">— DIFFERENT from the connected account</span>')
      : '') +
    '</div>'));

  if (!me || !me.role) {
    app.append(frag('<div class="note warn">This wallet is not a party to the trade. ' +
      'Switch accounts in the wallet if that is unexpected.</div>'));
    return;
  }

  if (me.role === 'taker' && !me.makerSigned) {
    app.append(frag('<div class="note">Waiting for the other party to sign. The link is ready — ' +
      'nothing happens until they do.</div>'));
  }

  // Deliberately the other party's Shed and not their wallet: this link is a bearer token, so
  // publishing the person's address to anyone holding it would be worse than publishing a contract
  // that only owns their order. But an address labelled "counterparty" reads like the person you are
  // dealing with, and it is not one — so the label says what it is.
  app.append(frag('<h2>The other side</h2><div class="trade">' +
    '<div class="row"><span>Their order owner</span></div>' +
    '<div class="row"><span class="addr">' + esc(me.counterparty) + '</span></div>' +
    '<p class="sub" style="margin:.5rem 0 0">A CoW Shed — the contract that holds their order, not their ' +
    'wallet. Anyone holding this link can read it, so their wallet address is not published.</p></div>'));

  if (offer.status === 'settled') {
    app.append(frag('<h2>Receipt</h2><div class="trade">' +
      '<div class="row"><span>Settlement</span><span class="addr">' +
      esc(offer.settlementTx ? offer.settlementTx : 'recorded, transaction not found') + '</span></div>' +
      '<div class="row"><small>Order</small><small class="addr">' + esc(short(offer.orderUid ?? '')) + '</small></div>' +
      '</div>'));
    const held = plan && !plan.empty ? plan.amounts.map((a, i) => ({ ...tokenOf(plan.targets[i]), amount: a })) : [];
    if (moved) {
      app.append(frag('<div class="note ok">Moved to your wallet.</div>'));
    } else if (!held.length) {
      app.append(frag('<div class="note">Your Shed is empty — everything is in your wallet.</div>'));
    } else {
      const what = held.map((h) => esc(amount(h.amount, h.decimals)) + ' ' + esc(h.symbol)).join(' and ');
      app.append(frag('<div class="note">' + what + ' ' + (held.length > 1 ? 'are' : 'is') +
        ' still in your Shed: ' + (held.length > 1 ? 'tokens' : 'a token') + ' this trade did not spend. ' +
        'One signature moves ' + (held.length > 1 ? 'them' : 'it') + ' to your wallet, and you still pay no gas.</div>'));
      const move = node('<button>Move ' + what + ' to my wallet</button>');
      move.onclick = async () => {
        move.disabled = true;
        move.textContent = 'Check your wallet…';
        try {
          failure = null;
          const [active] = await usable.request({ method: 'eth_accounts' });
          if (!active || active.toLowerCase() !== account.toLowerCase()) {
            throw new Error('The active account in your wallet is ' + (active ? short(active) : 'not set') +
              ', but this trade is with ' + short(account) + '.');
          }
          const signature = await signTyped(plan.typedData);
          await post('/offers/' + id + '/withdraw', { address: account, signature });
          moved = true;
          await loadRole();
        } catch (err) {
          failure = describe(err);
          render();
        }
      };
      app.append(move);
    }
    return;
  }

  // One signature per press. Four queued prompts is where wallets stall, and a stall is
  // indistinguishable from a wallet that cannot sign the message at all.
  const done = probeResults.length >= probeNames().length;
  const diag = node('<button class="ghost">' +
    (done
      ? 'Diagnostics complete'
      : probeResults.length
        ? 'Run probe ' + (probeResults.length + 1) + ' of ' + probeNames().length
        : 'Run wallet diagnostics') +
    '</button>');
  diag.disabled = done;
  diag.onclick = async () => {
    diag.disabled = true;
    diag.textContent = 'Check your wallet…';
    try {
      const probe = probeNames()[probeResults.length];
      const signature = await signTyped(probe.typedData);
      const out = await post('/probes', {
        address: account,
        signatures: [{ name: probe.name, typedData: probe.typedData, signature }],
      });
      probeResults.push(out.results[0]);
    } catch (err) {
      failure = describe(err);
    }
    render();
  };

  // What funding this side takes. A permit is one signature; an approve is one transaction first.
  // The server decides which case it is and describes the transaction, so this page never has to
  // infer it from a token — or assemble a transaction of its own.
  const funding = me.funding ?? { mode: 'permit' };
  const approving = funding.mode === 'approve';
  const unlimited = me.permit.unlimited === true;
  const amount_ = esc(amount(me.permit.amount, me.permit.decimals)) + ' ' + esc(me.permit.symbol);
  const approved = BigInt(me.allowance ?? '0') >= BigInt(me.permit.amount);
  const funded = BigInt(me.balance) >= BigInt(me.permit.amount);
  const wantChain = Number(me.bundle.typedData.domain.chainId);
  const wrongChain = walletChain !== null && Number(walletChain) !== wantChain;
  const owner = me.owner ?? { address: account, isContract: false };
  const ready = me.ready ?? { ok: true, problems: [], checks: [] };
  // How many times the wallet will be asked, said before the first prompt rather than discovered
  // halfway through. A permit is two signatures; an approval is a transaction and then a signature.
  const prompts = approving ? 'a transaction, then a signature' : 'two signatures';

  // The allowance is stated as what it is. A DAI-style permit carries 'allowed: true' and no amount,
  // so it grants the maximum; calling that "exactly this amount" would be a false claim on a page
  // whose whole job is to say what the reader is about to authorise.
  const stepOne = approving
    ? 'One transaction: approve your own Shed for exactly ' + amount_ + '. ' + esc(funding.reason ?? '') + '.'
    : unlimited
      ? 'Signs a permit that lets your own Shed move any amount of this token, until you revoke it. It still cannot move them anywhere but your Shed, and anyone may submit it.'
      : 'Signs a permit that lets your own Shed move exactly ' + amount_ + ', and nothing else. It cannot move them anywhere else, and anyone may submit it.';

  if (wrongChain) {
    app.append(frag('<div class="note warn">Your wallet is on chain ' + esc(Number(walletChain)) +
      ', but this trade is on chain ' + esc(wantChain) + '. A signature made now would be rejected there. ' +
      'Switch the network in the wallet, then reload.</div>'));
  } else if (walletChain === null) {
    app.append(frag('<div class="note warn">This page could not read the wallet’s chain id, so it cannot ' +
      'check that the wallet is on chain ' + esc(wantChain) + '. The signature will be rejected if it is not.</div>'));
  }

  app.append(frag('<h2>Your part</h2>'));

  // What is already known to be wrong, before any prompt. A signature that cannot lead anywhere is
  // not a favour to anyone, and a wallet prompt is expensive to take back.
  if (!ready.ok) {
    app.append(frag('<div class="note warn"><b>This offer cannot settle as it stands.</b>' +
      ready.problems.map((problem) => '<br>— ' + esc(problem)).join('') + '</div>'));
  }

  // What this wallet's kind means, said before the first prompt instead of after a failure.
  if (owner.isContract) {
    app.append(frag('<div class="note">This wallet is a smart contract account, not an account with a key. ' +
      'It approves its Shed with a transaction, and it authorises the order through its own signature check. ' +
      (ready.account && ready.account.threshold > 1
        ? '<br><span class="warn">Its rules need ' + esc(ready.account.threshold) + ' signatures over the same ' +
          'message, and this page cannot collect them yet.</span>'
        : '') + '</div>'));
  }

  app.append(frag('<div class="note">Your wallet will ask ' + esc(prompts) + '.' +
    (approving
      ? ' The transaction only approves your own Shed; the signature is the trade.'
      : ' The first prompt only lets your own Shed hold the tokens; the second is the trade itself.') +
    ' Nothing you sign costs gas.</div>'));
  app.append(frag('<div class="step' + ((approving ? approved : permitSig) ? ' done' : '') + '"><span class="n">1</span><b>' +
    (approving ? 'Approve your Shed' : 'Allow ' + amount_) + '</b>' +
    '<p class="sub" style="margin:.4rem 0 0">' + stepOne + '</p></div>'));
  app.append(frag('<div class="step' + (bundleSig ? ' done' : '') + '"><span class="n">2</span><b>Authorise the trade</b>' +
    '<p class="sub" style="margin:.4rem 0 0">Creates the order for exactly this pair, at exactly these amounts. ' +
    'Nothing else can fill it, and nothing moves until the other party accepts.</p></div>'));
  if (!check) {
    const checkBtn = node('<button class="ghost">Check the wallet signs with the connected account</button>');
    checkBtn.onclick = async () => {
      checkBtn.disabled = true;
      checkBtn.textContent = 'Check your wallet…';
      try {
        await runMessageCheck();
      } catch (err) {
        failure = describe(err);
      }
      render();
    };
    app.append(checkBtn);
  }

  app.append(frag('<div class="note">Your wallet holds ' + esc(amount(me.balance, me.permit.decimals)) + ' ' +
    esc(me.permit.symbol) + (funded ? ' <span class="ok">— enough</span>'
      : ' <span class="warn">— you need ' + esc(amount(me.permit.amount, me.permit.decimals)) + '</span>') + '</div>'));

  // Only an approve path has an allowance worth reading before anything is signed: a permit's
  // allowance does not exist until the relayer submits the permit the reader is about to sign.
  if (approving) {
    app.append(frag('<div class="note">Your Shed may currently move ' +
      (approved ? esc(amount(me.allowance, me.permit.decimals)) + ' ' + esc(me.permit.symbol) : 'nothing') +
      '.</div>'));
  }

  if (offer.status === 'settled') {
    app.append(frag('<div class="note ok">Settled.' +
      (offer.settlementTx ? '<br>Transaction <span class="addr">' + esc(offer.settlementTx) + '</span>' : '') +
      '<br><span class="muted">The proceeds were paid to your wallet, not your Shed.</span></div>'));
    return;
  }

  if (me.role === 'taker') {
    app.append(frag('<div class="note">Accepting funds both Sheds and puts the order on the book. This is the ' +
      'moment both sides commit: the maker\u2019s tokens move out of their wallet at the same time as yours.</div>'));
  }

  const go = node('<button>' + (approving
    ? 'Approve and sign'
    : me.role === 'maker' ? 'Sign and get the link' : 'Sign and settle') + '</button>');
  go.disabled = !funded || wrongChain || !ready.ok;
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

      if (approving && !approved) {
        go.textContent = 'Approve in your wallet…';
        await usable.request({
          method: 'eth_sendTransaction',
          params: [{
            from: account,
            to: funding.approve.to,
            data: funding.approve.data,
            value: funding.approve.value ?? '0x0',
          }],
        });
        go.textContent = 'Waiting for the approval…';
        if (!(await waitForAllowance())) {
          throw new Error('The approval transaction did not leave your Shed with this allowance. ' +
            'If it was replaced, dropped, or signed by another account, try again.');
        }
      }

      if (!approving) {
        go.textContent = 'Check your wallet…';
        permitSig = await signTyped(me.permit.typedData);
        go.textContent = 'One more signature…';
      }
      bundleSig = await signTyped(me.bundle.typedData);
      go.textContent = 'Submitting…';
      // The wallet's own account list travels with the signatures: a mismatch is almost always a
      // wallet signing with an account other than the one it reported, and the answer names it.
      const accounts = await usable.request({ method: 'eth_accounts' }).catch(() => null);
      const body = { signature: bundleSig, accounts };
      if (!approving) body.permitSignature = permitSig;
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

  // Only once the signature is in: handing out a link for an offer nobody has signed is how a
  // failed signature looks like a successful one.
  if (me.role === 'maker' && me.signed) {
    // The canonical offer URL, without whatever this session carried in its query string: a link
    // that says which wallet *I* am must not be the link I hand to the other party.
    const share = location.origin + '/o/' + id;
    app.append(frag('<div class="step"><b>Send this to the other party</b>' +
      '<div class="link"><input readonly value="' + esc(share) + '">' +
      '<button class="ghost" style="width:auto">Copy</button></div></div>'));
    // The scariest moment in the flow is the one right after signing, when nothing appears to happen.
    app.append(frag('<div class="note">Nothing has moved yet. Your tokens leave your wallet only when the ' +
      'other party accepts, and until then this is an offer they can take or ignore.</div>'));
    app.querySelector('.link button').onclick = (event) =>
      navigator.clipboard.writeText(share).then(() => (event.target.textContent = 'Copied'));
  }

  if (offer.status === 'settling' || offer.orderUid) {
    app.append(frag('<div class="note">Order is with the solvers.<div class="bar"><i></i></div></div>'));
  }

  if (probeResults.length) {
    app.append(frag('<div class="note"><b>Typed-data probes</b>' + probeResults
      .map((r) => '<br>' + (r.ok ? '<span class="ok">ok</span>' : '<span class="warn">failed</span>') + ' — ' + esc(r.name))
      .join('') + '</div>'));
  }
  app.append(diag);

  app.append(frag('<details><summary>Verify independently</summary>' +
    '<p class="addr">offer ' + esc(id) + ' · order owner ' + esc(me.bundle.typedData.domain.verifyingContract) + '</p>' +
    '<p class="addr">bundle digest ' + esc(me.bundle.digest) + '</p>' +
    (me.permit.digest ? '<p class="addr">permit digest ' + esc(me.permit.digest) + '</p>' : '') +
    (ready.checks.length
      ? '<p class="addr">checked before signing:<br>' +
        ready.checks.map((entry) => (entry.ok ? 'ok ' : 'FAILED ') + esc(entry.name) + (entry.detail ? ' (' + esc(entry.detail) + ')' : '')).join('<br>') + '</p>'
      : '') +
    '</details>'));
}

/// The two synthetic probes, then the two real messages for this trade. A synthetic pass with a
/// real failure points at the payload; a synthetic failure means the wallet is not hashing what it
/// shows.
function probeNames() {
  if (!probeCache.length) {
    // Only the messages this side actually has to sign: an approve-funded trade has no permit to
    // probe, and a probe over nothing reads as a wallet failure.
    probeCache = [
      ...synthetic,
      { name: '3. the permit for this trade', typedData: me.permit.typedData },
      { name: '4. the order authorisation for this trade', typedData: me.bundle.typedData },
    ].filter((probe) => probe.typedData);
  }
  return probeCache;
}

/// A plain message, not typed data. It separates "the wallet signs with the key it claims" from
/// "the wallet hashed a different message" — the probe results only mean something once this is
/// known. Asked for deliberately, never on connect.
async function runMessageCheck() {
  const message = 'private-trade wallet check';
  const signature = await usable.request({ method: 'personal_sign', params: [message, account] });
  const chainId = await usable.request({ method: 'eth_chainId' }).catch(() => null);
  check = await post('/wallet-check', { address: account, message, signature, chainId });
}

function signTyped(typedData) {
  // A JSON *string*. Rabby rejects the object form with -32602 "data is not a valid JSON string",
  // so this is not a stylistic choice: it is what this wallet requires.
  return usable.request({ method: 'eth_signTypedData_v4', params: [account, JSON.stringify(typedData)] });
}

function poll() {
  // One failed request used to end the loop silently, which is indistinguishable from a trade that
  // never settles. Keep polling, and say so if it keeps failing.
  let failures = 0;
  const timer = setInterval(async () => {
    try {
      const s = await get('/offers/' + id + '/status');
      failures = 0;
      document.getElementById('status').textContent = s.status;
      if (s.status === 'settled') {
        clearInterval(timer);
        await load();
        return;
      }
      const note = document.getElementById('waiting');
      if (note) note.textContent = 'Waiting for a solver to settle this. Usually under a minute.';
    } catch (err) {
      failures += 1;
      const note = document.getElementById('waiting');
      if (note && failures > 2) note.textContent = 'Still checking… (' + (err.message || err) + ')';
    }
  }, 3000);
}

load();
</script>
</html>`;


/// The maker's page: describe the trade, get a link, sign, share.
export const renderCreate = ({ devWallet, defaults }) => `<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Offer a private trade</title>
<style>${CSS}
  label{display:block;font-size:.85rem;color:var(--muted);margin:.9rem 0 .3rem}
  input{width:100%;font:inherit;padding:.6rem .7rem;border:1px solid var(--line);border-radius:10px;
        background:transparent;color:var(--ink)}
  .two{display:flex;gap:.6rem}
  .two>*{flex:1}
</style>

<h1>Offer a private trade</h1>
<p class="sub"><span class="pill ok">you pay no gas</span></p>
<p class="sub" style="margin-top:.6rem">Describe what you will give and what you want back. The other
party opens a link, signs, and the two sides settle together or not at all — no order book, no
auction, and neither of you sends a transaction.</p>

<div id="app"></div>
${devWalletShim(devWallet)}

<script>
const DEFAULTS = ${JSON.stringify(defaults ?? {})};
const el = (h) => { const t = document.createElement('template'); t.innerHTML = h.trim(); return t.content; };
const node = (h) => el(h).firstElementChild;
// Untrusted text arrives as text: a token address or a failure message from the service is not
// markup. Same rule as the trade page.
const esc = (value) =>
  String(value).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const get = async (p) => (await fetch(p)).json();
const post = async (p, body) => {
  const res = await fetch(p, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
  const out = await res.json();
  if (!res.ok) throw new Error(out.error || res.statusText);
  return out;
};
const short = (a) => a.slice(0, 6) + '…' + a.slice(-4);

let account = null, walletName = null, provider = null, failure = null, discovered = [];

window.addEventListener('eip6963:announceProvider', (event) => {
  if (!discovered.some((d) => d.info.uuid === event.detail.info.uuid)) { discovered.push(event.detail); render(); }
});
window.dispatchEvent(new Event('eip6963:requestProvider'));

function wallets() {
  if (discovered.length) return discovered.map((d) => ({ name: d.info.name, provider: d.provider }));
  return window.ethereum ? [{ name: 'Browser wallet', provider: window.ethereum }] : [];
}

async function connect(wallet) {
  try {
    failure = null;
    const [first] = await wallet.provider.request({ method: 'eth_requestAccounts' });
    if (!first) throw new Error('the wallet returned no accounts');
    provider = wallet.provider;
    walletName = wallet.name;
    account = first;
    render();
  } catch (err) {
    failure = err.message || String(err);
    render();
  }
}

function field(label, id, value, placeholder) {
  return el('<label>' + esc(label) + '<input id="' + esc(id) + '" value="' + esc(value || '') + '" placeholder="' + esc(placeholder || '') + '"></label>');
}

function render() {
  const app = document.getElementById('app');
  app.replaceChildren();

  if (failure) app.append(el('<div class="note warn">' + esc(failure) + '</div>'));

  if (!account) {
    app.append(el('<div class="step"><b>Connect the wallet that will hold your side.</b>' +
      '<p class="sub" style="margin:.4rem 0 0">It becomes the maker: your tokens go in, theirs come back, ' +
      'and the link binds to the counterparty you name.</p></div>'));
    const found = wallets();
    for (const wallet of found) {
      const b = node('<button>Connect ' + esc(wallet.name) + '</button>');
      b.onclick = () => connect(wallet);
      app.append(b);
    }
    if (!found.length) app.append(el('<div class="note warn">No wallet detected on this page.</div>'));
    return;
  }

  app.append(el('<div class="note">Connected as <span class="addr">' + esc(short(account)) + '</span>' +
    (walletName ? ' with ' + esc(walletName) : '') + '</div>'));

  app.append(field('You give (token address)', 'sellToken', DEFAULTS.sellToken));
  app.append(field('amount, in the smallest unit', 'sellAmount', '100000000'));
  app.append(field('You want (token address)', 'buyToken', DEFAULTS.buyToken));
  app.append(field('amount, in the smallest unit', 'buyAmount', '100000000000000000000'));
  app.append(field('The wallet you are trading with', 'taker', ''));
  app.append(field('Offer expires in (hours)', 'hours', '24'));

  const go = node('<button>Create the link</button>');
  go.onclick = async () => {
    go.disabled = true;
    go.textContent = 'Creating…';
    try {
      failure = null;
      const value = (id) => document.getElementById(id).value.trim();
      // The offer identity is the maker's to choose, so the browser picks it and the service keeps
      // it: a fresh random 32 bytes, never a timestamp. Without this the order hash, the
      // ComposableCoW salt derived from it, and the hook nonce are all predictable, and two
      // identical offers in the same second collide on a consumed nonce.
      const salt = '0x' +
        Array.from(crypto.getRandomValues(new Uint8Array(32)), (byte) => byte.toString(16).padStart(2, '0')).join('');
      const offer = await post('/offers', {
        maker: account,
        taker: value('taker'),
        sellToken: value('sellToken'),
        sellAmount: value('sellAmount'),
        buyToken: value('buyToken'),
        buyAmount: value('buyAmount'),
        validFor: String(Number(value('hours') || 24) * 3600),
        salt,
      });
      // Keep the query string: it carries which wallet this page is acting as.
      location.href = '/o/' + offer.id + location.search;
    } catch (err) {
      failure = err.message || String(err);
      go.disabled = false;
      go.textContent = 'Create the link';
      render();
    }
  };
  app.append(go);
}

render();
</script>
</html>`;
