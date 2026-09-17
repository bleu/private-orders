#!/usr/bin/env node
// Private trade sub-solver.
//
// A BYOS sub-solver in the shape this repo argues for: it holds a private offer that never reaches
// the orderbook, waits for the matching acceptance to appear in an auction, and answers with the
// pair the wrapper expects.
//
//   fulfillment  the taker's order, which is a real orderbook order
//   jit          the maker's order, injected inline and never published
//   wrappers     the private trade bundle, which enforces the pair on-chain
//   interactions none, because nothing else participates
//
// It reads the maker half from a JSON payload produced by `script/PreparePrivateTrade.s.sol`. No
// private keys are involved: order authorisation comes from the Shed-owned conditional orders.
//
//   OFFER_FILE=/tmp/private-trade-offer.json PORT=9100 node private-trade-solver.mjs

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

// 9100 is node_exporter's well-known port. A host that runs it refuses this bind with EADDRINUSE, which
// reads as "the sub-solver is broken" rather than "the port was taken", so set PORT to move it — and
// keep `endpoint` in the driver config (`config/offline/driver.toml`) in step with it.
const PORT = Number(process.env.PORT ?? 9100);
// The driver is the only expected caller, and it is usually on this machine. Listening on every
// interface would hand an unauthenticated, unbounded endpoint to anyone who can reach the host.
// The demo's driver runs in a container and reaches the sub-solver through host.docker.internal,
// so the demo scripts set HOST=0.0.0.0 explicitly.
const HOST = process.env.HOST ?? '127.0.0.1';
/// How much of one request to accept. A real auction here carries two orders; more than this is
/// not an auction, and a body is not a document: the log keeps a sample, not a copy, of it.
const MAX_BODY = 5e6;
const OFFERS_DIR = process.env.OFFERS_DIR ?? '/tmp/private-trade-offers';
const OFFER_FILE = process.env.OFFER_FILE ?? null;
const SOLVE_LOG = process.env.SOLVE_LOG ?? '/tmp/private-trade-solve.log';

function log(entry) {
  fs.appendFileSync(SOLVE_LOG, `${JSON.stringify(entry)}\n`);
}

/// Every private offer this sub-solver is holding. One file per offer, so several can be live.
function loadOffers() {
  const files = [];
  if (OFFER_FILE && fs.existsSync(OFFER_FILE)) files.push(OFFER_FILE);
  if (fs.existsSync(OFFERS_DIR)) {
    for (const name of fs.readdirSync(OFFERS_DIR)) {
      if (name.endsWith('.json')) files.push(path.join(OFFERS_DIR, name));
    }
  }
  const offers = [];
  for (const file of files) {
    try {
      offers.push(JSON.parse(fs.readFileSync(file, 'utf8')));
    } catch (err) {
      log({ error: `unreadable offer ${file}: ${err.message}` });
    }
  }
  return offers;
}

const hexEq = (a, b) => typeof a === 'string' && typeof b === 'string' && a.toLowerCase() === b.toLowerCase();

/// Build the solution if this auction carries the acceptance for our offer.
function buildSolution(auction, offer) {
  const orders = auction.orders ?? [];

  const takerOrder = orders.find(
    (o) => hexEq(o.appData, offer.appDataHash) && hexEq(o.owner, offer.taker),
  );

  if (!takerOrder) {
    log({
      skip: 'acceptance not in this auction',
      wanted: offer.appDataHash,
      auctionKeys: Object.keys(auction),
      orderCount: orders.length,
      seen: orders.map((o) => ({ uid: o.uid, owner: o.owner, appData: o.appData })),
    });
    return [];
  }

  // The pair must be the exact mirror. The wrapper checks this on-chain too, but returning a
  // solution that cannot settle only wastes a simulation.
  if (!hexEq(takerOrder.sellToken, offer.buyToken) || !hexEq(takerOrder.buyToken, offer.sellToken)) {
    log({ skip: 'acceptance is not the mirror of the offer' });
    return [];
  }

  return [
    {
      id: 0,
      prices: offer.prices,
      // Order matters: the wrapper expects the maker first, and the driver preserves the order
      // given here in the settlement's trades array.
      trades: [
        {
          kind: 'jit',
          order: offer.makerJitOrder,
          executedAmount: offer.sellAmount,
        },
        {
          kind: 'fulfillment',
          order: takerOrder.uid,
          executedAmount: takerOrder.sellAmount,
          // A limit order requires a solver-computed fee. Omitting it means `Fee::Static`, which
          // the driver rejects for limit orders; zero is the honest value here, since the taker
          // pays nothing beyond the pair.
          fee: '0',
        },
      ],
      interactions: [],
      wrappers: [{ address: offer.wrapper, data: offer.wrapperData }],
    },
  ];
}

const server = http.createServer((req, res) => {
  if (req.method === 'GET') {
    res.writeHead(200, { 'content-type': 'text/plain' }).end('ok');
    return;
  }

  let body = '';
  let rejected = false;
  req.on('data', (chunk) => {
    if (rejected) return;
    body += chunk;
    if (body.length > MAX_BODY) {
      rejected = true;
      log({ at: new Date().toISOString(), refused: `body of ${body.length} bytes exceeds ${MAX_BODY}` });
      res.writeHead(413, { 'content-type': 'text/plain' }).end('payload too large');
      req.destroy();
    }
  });
  req.on('end', () => {
    if (rejected) return;
    let auction;
    try {
      auction = JSON.parse(body);
    } catch {
      res.writeHead(400).end('invalid json');
      return;
    }

    log({ at: new Date().toISOString(), raw: body.slice(0, 400), bytes: body.length });
    const offers = loadOffers();
    const orders = auction.orders ?? [];
    const solutions = offers.flatMap((offer) => buildSolution(auction, offer));

    log({
      at: new Date().toISOString(),
      auctionId: auction.id ?? null,
      // A sample, not a copy: a request can carry more bytes than one log line should cost.
      orderCount: orders.length,
      orders: orders.slice(0, 200).map((o) => ({
        uid: o.uid,
        owner: o.owner,
        appData: o.appData,
        sellToken: o.sellToken,
        buyToken: o.buyToken,
        sellAmount: o.sellAmount,
        buyAmount: o.buyAmount,
        fullSellAmount: o.fullSellAmount,
        fullBuyAmount: o.fullBuyAmount,
        kind: o.kind,
        partiallyFillable: o.partiallyFillable,
        wrappers: o.wrappers ?? [],
      })),
      solutions: solutions.length,
    });

    res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify({ solutions }));
  });
});

server.listen(PORT, HOST, () => {
  log({ at: new Date().toISOString(), listening: `${HOST}:${PORT}`, offersDir: OFFERS_DIR });
  console.log(`private trade sub-solver listening on ${HOST}:${PORT}, offers in ${OFFERS_DIR}`);
});
