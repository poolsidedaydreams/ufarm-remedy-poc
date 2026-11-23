// SPDX-License-Identifier: BUSL-1.1
// Worker F — VaultShareAccounting invariant fuzz: totalSupply == sum(balances) under all ops.
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {VaultShareAccounting} from "../src/contracts/libraries/VaultShareAccounting.sol";
import {VaultBaseStorage} from "../src/contracts/libraries/VaultBaseStorage.sol";

contract ShareAccountingHarness {
    function mint(address to, uint256 shares) external {
        VaultShareAccounting.mintShares(to, shares);
    }

    function burn(address from, uint256 shares) external {
        VaultShareAccounting.burnShares(from, shares);
    }

    function move(address from, address to, uint256 shares) external {
        VaultShareAccounting.moveShares(from, to, shares);
    }

    function transfer(address from, address to, uint256 shares) external {
        VaultShareAccounting.transferShares(from, to, shares);
    }

    function approve(address owner, address spender, uint256 amount) external {
        VaultShareAccounting.approveShares(owner, spender, amount);
    }

    function totalSupply() external view returns (uint256) {
        return VaultBaseStorage.data().totalSupply;
    }

    function balanceOf(address a) external view returns (uint256) {
        return VaultBaseStorage.data().balances[a];
    }

    function allowance(address o, address s) external view returns (uint256) {
        return VaultBaseStorage.data().allowances[o][s];
    }
}

contract ShareAccountingHandler is Test {
    ShareAccountingHarness internal h;
    address[] internal actors;

    constructor(ShareAccountingHarness _h) {
        h = _h;
        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA901));
        actors.push(address(0xD00D));
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function mint(uint256 actorSeed, uint256 amount) external {
        amount = bound(amount, 0, 1e30);
        h.mint(_actor(actorSeed), amount);
    }

    function burn(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        uint256 bal = h.balanceOf(a);
        if (bal == 0) return;
        amount = bound(amount, 0, bal);
        h.burn(a, amount);
    }

    function move(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 bal = h.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 0, bal);
        h.move(from, to, amount);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 bal = h.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 0, bal);
        h.transfer(from, to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        h.approve(_actor(ownerSeed), _actor(spenderSeed), bound(amount, 0, 1e30));
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}

contract ShareAccountingInvariantTest is Test {
    ShareAccountingHarness internal h;
    ShareAccountingHandler internal handler;

    function setUp() public {
        h = new ShareAccountingHarness();
        handler = new ShareAccountingHandler(h);
        targetContract(address(handler));
    }

    function invariant_totalSupplyEqualsSumBalances() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            sum += h.balanceOf(handler.actorAt(i));
        }
        assertEq(sum, h.totalSupply(), "totalSupply must equal sum of balances");
    }

    // Unit: moveShares / burnShares revert (checked arithmetic) on insufficient balance.
    function test_moveRevertsOnInsufficientBalance() public {
        h.mint(address(0xA11CE), 100);
        vm.expectRevert();
        h.move(address(0xA11CE), address(0xB0B), 101);
        vm.expectRevert();
        h.burn(address(0xA11CE), 101);
    }

    function test_transferRevertsOnZeroAddress() public {
        h.mint(address(0xA11CE), 100);
        vm.expectRevert();
        h.transfer(address(0xA11CE), address(0), 10);
        vm.expectRevert();
        h.transfer(address(0), address(0xB0B), 10);
    }

    function test_approveSetsAllowance() public {
        h.approve(address(0xA11CE), address(0xB0B), 42);
        assertEq(h.allowance(address(0xA11CE), address(0xB0B)), 42);
    }
}
