# F-05 — Unbounded signed-request batch OOGs settlement despite the 100k ERC-1271 gas cap

**Severity:** Low — [Remedy report thread](https://hunt.r.xyz/report-thread/98e9a85b-a08c-4008-b972-6f2a47c5e1e0)

`settleRequests` loops over a caller-supplied batch with no maximum length.
Each entry is signature-validated with a 100k gas cap (`try
IERC1271.isValidSignature{gas: 100_000}`), but failed validation does not
consume the nonce, so the same griefing entry is replayable and distinct
invalid entries stack. At a 30M block gas limit, ~260 griefing requests make
the whole settlement revert — a bypass of the fix for Hexens finding
UFARM2-1, which capped only a single call.

## Layout

- `src/` — production contracts, copied byte-identical from the scope repo
  (https://github.com/UFarmDigital/UFarm-EVM-Contracts, HEAD `b19a6511`).
- `test/GriefPoC.t.sol` — the PoC (9 tests; `GasGriefERC1271` is defined in
  the file).
- `test/invariant/helpers/` — fixture the PoC deploys through
  (`InvariantFixture.sol`, `InvariantVm.sol`).

## Run

```bash
forge install --no-git foundry-rs/forge-std \
  OpenZeppelin/openzeppelin-contracts@v5.6.1 \
  OpenZeppelin/openzeppelin-contracts-upgradeable@v5.6.1
forge test --match-contract GriefPoCTest --gas-limit 100000000
```

Expected: **9/9 pass**. Gas figures reproduce the report exactly:
control 523,602; single grief 670,091; N=10 1,682,159; N=250 29,537,345;
distinct-owners OOG 73,856,261.
