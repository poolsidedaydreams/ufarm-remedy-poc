// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IUFarmCore} from "../../src/interfaces/IUFarmCore.sol";
import {IUFarmOracleConsumer} from "../../src/interfaces/IUFarmOracleConsumer.sol";
import {IUFarmOracle} from "../../src/interfaces/IUFarmOracle.sol";

/// @notice Minimal stub of UFarmCore for vault-lifecycle PoCs.
/// Only the functions the vault/escrow actually call are meaningfully implemented.
contract MockCore is IUFarmCore {
    address public escrowAddr;
    address public oracleAddr;
    address public curatorAddr;
    mapping(bytes32 => address) public modules;
    mapping(address => uint256) public masks;
    uint256 public allowedFluctuation;
    uint256 public cooldown = 0;
    uint256 public timeout = 300;
    uint256 public price = 1e18; // USD per whole token (18-dec asset => identity)
    uint256 public pauseMask;

    function setPauseMask(uint256 m) external { pauseMask = m; }
    function setEscrow(address e) external { escrowAddr = e; }
    function setOracle(address o) external { oracleAddr = o; }
    function setCurator(address c) external { curatorAddr = c; }
    function setModule(bytes32 id, address m) external { modules[id] = m; }
    function setAllowedFluctuation(uint256 f) external { allowedFluctuation = f; }
    function setCooldown(uint256 c) external { cooldown = c; }

    // --- IUFarmPermissions ---
    function setPermissionMask(address account, uint256 newMask) external { masks[account] = newMask; }
    function permissionMask(address account) external view returns (uint256) { return masks[account]; }
    function accountHasPermission(address account, uint256 mask) external view returns (bool) {
        return mask != 0 && (masks[account] & mask) == mask;
    }
    function accountHasAnyPermission(address account, uint256 mask) external view returns (bool) {
        return mask != 0 && (masks[account] & mask) != 0;
    }

    // --- value token pricing (identity at $1, 18 decimals) ---
    function valueTokenConfig(address) external view returns (ValueTokenConfig memory config) {
        config.feed = address(0x1);
        config.tokenUnit = 1e18;
        config.feedUnit = 1e18;
    }
    function setValueTokenConfig(address, address, uint32, uint96, uint96) external {}
    function clearValueTokenConfig(address) external {}
    function valueTokenToUsd(address, uint256 amt) external view returns (uint256) {
        return amt * price / 1e18;
    }
    function usdToValueToken(address, uint256 usd) external view returns (uint256) {
        return usd * 1e18 / price;
    }

    function oracleForVault(address) external view returns (address) { return oracleAddr; }
    function adapterForVault(bytes32, address) external pure returns (address) { return address(0); }
    function vaultModule(bytes32 moduleId) external view returns (address) { return modules[moduleId]; }
    function globalPauseMask() external view returns (uint256) { return pauseMask; }
    function curatorPauseMask(address) external pure returns (uint256) { return 0; }
    function navRequestCooldown() external view returns (uint256) { return cooldown; }
    function oracleRequestTimeout() external view returns (uint256) { return timeout; }
    function setProtocolFee(address, uint256, bool) external {}
    function protocolFee(address) external pure returns (uint256, bool) { return (0, false); }
    function clearProtocolFee(address) external {}
    function allowedPriceFluctuation() external view returns (uint256) { return allowedFluctuation; }
    function accountingChainId() external view returns (uint64) { return uint64(block.chainid); }
    function crossChainRouter() external pure returns (address) { return address(0); }
    function crossChainFeeToken() external pure returns (address) { return address(0); }
    function crossChainToken() external pure returns (address) { return address(0); }
    function crossChainGasLimit() external pure returns (uint256) { return 0; }
    function ccipSelectorForChain(uint64) external pure returns (uint64) { return 0; }
    function escrow() external view returns (address) { return escrowAddr; }
    function deterministicDeployer() external pure returns (address) { return address(0); }
    function curatorBeacon() external pure returns (address) { return address(0); }
    function vaultBeacon() external pure returns (address) { return address(0); }
    function isCurator(address c) external view returns (bool) { return c == curatorAddr; }
    function createCurator(address, bytes32) external pure returns (address) { return address(0); }
    function setVaultOperator(address, address, bool) external pure returns (bool) { return false; }
    function requestVaultRedeem(address, uint256) external pure returns (uint256) { return 0; }
    function claimVaultRedeem(address, address) external pure returns (uint256) { return 0; }
}

contract MockCurator {
    function isVault(address) external pure returns (bool) { return true; }
}

contract MockOracle is IUFarmOracle {
    uint256 public nextId = 1;
    function requestNav(address) external returns (uint256) {
        return nextId++;
    }
    function deliver(address vault, uint256 requestId, uint256 nav, uint64 ts) external {
        IUFarmOracleConsumer(vault).onOracleNav(requestId, nav, ts);
    }
}
