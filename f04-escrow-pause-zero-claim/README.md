# F-04 / C-1 — Redeem claim deleted before escrow release

**Severity:** Low — [Remedy report thread](https://hunt.r.xyz/report-thread/e7f33e41-46e8-43b6-96e0-e1dade3af3e3)

**Target (pinned):** https://github.com/UFarmDigital/UFarm-EVM-Contracts @ `b19a6511` ("Production Release 2.1.1"). Production contracts in `src/` are copied byte-identical from that commit.

## Bug

`VaultLifecycleModule._claimRedeemAssets` deletes `claimableRedeem` (`:768`) before calling `_releaseAvailableEscrow` (`:769`). If the release reverts — e.g. an admin sets `ESCROW_OPERATIONS_PAUSED` (bit `1 << 10`, `PauseMask.sol:16`) without `CLAIMS_PAUSED` — the catch (`:934-951`) swallows the revert and `redeem()` returns 0 with the claim already gone (shares were burned at settlement). The same pattern hits `cancelDeposit` (`:182-183` delete, `:185` release).

## Impact (numbers from the PoC run)

- Redeem claim of **100e18** → `redeem()` returns **0**, `claimableRedeem` goes from **100e18 to 0** — the claim is silently wiped.
- The **100e18** is not permanently lost: it still sits in escrow under the owner with `lockedTill == 0`. But the owner can only recover it by calling `UFarmEscrow.withdraw` directly — and only **after the pause is lifted**, because `withdraw` also checks the pause.
- In production the lost amount is whatever the redeem claim was; the user sees a successful `redeem()` that paid nothing.

## Layout

- `src/` — production contracts, copied byte-identical from the scope repo at the pinned commit.
- `test/VaultCorePoC.t.sol` — the PoC (9 tests). Header carries the bug, impact, severity, and vulnerable file + lines. The key test logs the claimable amount, the redeem result, and the escrow balance before vs after.
- `test/Mocks.sol` — PoC-only mocks.
- `foundry.toml`, `remappings.txt` — Foundry config; remappings are written out explicitly (forge-std + OpenZeppelin 5.6.1).

## Reproduce

```bash
forge install --no-git foundry-rs/forge-std \
  OpenZeppelin/openzeppelin-contracts@v5.6.1 \
  OpenZeppelin/openzeppelin-contracts-upgradeable@v5.6.1
forge test -vv
```

Expected: **9/9 pass**. Key test: `testRedeemClaim_DuringEscrowPause_RecoverableViaEscrow` (gas 1,937,679). Run with `-vv` to see the before/after logs — `redeem()` returning 0 while the escrow balance stays 100e18 is the proof.
