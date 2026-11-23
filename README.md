# UFarm Digital — Remedy PoCs

Foundry proof-of-concept projects for three bug bounty reports submitted to the
**UFarm Digital** programme on Remedy (https://hunt.r.xyz/programs/ufarm-digital),
from the Apgalxe account, 23 November 2026.

Scope repo: https://github.com/UFarmDigital/UFarm-EVM-Contracts
— production contracts copied byte-identical from HEAD
`b19a6511c61157bfd68df1c28f0299e68bde02fb` ("Production Release 2.1.1").
Solidity 0.8.35, Foundry 1.10.0, OpenZeppelin 5.6.1, forge-std latest.

| Project | Report | Severity | Thread |
|---|---|---|---|
| `f03-donation-price-latch/` | F-03 — donation before first settlement hardcodes $1 reference price; next settlement trips invalid-price latch and freezes settlements | Medium | https://hunt.r.xyz/report-thread/27dd88c1-90bd-4b8b-87c7-7f70ae5b5b78 |
| `f04-escrow-pause-zero-claim/` | C-1 (= F-04) — redeem claim deleted before escrow release; claim lost when release fails, redeem returns 0 | Low | https://hunt.r.xyz/report-thread/e7f33e41-46e8-43b6-96e0-e1dade3af3e3 |
| `f05-batch-settlement-gas/` | F-05 — unbounded signed-request batch lets griefing requests OOG settlement despite the 100k ERC-1271 gas cap (incomplete fix of Hexens UFARM2-1) | Low | https://hunt.r.xyz/report-thread/98e9a85b-a08c-4008-b972-6f2a47c5e1e0 |

## PoC standard

Every folder is a self-contained Foundry project following the standard used by
rewarded hunters (Immunefi's `forge-poc-templates`): a clear README (bug
summary, impact with numbers, reproduction steps), a test file headed with
`@title` / Bug / Impact / Severity / vulnerable file + lines, remappings
written out explicitly, the target commit pinned (`b19a6511`), and tests that
log the before-vs-after numbers — those numbers are the proof. No zip files;
all source is visible in the repo.

## Running a PoC

```bash
cd f03-donation-price-latch   # or f04-escrow-pause-zero-claim / f05-batch-settlement-gas
forge install --no-git foundry-rs/forge-std \
  OpenZeppelin/openzeppelin-contracts@v5.6.1 \
  OpenZeppelin/openzeppelin-contracts-upgradeable@v5.6.1
forge test
```

F-05 needs a higher gas limit for the griefing tests:

```bash
cd f05-batch-settlement-gas
forge test --match-contract GriefPoCTest --gas-limit 100000000
```

## Verification

Each project was independently re-run and verified on 23 November 2026:
F-03 `forge test` **3/3 pass**, F-04 `forge test` **9/9 pass**,
F-05 `forge test --match-contract GriefPoCTest --gas-limit 100000000` **9/9 pass**
(gas figures reproduce the reports exactly, e.g. F-05 control 523,602;
N=250 grief 29,537,345; distinct-owners OOG 73,856,261).

The mock oracle in the F-03 project stands in for Quex delivery and reports the
holdings-based NAV; no live deployment addresses exist in the repository, so all
PoCs run against a local deployment.
