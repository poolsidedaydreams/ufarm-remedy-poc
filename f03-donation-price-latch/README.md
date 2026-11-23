# F-03 — Donation before first settlement latches the price and freezes settlements

**Severity:** Medium — [Remedy report thread](https://hunt.r.xyz/report-thread/27dd88c1-90bd-4b8b-87c7-7f70ae5b5b78)

A donation made before a vault's first settlement is priced at a hardcoded $1
reference (`VaultLifecycleModule.sol:351-354` sets `highWaterMark` and
`lastTokenPrice` to `WAD`, and `_validatePrice` skips the check while
`pricingSupply == 0`). The next settlement compares the real price against
that $1 reference, the deviation exceeds `allowedPriceFluctuation`, and
`lifecycle.isInvalidPrice` latches — `settleRequests`, `resetRequests` and
`manualResendOracleRequest` all revert afterwards. Only
`resetInvalidPrice` (privileged) unblocks it.

## Layout

- `src/` — production contracts, copied byte-identical from the scope repo
  (https://github.com/UFarmDigital/UFarm-EVM-Contracts, HEAD `b19a6511`).
- `test/DonationPriceLatch.t.sol` — the PoC (3 tests).
- `test/mocks/` — PoC-only mocks. The mock oracle stands in for Quex delivery
  and reports the holdings-based NAV; no live deployment addresses exist in
  the repository, so the PoC runs against a local deployment.

## Run

```bash
forge install --no-git foundry-rs/forge-std \
  OpenZeppelin/openzeppelin-contracts@v5.6.1 \
  OpenZeppelin/openzeppelin-contracts-upgradeable@v5.6.1
forge test
```

Expected: **3/3 pass**. Key test:
`test_DonationBeforeFirstSettlement_LatchesPriceAndFreezesSettlement`
(gas 3,709,102).
