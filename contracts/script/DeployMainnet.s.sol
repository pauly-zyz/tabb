// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TabbDeployer} from "./TabbDeployer.sol";
import {TabbConfig} from "./Config.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PayeeRegistry} from "../src/agent/PayeeRegistry.sol";

/// @notice Robinhood Chain mainnet (4663) deployment of Phase 1 (agent credit) with real USDG and the real ERC-8004
///         Identity Registry. Phase 2 is NOT deployed on mainnet until verified price feeds / vault / YT exist.
///
///   forge script script/DeployMainnet.s.sol --rpc-url $ROBINHOOD_MAINNET_RPC_URL --broadcast --slow
///
/// Env:
///   MAINNET_DEPLOYER_PRIVATE_KEY  hot key used only to deploy + wire (needs ETH for gas and TABB_SEED_USDG USDG)
///   TABB_OWNER                    REQUIRED, must differ from the deployer. Receives ownership of every contract via
///                                 Ownable2Step (must call acceptOwnership on each; the web /admin page does this).
///   TABB_GUARDIAN / TABB_TREASURY / TABB_PAYEE_CURATOR  optional, default TABB_OWNER
///   TABB_SEED_USDG                optional seed deposit to 0xdead in 6-decimals units (default 10 USDG)
contract DeployMainnet is TabbDeployer {
    uint256 internal constant DEFAULT_MAINNET_SEED = 10e6;

    function run() external {
        require(block.chainid == TabbConfig.ROBINHOOD_MAINNET, "DeployMainnet: chain 4663 only");
        uint256 pk = vm.envUint("MAINNET_DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address owner_ = vm.envAddress("TABB_OWNER");
        require(owner_ != address(0) && owner_ != deployer, "TABB_OWNER must be set and differ from the deployer");
        address guardian = vm.envOr("TABB_GUARDIAN", owner_);
        address treasury = vm.envOr("TABB_TREASURY", owner_);
        address curator = vm.envOr("TABB_PAYEE_CURATOR", owner_);
        uint256 seed = vm.envOr("TABB_SEED_USDG", DEFAULT_MAINNET_SEED);

        TabbConfig.External memory e = TabbConfig.externalFor(block.chainid);
        require(e.usdg != address(0) && e.identityRegistry != address(0), "mainnet addresses missing in Config");
        require(e.usdg.code.length > 0 && e.identityRegistry.code.length > 0, "no code at configured addresses");
        require(IERC20Metadata(e.usdg).decimals() == 6, "USDG must have 6 decimals");
        require(seed > 0 && IERC20(e.usdg).balanceOf(deployer) >= seed, "deployer needs TABB_SEED_USDG USDG");

        vm.startBroadcast(pk);
        Core memory c = _deployCore(e.usdg, e.identityRegistry, deployer, guardian, treasury, seed);
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
}
