# F-03 — Donation before first settlement latches the price and freezes settlements

**Severity:** Medium — [Remedy report thread](https://hunt.r.xyz/report-thread/27dd88c1-90bd-4b8b-87c7-7f70ae5b5b78)

**Target (pinned):** https://github.com/UFarmDigital/UFarm-EVM-Contracts @ `b19a6511` ("Production Release 2.1.1"). Production contracts in `src/` are copied byte-identical from that commit.

## Bug

A donation made before a vault's first settlement is priced at a hardcoded $1 reference (`VaultLifecycleModule.sol:351-354` sets `highWaterMark` and `lastTokenPrice` to `WAD`, and `_validatePrice` skips the check while `pricingSupply == 0`). The next settlement compares the real price against that $1 reference, the deviation exceeds `allowedPriceFluctuation`, and `lifecycle.isInvalidPrice` latches (`:386`) — `settleRequests`, `resetRequests` and `manualResendOracleRequest` all revert afterwards. Only `resetInvalidPrice` (privileged, `MEMBER | CORE_PRICE_GUARD_MANAGER`) unblocks it.

## Impact (numbers from the PoC run)

- Donation: **11 units** on a first deposit of **100** → true price **$1.11/share**, but the reference price is hardcoded to **$1.00**.
- Second settlement: **+11%** deviation vs the **10%** guard → latch set, `isInvalidPrice == true`.
- After the latch: `settleRequests` reverts (`ORACLE_INVALID_PRICE`), the pending deposit of **10** stays unsettled, and **all** settlements for the vault are frozen until a privileged manual reset.
- The attacker recovers the donation at ~**$0 net** when they are the (dominant) first depositor; the damage to everyone else is a full settlement freeze.

## Layout

- `src/` — production contracts, copied byte-identical from the scope repo at the pinned commit.
- `test/DonationPriceLatch.t.sol` — the PoC (3 tests). Header carries the bug, impact, severity, and vulnerable file + lines. Key tests log the numbers before vs after (vault balance, reference price vs true price, latch state).
- `test/mocks/` — PoC-only mocks. The mock oracle stands in for Quex delivery and reports the holdings-based NAV; no live deployment addresses exist in the repository, so the PoC runs against a local deployment.
- `foundry.toml`, `remappings.txt` — Foundry config; remappings are written out explicitly (forge-std + OpenZeppelin 5.6.1).

## Reproduce

```bash
forge install --no-git foundry-rs/forge-std \
  OpenZeppelin/openzeppelin-contracts@v5.6.1 \
  OpenZeppelin/openzeppelin-contracts-upgradeable@v5.6.1
forge test -vv
```

Expected: **3/3 pass**. Key test: `test_DonationBeforeFirstSettlement_LatchesPriceAndFreezesSettlement` (gas 3,801,816). Run with `-vv` to see the before/after logs — the reference price vs the true price is the proof.
