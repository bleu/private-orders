# Trying it out, from an agent

Three ways, cheapest first. All of them assume the person has pi, Codex CLI, or Claude Code installed;
none needs a wallet except the hosted browser route.

## 1. Against the hosted demo, in a browser

For an agent with a browser tool and no local setup. The demo is on a tailnet, so the person must be on
the tailnet to reach it.

> Open https://ai-demo.neon-garibaldi.ts.net/ and try the private-trade demo.
>
> - Get demo tokens first at https://ai-demo.neon-garibaldi.ts.net/faucet — paste an address, take
>   10000 USDC and 10000 DAI.
> - Create a trade on the create page: connect a wallet, name the counterparty's address as the taker,
>   then open the link it gives you.
> - Report what the page says at each step, and whether the status becomes `settled`.
>
> Context: the chain is a local fork and the tokens are worthless. A party's wallet must be on Ethereum
> Mainnet, which it already is, and it will show its real balances. Neither party sends a transaction or
> pays gas — the relayer pays. Signing needs a wallet extension, so stop and say so if you have none.

Headless, in each harness:

```sh
pi    -p "Open https://ai-demo.neon-garibaldi.ts.net/faucet, take the demo tokens, then walk the create-trade flow and tell me what the status becomes. Stop if signing needs a real wallet."
codex exec "Open https://ai-demo.neon-garibaldi.ts.net/faucet and take the demo tokens, then walk the create-trade flow and report each step and the final status. Note that signing may need a wallet extension."
claude -p "Open https://ai-demo.neon-garibaldi.ts.net/faucet, take the demo tokens, then walk the create-trade flow and tell me what the page says and what the status becomes."
```

## 2. In their own checkout

This is the one that ends in a real settlement rather than a page walk. It needs the repository (see the
note at the bottom), Docker, Foundry, Node 24, and the offline CoW stack — `docs/OFFLINE.md` covers the
stack, including the two failures that look like bugs in our code.

```sh
pi    -p "Read AGENTS.md, run its four fast-gate commands, then scripts/demo/stack-up.sh and scripts/demo/reset-and-run.sh. Report the balances each side moved and whether either party sent a transaction."
codex exec "Read AGENTS.md. Run the fast gate, then ./scripts/demo/stack-up.sh, ./scripts/demo/reset-and-run.sh, and report exactly what settled."
claude -p "Read AGENTS.md. Run the fast gate, then scripts/demo/stack-up.sh and scripts/demo/reset-and-run.sh; summarise what settled and what moved."
```

`AGENTS.md` is what makes this work with no extra context: all three harnesses read it at startup, and it
carries the gate commands, the mutation requirement, and the environment traps.

## 3. Reading it instead of running it

For a reviewer who wants the argument rather than the demo, point at `docs/ASSESSMENT.md` (what this is
and is not), `docs/DESIGN.md` (why it is shaped this way), `docs/LINK-SERVICE.md` (service and page
behaviour), and `docs/review/codex-astra-*.md` plus the audit that followed, which is the honest record of
what the reviews found and what was done about it.

## A note on this repository

There is no git remote configured. For anyone outside this machine to try route 2, the repo has to be
pushed first — or shared as a tarball. Route 1 works today because it only needs the hosted demo.
