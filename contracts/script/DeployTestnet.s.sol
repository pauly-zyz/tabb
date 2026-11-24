// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TabbDeployer} from "./TabbDeployer.sol";
import {TabbConfig} from "./Config.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PayeeRegistry} from "../src/agent/PayeeRegistry.sol";
import {MockUSDG} from "../test/mocks/MockUSDG.sol";
import {MockERC8004IdentityRegistry} from "../test/mocks/MockERC8004IdentityRegistry.sol";

/// @notice Testnet deployment. Refuses Robinhood Chain mainnet (4663) and anvil.
///   source .env
///   forge script script/DeployTestnet.s.sol --rpc-url $ROBINHOOD_TESTNET_RPC_URL --broadcast
/// Env: DEPLOYER_PRIVATE_KEY (testnet only), optional TABB_GUARDIAN / TABB_TREASURY / TABB_PAYEE_CURATOR / TABB_OWNER,
///      TABB_USDG / TABB_IDENTITY_REGISTRY to override Config, DEPLOY_MOCKS=true to deploy MockUSDG + mock registry.
contract DeployTestnet is TabbDeployer {
    function run() external {
        _assertNotMainnet();
        require(block.chainid != 31337, "use DeployLocal on anvil");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address guardian = vm.envOr("TABB_GUARDIAN", deployer);
        address treasury = vm.envOr("TABB_TREASURY", deployer);
        address curator = vm.envOr("TABB_PAYEE_CURATOR", deployer);
        address finalOwner = vm.envOr("TABB_OWNER", deployer);

        TabbConfig.External memory e = TabbConfig.externalFor(block.chainid);
        address usdg = vm.envOr("TABB_USDG", e.usdg);
        address idReg = vm.envOr("TABB_IDENTITY_REGISTRY", e.identityRegistry);
        bool mocks = vm.envOr("DEPLOY_MOCKS", false);

        vm.startBroadcast(pk);
        if (usdg == address(0)) {
            require(mocks, "USDG address is TODO: fill script/Config.s.sol, set TABB_USDG, or DEPLOY_MOCKS=true");
            MockUSDG m = new MockUSDG();
            m.mint(deployer, 1_000_000e6);
            usdg = address(m);
        }
        if (idReg == address(0)) {
            require(mocks, "ERC-8004 registry is TODO: fill Config.s.sol, set TABB_IDENTITY_REGISTRY, or DEPLOY_MOCKS");
            idReg = address(new MockERC8004IdentityRegistry());
        }
        require(IERC20Metadata(usdg).decimals() == 6, "USDG must have 6 decimals");
        require(IERC20(usdg).balanceOf(deployer) >= SEED_DEPOSIT, "deployer needs seed USDG");

        Core memory c = _deployCore(usdg, idReg, deployer, guardian, treasury);
        if (curator != deployer) PayeeRegistry(c.payeeRegistry).setCurator(curator, true);
        if (finalOwner != deployer) _handOver(c, finalOwner);

        // Phase 2 (opt-in): DEPLOY_YIELD=true. Real vault / YT / feeds are TODO in Config.s.sol; with DEPLOY_MOCKS the
        // mock vault + YT are wired, otherwise only the core is deployed and collateral must be added by the owner.
        bool yieldOn = vm.envOr("DEPLOY_YIELD", false);
        YieldCore memory y;
        if (yieldOn) {
            y = _deployYieldCore(usdg, c.irm, deployer, guardian, treasury);
            if (mocks) y = _deployYieldMocks(y, usdg);
        }
        vm.stopBroadcast();

        _writeDeployment(c, "", address(0));
        if (yieldOn) _writeYield(y);
    }

    /// @dev Starts Ownable2Step transfers; `finalOwner` (e.g. a TimelockController) must call acceptOwnership().
    function _handOver(Core memory c, address finalOwner) internal {
        address[5] memory owned = [c.pool, c.riskConfig, c.stakeVault, c.creditScore, c.payeeRegistry];
        for (uint256 i; i < owned.length; ++i) {
            (bool ok,) = owned[i].call(abi.encodeWithSignature("transferOwnership(address)", finalOwner));
            require(ok, "transferOwnership failed");
        }
        (bool ok2,) = c.agentCreditManager.call(abi.encodeWithSignature("transferOwnership(address)", finalOwner));
        require(ok2, "transferOwnership failed");
    }
}
