#!/usr/bin/env node
// Private trade link service.
//
// Turns an agreed trade into a shareable link and drives it to settlement:
//
//   POST /offers              the maker describes the trade, gets a link and a digest to sign
//   GET  /offers/:id          the link target: terms, plus the digest the taker must sign
//   POST /offers/:id/signature  either party submits its signature
//   POST /offers/:id/accept   the taker accepts; the service relays both bundles and posts the order
//   GET  /offers/:id/status   open / settling / settled, with the settlement transaction
//   GET  /o/:id               a page rendering the link for a human
//
// Two deliberate properties:
//
//   * The service holds no keys that can move value. It relays owner-signed hook bundles, which
//     anyone may do, and posts an order whose signature is an ERC-1271 payload, not a secret. The
//     only signatures it collects are the two parties'.
//   * It never re-derives the trade. `script/LinkCompute.s.sol` is `PrivateTradeBuilder`, so the
//     service cannot drift from the on-chain rules; it just moves JSON and calls `cast`/`forge`.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';

import { render, renderCreate } from './page.mjs';

const PORT = Number(process.env.PORT ?? 9200);
const ROOT = process.env.PRIVATE_TRADE_ROOT ?? path.resolve(import.meta.dirname, '..');
const RPC = process.env.RPC ?? 'http://localhost:8545';
const ORDERBOOK = process.env.ORDERBOOK_URL ?? 'http://localhost:8080';
const STORE = path.join(ROOT, 'out-json', 'link');
// Where the sub-solver looks for private offers. One file per live offer.
const OFFERS_DIR = process.env.SUBSOLVER_OFFERS_DIR ?? path.join(ROOT, 'out-json', 'sub-solver-offers');
const PUBLIC_URL = process.env.PUBLIC_URL ?? `http://localhost:${PORT}`;

// The deploy script writes the addresses it deployed. Reading them as a fallback means the service
// starts correctly by hand, not only when a script exports the environment first.
const deployed = (() => {
  try {
    return JSON.parse(fs.readFileSync(path.join(ROOT, 'out-json', 'private-trade-deployed.json'), 'utf8'));
  } catch {
    return {};
  }
})();

const CONFIG = {
  wrapper: process.env.PRIVATE_TRADE_WRAPPER ?? deployed.wrapper,
  handler: process.env.PRIVATE_TRADE_HANDLER ?? deployed.handler,
  shedFactory: process.env.COWSHED_COMPOSABLE_COW_FACTORY_ADDRESS,
  composableCoW: process.env.COMPOSABLE_COW_ADDRESS,
  authoriser: process.env.PRIVATE_TRADE_AUTHORISER ?? deployed.authoriser,
  vaultRelayer: process.env.VAULT_RELAYER_ADDRESS,
  relayerKey: process.env.RELAYER_PRIVATE_KEY,
  // Pre-filled on the create page, so the whole flow is a few clicks on a known stack.
  defaults: {
    sellToken: process.env.DEFAULT_SELL_TOKEN ?? '',
    buyToken: process.env.DEFAULT_BUY_TOKEN ?? '',
  },
};

// A development wallet: the page can ask this service to sign with a key it was given, which is what
// lets the whole flow be driven in a browser without a wallet extension. Enabled only when keys are
// configured, and it will only sign for the addresses it was handed.
const DEV_KEYS = new Map(
  (process.env.PRIVATE_TRADE_DEV_KEYS ?? '')
    .split(',')
    .filter(Boolean)
    .map((pair) => {
      const [address, key] = pair.split('=');
      return [address.trim().toLowerCase(), key.trim()];
    }),
);
const DEV_WALLET = DEV_KEYS.size > 0;

fs.mkdirSync(STORE, { recursive: true });
fs.mkdirSync(OFFERS_DIR, { recursive: true });

const json = (res, status, body) => {
  const payload = JSON.stringify(body, null, 2);
  res.writeHead(status, { 'content-type': 'application/json' }).end(payload);
};

const readBody = (req) =>
  new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', (chunk) => {
      raw += chunk;
      if (raw.length > 1e6) reject(new Error('body too large'));
    });
    req.on('end', () => {
      try {
        resolve(raw ? JSON.parse(raw) : {});
      } catch (err) {
        reject(new Error(`invalid json: ${err.message}`));
      }
    });
  });

/// Offers with an acceptance running in this process. See the guard in the accept handler.
const accepting = new Set();

const offerPath = (id) => path.join(STORE, `${id}.json`);
const loadOffer = (id) => (fs.existsSync(offerPath(id)) ? JSON.parse(fs.readFileSync(offerPath(id), 'utf8')) : null);
const saveOffer = (offer) => {
  const target = offerPath(offer.id);
  const temporary = `${target}.${process.pid}.${crypto.randomUUID()}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify(offer, null, 2));
  fs.renameSync(temporary, target);
};

function attemptFiles(kind) {
  return fs.mkdtempSync(path.join(STORE, `.${kind}-`));
}

/// Run one `cast`/`forge` call against its own private file, and clean up after it.
///
/// Every invocation that hands a file to `cast` or `forge` goes through here: a fixed path is how
/// two offers interleaved in this process end up verifying or signing each other's messages.
function withScratch(kind, name, contents, run) {
  const directory = attemptFiles(kind);
  const file = path.join(directory, name);
  fs.writeFileSync(file, contents);
  try {
    return run(file);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

function forge(args) {
  return execFileSync('forge', args, { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
}

function cast(args) {
  return execFileSync('cast', args, { cwd: ROOT, encoding: 'utf8' }).trim();
}

/// Whether an address is a contract, remembered per process.
///
/// The owner's kind decides two things the service cannot guess: a token permit can only be signed by
/// an account holding a key, and a contract account answers a signature check over ERC-1271 instead of
/// recovering to an address. A party's owner never changes kind, so one read is enough.
const codeCache = new Map();
function hasCode(address) {
  const key = String(address ?? '').toLowerCase();
  if (!key) return false;
  if (!codeCache.has(key)) {
    try {
      codeCache.set(key, cast(['code', address, '--rpc-url', RPC]).trim() !== '0x');
    } catch {
      // An unreadable chain must not silently turn a contract owner into an EOA: assume code, which
      // routes to the path that asks the owner rather than the one that guesses.
      codeCache.set(key, true);
    }
  }
  return codeCache.get(key);
}

/// Ask the Solidity builder to derive the whole payload. No private key, no transaction.
function compute(request) {
  const directory = attemptFiles('compute');
  const requestFile = path.join(directory, 'request.json');
  const computedFile = path.join(directory, 'computed.json');
  fs.writeFileSync(requestFile, JSON.stringify(request, null, 2));
  try {
    execFileSync('forge', ['script', 'script/LinkCompute.s.sol', '--rpc-url', RPC, '-q'], {
      cwd: ROOT,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, LINK_REQUEST_FILE: requestFile, LINK_COMPUTED_FILE: computedFile },
    });
    return JSON.parse(fs.readFileSync(computedFile, 'utf8'));
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

/// Relay both owner-signed bundles. Permissionless, and safe to retry.
function relay(computed, signatures) {
  const directory = attemptFiles('relay');
  const computedFile = path.join(directory, 'computed.json');
  const signaturesFile = path.join(directory, 'signatures.json');
  fs.writeFileSync(computedFile, JSON.stringify(computed, null, 2));
  fs.writeFileSync(
    signaturesFile,
    JSON.stringify(
      {
        maker: signatures.maker,
        taker: signatures.taker,
        // Empty when the token has no permit; the relay skips those.
        makerPermit: signatures.makerPermit ?? '0x',
        takerPermit: signatures.takerPermit ?? '0x',
      },
      null,
      2,
    ),
  );
  const env = {
    ...process.env,
    RELAYER_PRIVATE_KEY: CONFIG.relayerKey,
    LINK_COMPUTED_FILE: computedFile,
    LINK_SIGNATURES_FILE: signaturesFile,
  };
  let out;
  try {
    // Dry run first. Without `--broadcast`, forge applies the whole script against current state and
    // stops at the first call that would fail — so a signature the Shed refuses, a nonce already
    // spent, or an allowance that never arrived are all reported before a transaction is paid for
    // and before the taker is told the trade is settling. RELAY_DRY_RUN=0 skips the extra pass.
    if (process.env.RELAY_DRY_RUN !== '0') {
      execFileSync('forge', ['script', 'script/LinkRelay.s.sol', '--rpc-url', RPC], {
        cwd: ROOT,
        stdio: ['ignore', 'pipe', 'pipe'],
        env,
      });
    }
    out = execFileSync(
      'forge',
      ['script', 'script/LinkRelay.s.sol', '--rpc-url', RPC, '--broadcast'],
      { cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'], env },
    ).toString();
  } catch (err) {
    // The relay already says why in one line. Everything around it is the command that failed and
    // forge's build notices, which is noise to whoever is holding the link.
    throw new Error(relayReason(String(err.stderr ?? err.message ?? '')));
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }

  // The relay's own lines, returned so a caller can see what happened without reading a log file.
  return out
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.includes('permit applied') || line.includes('digest matches') || line.includes('relayed'));
}

const PROBE_DOMAIN = {
  name: 'PrivateTradeProbe',
  version: '1',
  chainId: 1,
  verifyingContract: '0x0000000000000000000000000000000000000001',
};

/// Diagnostics, not payloads: each probe adds one feature, so the first failure names the culprit.
function probes() {
  return [
    {
      name: '1. one uint256',
      typedData: {
        primaryType: 'Probe',
        domain: PROBE_DOMAIN,
        types: { Probe: [{ name: 'value', type: 'uint256' }] },
        message: { value: '42' },
      },
    },
    {
      name: '2. array of a struct holding bytes',
      typedData: {
        primaryType: 'Probe',
        domain: PROBE_DOMAIN,
        types: {
          Probe: [{ name: 'items', type: 'Item[]' }],
          Item: [
            { name: 'target', type: 'address' },
            { name: 'value', type: 'uint256' },
            { name: 'callData', type: 'bytes' },
            { name: 'allowFailure', type: 'bool' },
            { name: 'isDelegateCall', type: 'bool' },
          ],
        },
        message: {
          items: [
            {
              target: '0x6b175474e89094c44da98b954eedeac495271d0f',
              value: '0',
              callData: '0x095ea7b3000000000000000000000000c92e8bdf79f0507f65a392b0ab4667716bfe0110',
              allowFailure: false,
              isDelegateCall: false,
            },
          ],
        },
      },
    },
  ];
}

/// Sign as a development key. Typed data goes through the same EIP-712 hashing a wallet would do;
/// a plain message is prefixed exactly as `personal_sign` prefixes it.
function devSign(key, { typedData, message }) {
  if (typedData) {
    return withScratch('dev-sign', 'typed-data.json', JSON.stringify(typedData), (file) =>
      cast(['wallet', 'sign', '--data', '--from-file', file, '--private-key', key]).trim(),
    );
  }
  return cast(['wallet', 'sign', '--private-key', key, String(message)]).trim();
}

/// Which side of a trade an address is, or null. Kept in one place so the role view and the
/// withdrawal agree on who may ask for what.
function addressRole(offer, who) {
  if (who === offer.computed.maker.toLowerCase()) return 'maker';
  if (who === offer.request.taker.toLowerCase()) return 'taker';
  return null;
}

/// What the party's Shed holds, as a bundle to sign. Writes the request, runs the computation, and
/// returns the plan — including `empty: true` when there is nothing to move.
function withdrawPlan(offer, role) {
  const side = role === 'maker' ? offer.computed.makerBundle : offer.computed.takerBundle;
  const directory = attemptFiles('withdraw');
  const requestFile = path.join(directory, 'request.json');
  const computedFile = path.join(directory, 'computed.json');
  fs.writeFileSync(
    requestFile,
    JSON.stringify(
      {
        shedFactory: CONFIG.shedFactory,
        shed: side.shed,
        owner: side.owner,
        // Both tokens: a trade can leave the sell side behind if it was not fully spent.
        tokens: [offer.computed.sellToken, offer.computed.buyToken],
      },
      null,
      2,
    ),
  );
  try {
    execFileSync('forge', ['script', 'script/Withdraw.s.sol', '--rpc-url', RPC], {
      cwd: ROOT,
      stdio: 'pipe',
      env: { ...process.env, WITHDRAW_REQUEST_FILE: requestFile, WITHDRAW_COMPUTED_FILE: computedFile },
    });
    const plan = JSON.parse(fs.readFileSync(computedFile, 'utf8'));
    return plan.empty ? { empty: true, shed: side.shed } : { ...plan, shed: side.shed, role };
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

/// Does this signature authorise this exact message, for this owner?
///
/// Returns null when the question cannot be asked (no message, or something too short to be a
/// signature), so a caller can tell "verified false" apart from "not checked".
///
/// A contract owner is asked over ERC-1271 rather than recovered. It decides for itself what a valid
/// signature is — a Safe wraps the digest as a Safe message internally and checks its own owners —
/// and `ecrecover` reports a correct signature from one as an unrelated address. An account holding a
/// key is recovered against the typed data, so the answer is about the message the wallet was shown
/// and not a digest it never saw.
function verifies({ typedData, digest, signature, owner }) {
  const sig = signature ?? '';
  if (!/^0x([0-9a-fA-F]{2})*$/.test(sig) || sig.length < 132) return null;

  if (hasCode(owner)) {
    if (!digest) return null;
    try {
      const result = cast([
        'call', owner, 'isValidSignature(bytes32,bytes)(bytes4)', digest, sig, '--rpc-url', RPC,
      ]);
      return result.toLowerCase().startsWith('0x1626ba7e');
    } catch {
      // EIP-1271 requires the magic value or a revert, so a revert is an answer: not a signature.
      return false;
    }
  }

  if (!typedData || sig.length !== 132) return null;
  return withScratch('verify', 'typed-data.json', JSON.stringify(typedData), (file) => {
    const res = spawnSync(
      'cast',
      ['wallet', 'verify', '--address', owner, '--data', '--from-file', file, sig],
      { encoding: 'utf8' },
    );
    return res.status === 0;
  });
}

/// What shape a signature has to have, which depends on who is signing it.
///
/// An account holding a key produces exactly 65 bytes. A contract account produces whatever its own
/// ERC-1271 implementation accepts: a single-owner Safe still 65, a multi-owner Safe its owners'
/// signatures concatenated in ascending address order, a nested scheme possibly more.
function signatureProblem(owner, signature) {
  const sig = signature ?? '';
  if (!/^0x([0-9a-fA-F]{2})*$/.test(sig) || sig.length < 132) {
    return 'signature must be at least r || s || v, as hex';
  }
  if (hasCode(owner)) return sig.length > 8194 ? 'signature is longer than any ERC-1271 account should return' : null;
  return sig.length === 132 ? null : `a signature from ${owner} must be exactly 65 bytes`;
}

/// Check a party's signatures before anything is relayed.
///
/// The relay verifies them too, but it can only report that a signature recovered to a different
/// address — which is true of every way of getting this wrong. Asking the question here, against the
/// message the page showed, distinguishes "signed the other prompt" from "signed something else
/// entirely", and the wallet's own account list is echoed back because the usual cause is a wallet
/// signing with an account other than the one that connected.
function preflight(offer, role, body) {
  const side = role === 'maker' ? offer.computed.makerBundle : offer.computed.takerBundle;
  const owner = side.owner;
  const problems = [];

  // Some wallets answer two prompts with one signature. Nothing verifies in that case, and the
  // symptom is otherwise identical to a wrong account.
  if (body.permitSignature && body.permitSignature === body.signature) {
    return {
      error: `The ${role}'s wallet returned the same signature for both prompts. Each prompt has to be approved separately.`,
      expectedSigner: owner,
      walletAccounts: body.accounts ?? null,
    };
  }

  // Only when the permit is what funds this side. A token whose permit cannot be presented as typed
  // data is funded by an `approve` transaction, and there is no permit signature to ask for.
  const expectPermit = funding(offer.computed, role).mode === 'permit';
  if (expectPermit && side.permitTypedData) {
    if (
      verifies({ typedData: side.permitTypedData, digest: side.permitDigest, signature: body.permitSignature, owner }) ===
      false
    ) {
      problems.push(
        verifies({ typedData: side.bundleTypedData, digest: side.digest, signature: body.permitSignature, owner })
          ? 'the permit signature is over the order authorisation, so the two prompts were answered in the wrong order'
          : `the permit signature is not a signature of the permit this page showed, by ${owner}`,
      );
    }
  }

  if (verifies({ typedData: side.bundleTypedData, digest: side.digest, signature: body.signature, owner }) === false) {
    problems.push(`the order signature is not a signature of the authorisation this page showed, by ${owner}`);
  }

  if (!problems.length) return null;
  return {
    error: `The ${role}'s signatures do not match this trade: ${problems.join('; ')}.`,
    expectedSigner: owner,
    // Echoed so the reader can see which account the wallet is actually on.
    walletAccounts: body.accounts ?? null,
    hint: 'In the wallet, make the account above the active one — a wallet signs with whichever account is selected, not the one the page connected with.',
  };
}

/// The first `Error: ...` line out of a failed `forge` run, without the invocation around it.
function relayReason(text) {
  const lines = text.split('\n').map((line) => line.trim());
  const reason = lines.find((line) => line.startsWith('Error: ')) ?? lines.find(Boolean) ?? 'the relay failed';
  return reason.replace(/^Error: /, '').split('\n').slice(0, 4).join(' ');
}

async function postOrder(order) {
  const res = await fetch(`${ORDERBOOK}/api/v1/orders`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(order),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`orderbook rejected the order (${res.status}): ${text}`);
  return text.replace(/"/g, '');
}

/// The settlement transaction, looked up from the trade the order produced. A "settled" with no
/// transaction is not much of a receipt.
async function settlementTx(orderUid) {
  try {
    const res = await fetch(`${ORDERBOOK}/api/v1/trades?orderUid=${orderUid}`);
    if (!res.ok) return null;
    const trades = await res.json();
    return Array.isArray(trades) && trades.length ? trades[0].txHash : null;
  } catch {
    return null;
  }
}

async function orderStatus(uid) {
  try {
    const res = await fetch(`${ORDERBOOK}/api/v1/orders/${uid}`);
    if (!res.ok) return { status: 'unknown' };
    return await res.json();
  } catch {
    return { status: 'unknown' };
  }
}

function wrapperOfferState(offerId) {
  if (!CONFIG.wrapper || !offerId) return 'unknown';
  try {
    const value = Number(
      cast(['call', CONFIG.wrapper, 'offerState(bytes32)(uint8)', offerId, '--rpc-url', RPC]).split(' ')[0],
    );
    return ['available', 'consumed', 'cancelled'][value] ?? 'unknown';
  } catch {
    return 'unknown';
  }
}

function transactionReceipt(txHash) {
  if (!txHash) return null;
  try {
    return JSON.parse(cast(['receipt', txHash, '--rpc-url', RPC, '--json']));
  } catch {
    return null;
  }
}

const receiptSucceeded = (receipt) => {
  const status = receipt?.status;
  return status === 1 || status === '1' || status === '0x1';
};

/// ERC-20 `approve(address,uint256)` calldata. Built here, once, so the page sends exactly what the
/// server described instead of assembling a transaction of its own.
const approveCalldata = (spender, amount) => {
  const word = (hex) => hex.replace(/^0x/, '').toLowerCase().padStart(64, '0');
  return `0x095ea7b3${word(spender)}${word(BigInt(amount).toString(16))}`;
};

/// Symbol and decimals, read once per token and kept on the offer. Raw amounts are unreadable —
/// `100000000` is not a price — and a client should never be the one to guess a token's decimals.
/// A string return value as `cast` prints it: a JSON string, so the quotes are a JSON frame and not
/// part of the value. Decoding it is what keeps a symbol containing a quote or a backslash intact —
/// trimming the quotes alone would leave the escapes in the text the page then has to render.
function castString(raw) {
  const trimmed = raw.trim();
  if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
    try {
      return JSON.parse(trimmed);
    } catch {
      return trimmed.replace(/^"|"$/g, '');
    }
  }
  return trimmed;
}

function tokenMeta(offer, token) {
  offer.tokens ??= {};
  const key = token.toLowerCase();
  if (!offer.tokens[key]) {
    offer.tokens[key] = {
      address: token,
      symbol: castString(cast(['call', token, 'symbol()(string)', '--rpc-url', RPC])),
      decimals: Number(cast(['call', token, 'decimals()(uint8)', '--rpc-url', RPC]).split(' ')[0]),
    };
  }
  return offer.tokens[key];
}

const balanceOf = (token, holder) =>
  cast(['call', token, 'balanceOf(address)(uint256)', holder, '--rpc-url', RPC]).split(' ')[0];

/// What `spender` may already move out of `owner`. Read for the Shed the bundle funds: a permit can
/// be front-run, and an `approve` may already be in place, so the fact that matters is the allowance,
/// not which of the two put it there.
const allowanceOf = (token, owner, spender) =>
  cast(['call', token, 'allowance(address,address)(uint256)', owner, spender, '--rpc-url', RPC]).split(' ')[0];

/// The offer's progress, derived from the chain rather than from the service's own bookkeeping.
async function status(offer) {
  const wrapperState = wrapperOfferState(offer.computed?.offerId);
  if (wrapperState === 'cancelled') return { status: 'cancelled', wrapperState };
  if (!offer.orderUid) {
    const expired = Number(offer.computed?.validTo ?? 0) * 1000 < Date.now();
    const phase = offer.acceptance?.phase;
    const pendingStatus = phase === 'failed' ? 'recovery_available' : phase ? phase : offer.signatures?.maker && offer.signatures?.taker ? 'signed' : 'open';
    return { status: expired ? 'expired' : pendingStatus, wrapperState, error: phase === 'failed' ? offer.acceptance.error : undefined };
  }

  const order = await orderStatus(offer.orderUid);
  const txHash = order.status === 'fulfilled' ? await settlementTx(offer.orderUid) : null;
  const receipt = transactionReceipt(txHash);
  const settled = order.status === 'fulfilled' && txHash && receiptSucceeded(receipt) && wrapperState === 'consumed';
  return {
    status: settled ? 'settled' : 'settling',
    orderUid: offer.orderUid,
    settlementTx: txHash,
    wrapperState,
    evidence: {
      orderStatus: order.status ?? 'unknown',
      receiptSucceeded: receipt ? receiptSucceeded(receipt) : null,
      blockNumber: receipt?.blockNumber ?? null,
    },
  };
}

/// What a party must do before signing.
///
/// A token whose permit can be shown as typed data is funded by signature: the party signs, the
/// relayer submits, and they never send a transaction. A token with no permit — or one whose EIP-712
/// domain cannot be reproduced from its own `DOMAIN_SEPARATOR()`, so no wallet can be shown what it
/// is signing — is funded by an ordinary `approve` transaction first.
///
/// So is a party whose owner is a contract. A token permit is verified by `ecrecover` inside the
/// token, so a smart account cannot produce one at all; asking it to sign one costs a prompt and then
/// fails on the allowance, which blames the party for something impossible.
///
/// The cases are reported distinctly, with the calldata to send, so a client never has to guess which
/// one it is in or hand-build a transaction the server should have described.
const funding = (computed, role) => {
  const side = role === 'maker' ? computed.makerBundle : computed.takerBundle;
  const common = { token: side.sellToken, owner: side.owner, spender: side.shed, amount: side.sellAmount };
  const contractOwner = hasCode(side.owner);

  if (contractOwner || side.permitKind === 'none' || side.permitTypedDataAvailable !== true) {
    return {
      mode: 'approve',
      ...common,
      reason: contractOwner
        ? 'this side is a smart contract account, and a token permit can only be signed by an account holding a key'
        : side.permitKind === 'none'
          ? 'this token has no permit'
          : 'this token has a permit, but its typed data cannot be reproduced from its own domain separator, so a wallet cannot be shown what it is signing',
      note: 'approve your Shed, then sign the authorisation. The approval is a transaction, so this side pays gas once.',
      approve: { to: side.sellToken, data: approveCalldata(side.shed, side.sellAmount), value: '0x0' },
      allowance: 'exact',
    };
  }

  // A DAI-style permit carries `allowed: true` and no amount, which sets the allowance to the
  // maximum. Saying "exactly this amount" would be false, so it is said plainly instead.
  const unlimited = side.permitKind === 'dai';
  return {
    mode: 'permit',
    ...common,
    kind: side.permitKind,
    deadline: side.deadline,
    digest: side.permitDigest,
    allowance: unlimited ? 'unlimited' : 'exact',
    note: unlimited
      ? 'sign the permit and the bundle; the relayer submits both, so you need no transaction. This token\u2019s permit has no amount, so it grants your Shed an unlimited allowance until you revoke it.'
      : 'sign the permit and the bundle; the relayer submits both, so you need no transaction.',
    verify: unlimited
      ? 'the allowance is unlimited, but your own Shed holds it and only this offer can spend it'
      : `the permit moves at most ${side.sellAmount} into your own Shed, so publishing it is safe`,
  };
};

/// Everything that can be known before a party signs, so a trade that cannot settle is reported
/// before anyone is asked for a prompt rather than after both of them are.
///
/// Each check is something the settlement itself would refuse on, asked the same way it is asked
/// there. None of them need a signature, which is the point: a dead offer should cost somebody a
/// sentence, not two wallet prompts and a failed relay.
function checksBeforeSigning(offer, role) {
  const computed = offer.computed;
  const side = role === 'maker' ? computed.makerBundle : computed.takerBundle;
  const checks = [];
  const problems = [];
  const account = { address: side.owner, isContract: hasCode(side.owner), threshold: null, owners: null, version: null };
  const record = (name, detail, ok, problem) => {
    checks.push({ name, detail, ok });
    if (!ok) problems.push(problem);
  };

  // The same call the settlement makes, so a payload the wrapper would refuse is caught here instead
  // of reverting later with an opaque error.
  try {
    cast(['call', computed.wrapper, 'validateWrapperData(bytes)', computed.wrapperData, '--rpc-url', RPC]);
    record('the wrapper accepts this offer', null, true, null);
  } catch (err) {
    record(
      'the wrapper accepts this offer',
      null,
      false,
      `the wrapper refuses this offer: ${relayReason(String(err.stderr ?? err.message ?? ''))}`,
    );
  }

  // A bundle cannot call the settlement contract at all without a solver seat, and that is a manager
  // action nobody in this flow can perform. Reading it here turns an opaque revert at settlement
  // time into a sentence before the first prompt.
  try {
    const authenticator = cast(['call', computed.wrapper, 'AUTHENTICATOR()(address)', '--rpc-url', RPC]).trim();
    const allowed = cast(['call', authenticator, 'isSolver(address)(bool)', computed.wrapper, '--rpc-url', RPC]).trim();
    const ok = allowed === 'true';
    record(
      'the wrapper is allowlisted as a solver',
      computed.wrapper,
      ok,
      `the wrapper ${computed.wrapper} is not allowlisted as a solver on this chain, so nothing can settle`,
    );
  } catch {
    // An unreadable authenticator is not evidence of a problem, and guessing here would block a
    // working flow. The settlement still refuses if it really is missing.
    record('the wrapper is allowlisted as a solver', 'not readable', true, null);
  }

  const state = wrapperOfferState(computed.offerId);
  record(
    'the offer is still available',
    state,
    state === 'available',
    state === 'available' ? null : `the offer is ${state}, so it can no longer settle`,
  );

  const expiry = Number(computed.validTo);
  const live = expiry > 0 && expiry * 1000 > Date.now();
  record('the offer has not expired', new Date(expiry * 1000).toISOString(), live, 'the offer has expired');

  // The relay pulls the sell tokens from the party's own account, so a party who does not hold them
  // fails after both signatures are collected. The page shows the balance; this is the same fact
  // stated as a reason.
  try {
    const held = BigInt(balanceOf(side.sellToken, side.owner));
    const ok = held >= BigInt(side.sellAmount);
    record(
      'this side holds what it is selling',
      String(held),
      ok,
      `this side must hold ${side.sellAmount} of ${side.sellToken} before it can fund its Shed`,
    );
  } catch {
    record('this side holds what it is selling', 'not readable', true, null);
  }

  // A contract account's own rules decide how many signatures it needs, and gathering them is its
  // job: a Safe's tooling — the Safe App, WalletConnect, its SDK — collects the owners and returns one
  // blob. So this is reported, never required. The service's part is to accept whatever the account
  // returns and ask the account whether it is valid.
  if (account.isContract) {
    try {
      account.threshold = Number(cast(['call', side.owner, 'getThreshold()(uint256)', '--rpc-url', RPC]).split(' ')[0]);
      const list = cast(['call', side.owner, 'getOwners()(address[])', '--rpc-url', RPC]).replace(/[[\]]/g, '');
      account.owners = list.split(',').map((entry) => entry.trim()).filter(Boolean).length;
      // A Safe's EIP-712 domain carries its own version, and a signature over a message built with
      // a different one hashes to something it will not accept. The account can be asked.
      account.version = castString(cast(['call', side.owner, 'VERSION()(string)', '--rpc-url', RPC]));
      record('this account can be authorised by its own rules', `${account.threshold} of ${account.owners} owners`, true, null);
    } catch {
      record('this account can be authorised by its own rules', 'not a readable multisig', true, null);
    }
  }

  return { ok: problems.length === 0, role, checks, problems, account };
}

/// The terms, with amounts already scaled. No addresses: this view answers to whoever holds the link.
const publicTerms = (offer) => {
  const computed = offer.computed;
  const sell = tokenMeta(offer, computed.sellToken);
  const buy = tokenMeta(offer, computed.buyToken);
  return {
    sellToken: computed.sellToken,
    sellAmount: computed.sellAmount,
    sellSymbol: sell.symbol,
    sellDecimals: sell.decimals,
    buyToken: computed.buyToken,
    buyAmount: computed.buyAmount,
    buySymbol: buy.symbol,
    buyDecimals: buy.decimals,
    validTo: Number(computed.validTo),
    expiresAt: new Date(Number(computed.validTo) * 1000).toISOString(),
  };
};

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, PUBLIC_URL);
    const parts = url.pathname.split('/').filter(Boolean);

    if (req.method === 'GET' && parts[0] === 'health') return json(res, 200, { ok: true });

    if (DEV_WALLET && req.method === 'POST' && parts[0] === 'dev' && parts[1] === 'sign') {
      const body = await readBody(req);
      const key = DEV_KEYS.get(String(body.address ?? '').toLowerCase());
      if (!key) return json(res, 404, { error: 'no development key for that address' });
      return json(res, 200, { address: body.address, signature: devSign(key, body) });
    }

    // The development wallet's other half: broadcast a transaction it was asked to send. Same trust
    // as `/dev/sign`, since the service already holds this key, and only when development keys are
    // configured. Without it the browser flow cannot exercise a token that needs an `approve`.
    if (DEV_WALLET && req.method === 'POST' && parts[0] === 'dev' && parts[1] === 'send') {
      const body = await readBody(req);
      const key = DEV_KEYS.get(String(body.from ?? '').toLowerCase());
      if (!key) return json(res, 404, { error: 'no development key for that address' });
      if (!/^0x[0-9a-fA-F]{40}$/.test(body.to ?? '') || !/^0x([0-9a-fA-F]{2})*$/.test(body.data ?? '')) {
        return json(res, 400, { error: 'to must be an address and data must be even-length hex' });
      }
      try {
        return json(res, 200, JSON.parse(cast(['send', body.to, body.data, '--private-key', key, '--rpc-url', RPC, '--json'])));
      } catch (err) {
        return json(res, 502, { error: relayReason(String(err.stderr ?? err.message ?? '')) });
      }
    }

    // Typed-data probes, simplest first. Every one of these is canonical EIP-712, so a wallet that
    // signs them all correctly and still cannot sign the bundle tells us the problem is one specific
    // feature of the struct — and if even the simplest fails, the wallet is not hashing what it shows.
    if (req.method === 'GET' && parts[0] === 'probes') {
      return json(res, 200, probes());
    }

    if (req.method === 'POST' && parts[0] === 'probes') {
      const body = await readBody(req);
      const results = body.signatures.map(({ name, signature, typedData }) => {
        const ok = withScratch('probe', 'typed-data.json', JSON.stringify(typedData), (file) => {
          const res2 = spawnSync(
            'cast',
            ['wallet', 'verify', '--address', body.address, '--data', '--from-file', file, signature],
            { encoding: 'utf8' },
          );
          return res2.status === 0;
        });
        console.log('probe', name, ok ? 'OK' : 'FAIL', signature);
        return { name, ok };
      });
      return json(res, 200, { address: body.address, results });
    }

    // A diagnostic: the wallet signs a message this service chose, and we recover the signer. It
    // separates "the wallet is on a different key" from "the wallet hashed a different message" —
    // a distinction no amount of guesswork about typed-data encodings can make.
    if (req.method === 'POST' && parts[0] === 'wallet-check') {
      const body = await readBody(req);
      const out = withScratch('wallet-check', 'submitted.json', JSON.stringify(body, null, 2), (file) =>
        execFileSync('forge', ['script', 'script/Diagnose.s.sol', '--rpc-url', RPC], {
          cwd: ROOT,
          encoding: 'utf8',
          env: {
            ...process.env,
            DIAG_MESSAGE: body.message,
            DIAG_SIG_FILE: file,
            COMPOSABLE_COW_ADDRESS: CONFIG.composableCoW ?? '',
          },
        }),
      );
      const recovered = (out.match(/recovered (0x[0-9a-fA-F]{40})/) ?? [])[1] ?? null;
      console.log('wallet-check', body.address, 'recovered', recovered, 'chainId', body.chainId, body.signature);
      return json(res, 200, {
        claimed: body.address,
        recovered,
        matches: recovered?.toLowerCase() === String(body.address).toLowerCase(),
      });
    }

    if (req.method === 'POST' && parts[0] === 'offers' && parts.length === 1) {
      const body = await readBody(req);
      if (!/^0x[0-9a-fA-F]{40}$/.test(body.taker ?? '') || /^0x0{40}$/i.test(body.taker)) {
        return json(res, 400, { error: 'a concrete taker address is required for this beta' });
      }
      // The maker's browser picks the offer salt; a caller that omits it gets a cryptographically
      // secure one, and a malformed one is refused rather than silently replaced. It is never
      // derived from anything public: ComposableCoW asks for a secure salt because it is what keeps
      // two offers' order identities apart, and the hook nonce and ComposableCoW salt come from it.
      const salt = body.salt === undefined || body.salt === null
        ? `0x${crypto.randomBytes(32).toString('hex')}`
        : String(body.salt).toLowerCase();
      if (!/^0x[0-9a-f]{64}$/.test(salt) || /^0x0{64}$/.test(salt)) {
        return json(res, 400, { error: 'salt must be 32 non-zero bytes of hex' });
      }
      // Explicitly enumerated: CONFIG also holds the relayer key, and this object is written to disk.
      const request = {
        maker: body.maker,
        taker: body.taker,
        sellToken: body.sellToken,
        sellAmount: String(body.sellAmount),
        buyToken: body.buyToken,
        buyAmount: String(body.buyAmount),
        validFor: String(body.validFor ?? 86400),
        salt,
        wrapper: CONFIG.wrapper,
        handler: CONFIG.handler,
        shedFactory: CONFIG.shedFactory,
        composableCoW: CONFIG.composableCoW,
        vaultRelayer: CONFIG.vaultRelayer,
        authoriser: CONFIG.authoriser,
      };
      const computed = compute(request);
      const id = crypto.randomBytes(16).toString('hex');
      const computedHash = `0x${crypto.createHash('sha256').update(JSON.stringify(computed)).digest('hex')}`;

      const offer = {
        schemaVersion: 2,
        id,
        request,
        computed,
        computedHash,
        createdAt: new Date().toISOString(),
        signatures: {},
        permits: {},
      };
      saveOffer(offer);

      return json(res, 201, {
        id,
        offerId: computed.offerId,
        computedHash,
        link: `${PUBLIC_URL}/o/${id}`,
        funding: funding(computed, 'maker'),
        permitRequired: funding(computed, 'maker').mode === 'permit',
        makerBundle: {
          shed: computed.makerBundle.shed,
          nonce: computed.makerBundle.nonce,
          deadline: computed.makerBundle.deadline,
          digest: computed.makerBundle.digest,
        },
      });
    }

    if (parts[0] === 'offers' && parts[1]) {
      const offer = loadOffer(parts[1]);
      if (!offer) return json(res, 404, { error: 'unknown offer' });

      if (req.method === 'GET' && parts[2] === 'role') {
        const who = (url.searchParams.get('address') ?? '').toLowerCase();
        if (!/^0x[0-9a-f]{40}$/.test(who)) return json(res, 400, { error: 'an address query parameter is required' });

        const maker = offer.computed.maker.toLowerCase();
        const taker = offer.request.taker.toLowerCase();
        const role = who === maker ? 'maker' : who === taker ? 'taker' : null;
        if (!role) return json(res, 200, { role: null, terms: publicTerms(offer) });

        const side = role === 'maker' ? offer.computed.makerBundle : offer.computed.takerBundle;
        // One decision, stated once. `funding` is the only place that reads a permit kind; the
        // permit block reports its conclusion rather than deciding the same thing a second way.
        const money = funding(offer.computed, role);
        return json(res, 200, {
          role,
          terms: publicTerms(offer),
          // Only a party learns who the other one is. The link itself is a bearer token, and the Shed
          // is derivable from its owner, so publishing it would publish the maker's address to
          // anyone holding the link.
          counterparty: role === 'taker' ? offer.computed.makerShed : offer.computed.takerBundle.shed,
          bundle: { digest: side.digest, typedData: side.bundleTypedData, deadline: Number(side.deadline) },
          permit: {
            kind: side.permitKind,
            digest: side.permitDigest,
            typedData: side.permitTypedData ?? null,
            typedDataAvailable: side.permitTypedDataAvailable === true,
            // A DAI-style permit has no amount and grants the maximum. The client says so rather
            // than presenting an amount-limited approval that never happens.
            unlimited: money.allowance === 'unlimited',
            token: side.sellToken,
            amount: side.sellAmount,
            symbol: tokenMeta(offer, side.sellToken).symbol,
            decimals: tokenMeta(offer, side.sellToken).decimals,
            spender: side.shed,
            deadline: Number(side.deadline),
          },
          funding: money,
          balance: balanceOf(side.sellToken, who),
          // What the Shed may already move. `approve` mode is finished when this reaches the amount,
          // and a permit that was front-run shows up here too.
          allowance: allowanceOf(side.sellToken, side.owner, side.shed),
          // A contract account signs differently and funds differently from one holding a key, and the
          // page says which before the first prompt rather than explaining a failure after it.
          owner: { address: side.owner, isContract: hasCode(side.owner) },
          // What is already known to be wrong, before anybody is asked for anything. Every one of
          // these would refuse the settlement, and none of them need a signature to answer.
          ready: checksBeforeSigning(offer, role),
          signed: offer.signatures?.[role] !== undefined,
          makerSigned: offer.signatures?.maker !== undefined,
          orderUid: offer.orderUid ?? null,
        });
      }

      if (req.method === 'GET' && parts.length === 2) {
        return json(res, 200, {
          id: offer.id,
          offerId: offer.computed.offerId,
          computedHash: offer.computedHash,
          status: (await status(offer)).status,
          terms: publicTerms(offer),
          // Whether the counterparty has signed is not secret, and a taker waiting on a maker needs
          // to know it. Which addresses those are is not part of this view.
          makerSigned: offer.signatures?.maker !== undefined,
          takerSigned: offer.signatures?.taker !== undefined,
          orderUid: offer.orderUid ?? null,
        });
      }

      if (req.method === 'GET' && parts[2] === 'cancel') {
        const who = (url.searchParams.get('address') ?? '').toLowerCase();
        if (addressRole(offer, who) !== 'maker') {
          return json(res, 403, { error: 'only the maker can cancel this offer' });
        }
        const cancellation = offer.computed.makerCancellation;
        return json(res, 200, {
          offerId: offer.computed.offerId,
          digest: cancellation.digest,
          typedData: cancellation.bundleTypedData,
          deadline: Number(cancellation.deadline),
        });
      }

      if (req.method === 'POST' && parts[2] === 'cancel') {
        const body = await readBody(req);
        if (addressRole(offer, String(body.address ?? '').toLowerCase()) !== 'maker') {
          return json(res, 403, { error: 'only the maker can cancel this offer' });
        }
        const cancellation = offer.computed.makerCancellation;
        if (verifies({ typedData: cancellation.bundleTypedData, digest: cancellation.digest, signature: body.signature, owner: cancellation.owner }) !== true) {
          return json(res, 400, { error: 'signature does not match this cancellation plan' });
        }

        const directory = attemptFiles('cancel');
        const computedFile = path.join(directory, 'computed.json');
        const signatureFile = path.join(directory, 'signature.json');
        fs.writeFileSync(computedFile, JSON.stringify(offer.computed, null, 2));
        fs.writeFileSync(signatureFile, JSON.stringify({ signature: body.signature }));
        try {
          const out = execFileSync(
            'forge',
            ['script', 'script/LinkCancel.s.sol', '--rpc-url', RPC, '--broadcast'],
            {
              cwd: ROOT,
              encoding: 'utf8',
              env: {
                ...process.env,
                RELAYER_PRIVATE_KEY: CONFIG.relayerKey,
                LINK_COMPUTED_FILE: computedFile,
                LINK_SIGNATURE_FILE: signatureFile,
              },
            },
          );
          fs.rmSync(path.join(OFFERS_DIR, `${offer.id}.json`), { force: true });
          offer.cancelledAt = new Date().toISOString();
          saveOffer(offer);
          return json(res, 200, { status: 'cancelled', relay: out.includes('already') ? 'already relayed' : 'relayed' });
        } catch (err) {
          return json(res, 409, { error: relayReason(String(err.stderr ?? err.message ?? '')) });
        } finally {
          fs.rmSync(directory, { recursive: true, force: true });
        }
      }

    // Everything the party's Shed holds, ready to be moved to their wallet. Computing it needs the
    // chain, so it is the same Solidity that signs it.
    if (req.method === 'GET' && parts[2] === 'withdraw') {
      const who = (url.searchParams.get('address') ?? '').toLowerCase();
      const role = addressRole(offer, who);
      if (!role) return json(res, 403, { error: 'this link is for a specific wallet' });
      const plan = withdrawPlan(offer, role);
      offer.withdrawals ??= {};
      offer.withdrawals[role] = plan;
      saveOffer(offer);
      return json(res, 200, plan);
    }

    if (req.method === 'POST' && parts[2] === 'withdraw') {
      const body = await readBody(req);
      const role = addressRole(offer, String(body.address ?? '').toLowerCase());
      if (!role) return json(res, 403, { error: 'this link is for a specific wallet' });
      if (!/^0x[0-9a-fA-F]{130}$/.test(body.signature ?? '')) {
        return json(res, 400, { error: 'signature must be 65 bytes, r || s || v' });
      }

      // The computed plan is replayed, never recomputed: a fresh deadline would build a different
      // message and reject a signature that is valid for what was signed.
      const plan = offer.withdrawals?.[role];
      if (!plan || plan.empty) return json(res, 409, { error: 'prepare a non-empty withdrawal first' });
      const directory = attemptFiles('withdraw-relay');
      const computedFile = path.join(directory, 'computed.json');
      const signatureFile = path.join(directory, 'signature.json');
      fs.writeFileSync(path.join(directory, 'request.json'), JSON.stringify({ shedFactory: CONFIG.shedFactory }));
      fs.writeFileSync(computedFile, JSON.stringify(plan, null, 2));
      fs.writeFileSync(signatureFile, JSON.stringify({ signature: body.signature }, null, 2));
      try {
        const out = execFileSync(
          'forge',
          ['script', 'script/Withdraw.s.sol', '--rpc-url', RPC, '--broadcast'],
          {
            cwd: ROOT,
            encoding: 'utf8',
            env: {
              ...process.env,
              WITHDRAW_REQUEST_FILE: path.join(directory, 'request.json'),
              WITHDRAW_COMPUTED_FILE: computedFile,
              WITHDRAW_SIGNATURE_FILE: signatureFile,
              RELAYER_PRIVATE_KEY: CONFIG.relayerKey,
            },
          },
        );
        const line = out.split('\n').map((l) => l.trim()).filter((l) => /withdrawn|already/.test(l));
        return json(res, 200, { moved: true, relay: line });
      } catch (err) {
        return json(res, 400, { error: relayReason(String(err.stderr ?? err.message ?? '')) });
      } finally {
        fs.rmSync(directory, { recursive: true, force: true });
      }
    }

      if (req.method === 'GET' && parts[2] === 'status') return json(res, 200, await status(offer));

      if (req.method === 'POST' && parts[2] === 'signature') {
        const body = await readBody(req);
        if (!['maker', 'taker'].includes(body.role)) return json(res, 400, { error: 'role must be maker or taker' });
        const side = body.role === 'maker' ? offer.computed.makerBundle : offer.computed.takerBundle;
        const shape = signatureProblem(side.owner, body.signature);
        if (shape) return json(res, 400, { error: shape, expectedSigner: side.owner });

        // Refuse before signing for the reasons that would refuse after it. A signature that cannot
        // lead anywhere is not a favour, and a wallet prompt is expensive to take back.
        const ready = checksBeforeSigning(offer, body.role);
        if (!ready.ok) return json(res, 409, { error: 'this offer cannot settle', problems: ready.problems, checks: ready.checks });

        if (funding(offer.computed, body.role).mode === 'permit' && !/^0x[0-9a-fA-F]{130}$/.test(body.permitSignature ?? '')) {
          return json(res, 400, {
            error: `this side is funded by a permit, so a permitSignature is required alongside the authorisation`,
            permitKind: side.permitKind,
            funding: funding(offer.computed, body.role),
          });
        }
        const wrong = preflight(offer, body.role, body);
        if (wrong) return json(res, 400, wrong);

        offer.signatures[body.role] = body.signature;
        if (body.permitSignature) offer.permits[body.role] = body.permitSignature;
        saveOffer(offer);
        return json(res, 200, { id: offer.id, signed: Object.keys(offer.signatures) });
      }

      if (req.method === 'POST' && parts[2] === 'accept') {
        const body = await readBody(req);
        if (offer.orderUid) return json(res, 409, { error: 'already accepted', orderUid: offer.orderUid });

        // Acceptance is the one path that both moves money and takes a network round trip, so it is
        // the one path a second request can slip into. The relay is idempotent (the Shed skips a
        // nonce it has seen) and the order UID is derived from the order, so a duplicate costs work
        // and a confusing second answer — not a second trade. Refuse it instead of paying that.
        //
        // Per process. Two service instances sharing a store still race here; see README.
        if (accepting.has(offer.id)) {
          return json(res, 409, { error: 'an acceptance is already in flight for this offer' });
        }

        if (body.taker && body.taker.toLowerCase() !== offer.request.taker.toLowerCase()) {
          return json(res, 403, { error: 'this offer is restricted to another counterparty' });
        }

        const signature = body.signature ?? offer.signatures.taker;
        if (!signature) return json(res, 400, { error: 'signature required' });
        const shape = signatureProblem(offer.computed.takerBundle.owner, signature);
        if (shape) return json(res, 400, { error: shape, expectedSigner: offer.computed.takerBundle.owner });

        // The taker is the party who commits both sides: accepting relays both bundles, which funds
        // their Shed and the maker's. So the offer has to be settleable before their signature is
        // taken, not after.
        const ready = checksBeforeSigning(offer, 'taker');
        if (!ready.ok) {
          return json(res, 409, { error: 'this offer cannot settle', problems: ready.problems, checks: ready.checks });
        }
        // Always check what is being submitted now, not what is already on file.
        const wrong = preflight(offer, 'taker', { ...body, signature });
        if (wrong) return json(res, 400, wrong);

        offer.signatures.taker = signature;
        if (body.permitSignature) offer.permits.taker = body.permitSignature;

        for (const role of ['maker', 'taker']) {
          if (funding(offer.computed, role).mode === 'permit' && !offer.permits[role]) {
            return json(res, 400, {
              error: `the ${role}'s side is funded by a permit, so its permitSignature is required`,
              permitKind: offer.computed[role === 'maker' ? 'makerBundle' : 'takerBundle'].permitKind,
              funding: funding(offer.computed, role),
            });
          }
        }

        offer.acceptance ??= { attemptId: crypto.randomUUID(), startedAt: new Date().toISOString() };
        offer.acceptance.phase = 'funding';
        delete offer.acceptance.error;
        saveOffer(offer);

        // Taken here, immediately before the work, and not a line earlier: every check above can
        // return, and a lock held across a return never comes back — the offer would report "already
        // in flight" for the rest of its life.
        accepting.add(offer.id);
        try {
          const relayLog = relay(offer.computed, {
            ...offer.signatures,
            makerPermit: offer.permits.maker,
            takerPermit: offer.permits.taker,
          });
          offer.acceptance.phase = 'funded';
          saveOffer(offer);

          // Publish atomically so the sub-solver never observes a partial plan.
          const target = path.join(OFFERS_DIR, `${offer.id}.json`);
          const temporary = `${target}.${offer.acceptance.attemptId}.tmp`;
          fs.writeFileSync(temporary, JSON.stringify(offer.computed, null, 2));
          fs.renameSync(temporary, target);
          offer.acceptance.phase = 'published';
          saveOffer(offer);

          offer.orderUid = await postOrder(offer.computed.takerOrder);
          offer.acceptedAt = new Date().toISOString();
          offer.acceptance.phase = 'settling';
          saveOffer(offer);

          return json(res, 202, { id: offer.id, orderUid: offer.orderUid, status: 'settling', relay: relayLog });
        } catch (err) {
          offer.acceptance.phase = 'failed';
          offer.acceptance.error = relayReason(String(err.stderr ?? err.message ?? ''));
          saveOffer(offer);
          return json(res, 502, { status: 'recovery_available', error: offer.acceptance.error });
        } finally {
          accepting.delete(offer.id);
        }
      }
    }

    if (req.method === 'GET' && parts.length === 0) {
      res
        .writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' })
        .end(renderCreate({ devWallet: DEV_WALLET, defaults: CONFIG.defaults }));
      return;
    }

    if (req.method === 'GET' && parts[0] === 'o' && parts[1]) {
      const offer = loadOffer(parts[1]);
      if (!offer) return json(res, 404, { error: 'unknown offer' });
      // No caching: this page is served by a service that changes, and a stale copy looks exactly
      // like a bug in the page.
      res
        .writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' })
        .end(render(offer.id, { devWallet: DEV_WALLET }));
      return;
    }

    json(res, 404, { error: 'not found' });
  } catch (err) {
    json(res, 500, { error: err.message, stderr: String(err.stderr ?? '').slice(0, 800) });
  }
});

server.listen(PORT, () => {
  console.log(`private trade link service on ${PUBLIC_URL} (rpc ${RPC}, orderbook ${ORDERBOOK})`);
  if (!CONFIG.wrapper) console.warn('warning: PRIVATE_TRADE_WRAPPER is not set');
});
