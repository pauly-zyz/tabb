// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TabbDeployer} from "./TabbDeployer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TabbPool} from "../src/pool/TabbPool.sol";
import {PayeeRegistry} from "../src/agent/PayeeRegistry.sol";
import {OwnerStakeVault} from "../src/agent/OwnerStakeVault.sol";
import {AgentCreditManager} from "../src/agent/AgentCreditManager.sol";
import {MockUSDG} from "../test/mocks/MockUSDG.sol";
import {MockERC8004IdentityRegistry} from "../test/mocks/MockERC8004IdentityRegistry.sol";
import {MockYieldToken} from "../test/mocks/MockYieldToken.sol";

/// @notice Local anvil deployment with mocks and demo data.
///   anvil &
///   forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
/// Uses anvil's public test accounts: #0 deployer/owner/guardian/treasury/curator, #1 lender, #2 agent owner,
/// #3 demo compute provider (payee).
contract DeployLocal is TabbDeployer {
    uint256 internal constant ANVIL_PK0 = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant ANVIL_PK1 = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant ANVIL_PK2 = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    address internal constant PROVIDER = 0x90F79bf6EB2c4f870365E785982E1f101E93b906; // anvil #3

    function run() external {
        require(block.chainid == 31337, "DeployLocal: anvil only");
        address deployer = vm.addr(ANVIL_PK0);
        address lender = vm.addr(ANVIL_PK1);
        address agentOwner = vm.addr(ANVIL_PK2);

        vm.startBroadcast(ANVIL_PK0);
        MockUSDG usdg = new MockUSDG();
        MockERC8004IdentityRegistry idReg = new MockERC8004IdentityRegistry();
        for (uint256 i; i < 5; ++i) {
            usdg.mint(_anvil(i), 1_000_000e6);
        }
        Core memory c = _deployCore(address(usdg), address(idReg), deployer, deployer, deployer);
        PayeeRegistry(c.payeeRegistry).setPayee(PROVIDER, true, "Demo compute provider");
        vm.stopBroadcast();

        // lender liquidity
        vm.startBroadcast(ANVIL_PK1);
        IERC20(address(usdg)).approve(c.pool, type(uint256).max);
        TabbPool(c.pool).deposit(50_000e6, lender);
        vm.stopBroadcast();

        // demo agent: register, stake, open, draw, earn once
        vm.startBroadcast(ANVIL_PK2);
        uint256 agentId = idReg.register("ipfs://tabb-demo-agent");
        IERC20(address(usdg)).approve(c.stakeVault, type(uint256).max);
        IERC20(address(usdg)).approve(c.agentCreditManager, type(uint256).max);
        OwnerStakeVault(c.stakeVault).stake(agentId, 500e6);
        AgentCreditManager mgr = AgentCreditManager(c.agentCreditManager);
        mgr.openTab(agentId, agentOwner, agentOwner);
        mgr.draw(agentId, 80e6);
        vm.stopBroadcast();

        _writeDeployment(c, "demoProvider", PROVIDER);

        // ---------------- Phase 2: yield credit (separate pool) ----------------
        vm.startBroadcast(ANVIL_PK0);
        YieldCore memory y = _deployYieldCore(address(usdg), c.irm, deployer, deployer, deployer);
        y = _deployYieldMocks(y, address(usdg));
        for (uint256 i; i < 5; ++i) {
            MockYieldToken(y.yieldToken).mint(_anvil(i), 10_000e18);
        }
        vm.stopBroadcast();
        vm.startBroadcast(ANVIL_PK1);
        IERC20(address(usdg)).approve(y.pool, type(uint256).max);
        TabbPool(y.pool).deposit(50_000e6, lender);
        vm.stopBroadcast();
        _writeYield(y);
    }

    function _anvil(uint256 i) internal pure returns (address) {
        address[5] memory a = [
            0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,
            0x90F79bf6EB2c4f870365E785982E1f101E93b906,
            0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
        ];
        return a[i];
    }
}
