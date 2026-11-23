# F-04 / C-1 — Redeem claim deleted before escrow release

**Severity:** Low — [Remedy report thread](https://hunt.r.xyz/report-thread/e7f33e41-46e8-43b6-96e0-e1dade3af3e3)

`VaultLifecycleModule._claimRedeemAssets` deletes `claimableRedeem` before
calling `_releaseAvailableEscrow`. If the release reverts — e.g. an admin sets
`ESCROW_OPERATIONS_PAUSED` without `CLAIMS_PAUSED` — the catch swallows the
revert and `redeem()` returns 0 with the claim already gone (shares were
burned at settlement). The same pattern hits `cancelDeposit`. Funds are not
permanently lost: redeem credits have `lockedTill = 0`, so the owner can
withdraw directly via `UFarmEscrow.withdraw` — but only after the pause is
lifted, because `withdraw` also checks the pause.

## Layout

- `src/` — production contracts, copied byte-identical from the scope repo
  (https://github.com/UFarmDigital/UFarm-EVM-Contracts, HEAD `b19a6511`).
- `test/VaultCorePoC.t.sol` — the PoC (9 tests).
- `test/Mocks.sol` — PoC-only mocks.

## Run

```bash
forge install --no-git foundry-rs/forge-std \
  OpenZeppelin/openzeppelin-contracts@v5.6.1 \
  OpenZeppelin/openzeppelin-contracts-upgradeable@v5.6.1
forge test
```

Expected: **9/9 pass**. Key test:
`testRedeemClaim_DuringEscrowPause_RecoverableViaEscrow` (gas 1,860,589).
