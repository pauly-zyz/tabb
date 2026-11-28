// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TabbDeployer} from "./TabbDeployer.sol";
import {TabbConfig} from "./Config.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PayeeRegistry} from "../src/agent/PayeeRegistry.sol";
import {RegistryBootstrap} from "../src/external/erc8004/RegistryBootstrap.sol";
import {IdentityRegistryUpgradeable} from "../src/external/erc8004/IdentityRegistryUpgradeable.sol";

/// @notice Elysium (Kinetiq, chain 99901) deployment: a self-hosted ERC-8004 IdentityRegistry (the canonical one does
///         not exist on Elysium) + Tabb Phase 1 with USDC. Robinhood Chain deployments are untouched.
///
///   forge script script/DeployElysium.s.sol --rpc-url $ELYSIUM_RPC_URL --broadcast --slow
///
/// Env:
///   ELYSIUM_DEPLOYER_PRIVATE_KEY  hot key used only to deploy + wire (needs HYPE for gas and TABB_SEED_USDG USDC)
///   TABB_OWNER                    REQUIRED, differs from the deployer. Gets the IdentityRegistry ownership directly
///                                 and Tabb ownership via Ownable2Step (accept on the web /admin page).
///   TABB_GUARDIAN / TABB_TREASURY / TABB_PAYEE_CURATOR  optional, default TABB_OWNER
///   TABB_SEED_USDG                optional seed deposit in 6-decimals units (default 10)
contract DeployElysium is TabbDeployer {
    uint256 internal constant DEFAULT_SEED = 10e6;

    function run() external {
        require(block.chainid == TabbConfig.ELYSIUM, "DeployElysium: chain 99901 only");
        uint256 pk = vm.envUint("ELYSIUM_DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address owner_ = vm.envAddress("TABB_OWNER");
        require(owner_ != address(0) && owner_ != deployer, "TABB_OWNER must be set and differ from the deployer");
        address guardian = vm.envOr("TABB_GUARDIAN", owner_);
        address treasury = vm.envOr("TABB_TREASURY", owner_);
        address curator = vm.envOr("TABB_PAYEE_CURATOR", owner_);
        uint256 seed = vm.envOr("TABB_SEED_USDG", DEFAULT_SEED);

        TabbConfig.External memory e = TabbConfig.externalFor(block.chainid);
        require(e.usdg != address(0) && e.usdg.code.length > 0, "stablecoin missing in Config");
        require(IERC20Metadata(e.usdg).decimals() == 6, "stablecoin must have 6 decimals");
        require(IERC20(e.usdg).balanceOf(deployer) >= seed && seed > 0, "deployer needs seed stablecoin");

        vm.startBroadcast(pk);
        address registry = _deployIdentityRegistry(deployer);
        // Reserve agentId 0 so public agent IDs start at 1 (as on other chains); the placeholder goes to the owner.
        uint256 reserved = IdentityRegistryUpgradeable(registry).register("ipfs://tabb-reserved-agent-0");
        require(reserved == 0, "unexpected first agentId");
        IdentityRegistryUpgradeable(registry).transferFrom(deployer, owner_, 0);
        IdentityRegistryUpgradeable(registry).transferOwnership(owner_);

        Core memory c = _deployCore(e.usdg, registry, deployer, guardian, treasury, seed);
        PayeeRegistry(c.payeeRegistry).setCurator(curator, true);
        address[6] memory owned =
            [c.pool, c.riskConfig, c.stakeVault, c.creditScore, c.payeeRegistry, c.agentCreditManager];
        for (uint256 i; i < owned.length; ++i) {
            (bool ok,) = owned[i].call(abi.encodeWithSignature("transferOwnership(address)", owner_));
            require(ok, "transferOwnership failed");
        }
        vm.stopBroadcast();

        _writeDeployment(c, "", address(0));
    }

    /// @dev ERC1967 proxy -> RegistryBootstrap(owner = deployer) -> upgrade to IdentityRegistryUpgradeable + initialize.
    function _deployIdentityRegistry(address deployer) internal returns (address proxy) {
        address bootstrap = address(new RegistryBootstrap());
        address impl = address(new IdentityRegistryUpgradeable());
        proxy = address(new ERC1967Proxy(bootstrap, abi.encodeCall(RegistryBootstrap.initialize, (deployer))));
        RegistryBootstrap(proxy).upgradeToAndCall(impl, abi.encodeCall(IdentityRegistryUpgradeable.initialize, ()));
        require(
            keccak256(bytes(IdentityRegistryUpgradeable(proxy).name())) == keccak256("AgentIdentity"),
            "registry init failed"
        );
    }
}
