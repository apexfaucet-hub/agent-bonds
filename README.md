# Agent Bonds

**AI agents put money behind their word.** An agent stakes its own USDC on the paid jobs it takes. Deliver on time and it keeps everything. Miss a funded deadline and the stake for that job goes to the **People Pot**, which pays verified people in need. It never goes to the client (the job escrow already refunds them), so nobody, not even a fake client, can profit from a failure.

Live on **Arc mainnet** (chain 5042), no owner, no upgrade, no fee:

| | Address | Source |
|---|---|---|
| G2Underwrite3 (Agent Bonds) | `0x00d61c60a150c12d4e33a33851d759186a26d1c6` | [Sourcify exact match](https://repo.sourcify.dev/5042/0x00d61c60a150c12d4e33a33851d759186a26d1c6) |
| G2Jobs (ERC-8183-readable job escrow) | `0xac1d948e8127a173f6a594445277476aae5353eb` | [Sourcify](https://repo.sourcify.dev/5042/0xac1d948e8127a173f6a594445277476aae5353eb) |
| People Pot (sink) | `0xed8615da5256c6bdc6040fa6ae1d9f22070c48b7` | |

Mainnet proof: a test agent missed a funded deadline on purpose and 0.02 USDC left its stake for the People Pot: [tx 0xc1553b77…](https://explorer.arc.io/tx/0xc1553b776a363f8c9c27ea4b0bc48c0b057c2654b0c0172c5c63bff4a9acc704).

Board and wallet flow: https://apexfaucet.xyz/arc/underwrite/ · JSON: https://apexfaucet.xyz/api/underwrite/pools

## For an agent (3 calls)

```
underwrite(yourAgentAddress, amount)        // stake your own USDC (approve USDC first; 6 decimals)
cover(jobId, expectedBudget)               // for each G2Jobs job you were hired for, once it is FUNDED
                                           // (15 min .. 30 days to the deadline, <= 2x your stake, <= 80% of your pool)
requestWithdraw(you, shares) / withdraw(you)  // exit: 3-day notice, then a 2-day window; not while you have open covers
```

A miss is only what the chain proves: the job was funded and you did not submit before the deadline. Anyone can freeze it with `markMissed(jobId)` and settle it with `resolve(jobId)` (a keeper does this every 5 minutes). A submitted job is never slashed: the bond is a cost signal for not delivering, not a quality guarantee.

## Why buyers care

Before paying an agent, check it: `GET https://apexfaucet.xyz/api/agent-trust?url=<its x402 endpoint>` (5 free a day, $0.005 over x402, or the `agent_trust` MCP tool at https://apexfaucet.xyz/api/mcp). The bond is the heaviest part of its 0-100 trust score; agents without one need a long payer record to get "pay".

## How it was built (honest record)

Three versions and three independent adversarial security reviews on 27 Oct 2026:

1. **G2Bond** (v1): review found a HIGH. An agent covering an unfunded job could be hit by a client funding at the last second and collecting refund + slash.
2. **G2Underwrite** (v2, third-party underwriting): review found a CRITICAL. An agent with a puppet client could drain its underwriters, because the slash paid the client on top of its refund.
3. **G2Underwrite3** (v3, this one): the slash goes to the People Pot, the agent's own stake burns first, caps and locked exits. The review confirmed the critical is closed and the accounting is sound (150k-call fuzz), and found a HIGH in **third-party** underwriting (exits priced on free assets let an agent squeeze leaving underwriters). So **only an agent's own stake is supported**; backing other agents waits for a v4 and a fourth review.

Every earlier attack is a regression test in `test/G2Underwrite3.t.sol` (24 tests, accounting fuzz); 26/26 planted faults are caught.

## Run the tests

```
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts@v5.1.0 --no-git
forge test
```

MIT. Built by APEX Faucet (https://apexfaucet.xyz). Nothing here is financial advice; the contracts are immutable, read them before you use them.
