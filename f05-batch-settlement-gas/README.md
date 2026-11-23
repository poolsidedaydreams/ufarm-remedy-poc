# F-05 — Unbounded signed-request batch OOGs settlement despite the 100k ERC-1271 gas cap

**Severity:** Low — [Remedy report thread](https://hunt.r.xyz/report-thread/98e9a85b-a08c-4008-b972-6f2a47c5e1e0)

**Target (pinned):** https://github.com/UFarmDigital/UFarm-EVM-Contracts @ `b19a6511` ("Production Release 2.1.1"). Production contracts in `src/` are copied byte-identical from that commit.

## Bug

`settleRequests` loops over a caller-supplied batch with no maximum length (`VaultLifecycleModule.sol:225-243`). Each entry is signature-validated with a 100k gas cap (`try IERC1271.isValidSignature{gas: 100_000}`, `:59`), but failed validation does not consume the nonce, so the same griefing entry is replayable and distinct invalid entries stack. `PENDING_QUEUE_LIMIT = 10` (`:61`) caps only accepted owners and is checked last in `_validateRequest` (`:518-541`). This is an incomplete fix of Hexens finding UFARM2-1, which capped only a single call.

## Impact (numbers from the PoC run)

| Case | Gas |
|---|---|
| Control settlement, no griefing (N=0) | 523,602 |
| 1 griefing request + settle | 670,091 |
| N=10 griefing requests | 1,682,159 |
| N=250 griefing requests | 29,537,345 |
| **260 distinct-owner griefing requests** | **OOG at 30M gas** (73,856,261 measured) |
| **280 same-owner griefing requests** | **OOG at 30M gas** (31,145,995 measured) |

Each griefing request burns ~116k gas (~100k cap + validation overhead). At a 30M block gas limit, ~260 requests make the whole settlement revert — the legitimate pending deposit stays queued and settlement is blocked. The attacker's cost is **zero on-chain gas** (signed messages only, submitted off-chain to the backend); the settlement manager pays for the reverted transaction.

## Layout

- `src/` — production contracts, copied byte-identical from the scope repo at the pinned commit.
- `test/GriefPoC.t.sol` — the PoC (9 tests; `GasGriefERC1271` is defined in the file). Header carries the bug, impact, severity, and vulnerable file + lines. Tests log the gas before vs after (control vs griefed) and the settlement success flag.
- `test/invariant/helpers/` — fixture the PoC deploys through (`InvariantFixture.sol`, `InvariantVm.sol`).
- `foundry.toml`, `remappings.txt` — Foundry config; remappings are written out explicitly (forge-std + OpenZeppelin 5.6.1).

## Reproduce

```bash
forge install --no-git foundry-rs/forge-std \
  OpenZeppelin/openzeppelin-contracts@v5.6.1 \
  OpenZeppelin/openzeppelin-contracts-upgradeable@v5.6.1
forge test --match-contract GriefPoCTest --gas-limit 100000000 -vv
```

Expected: **9/9 pass**. Run with `-vv` to see the before/after gas logs — the control-vs-griefed gas figures are the proof.
