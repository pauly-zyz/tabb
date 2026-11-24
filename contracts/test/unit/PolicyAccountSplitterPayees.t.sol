// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentFixture} from "../utils/AgentFixture.sol";
import {PolicyAccount} from "../../src/agent/PolicyAccount.sol";
import {RepaymentSplitter} from "../../src/agent/RepaymentSplitter.sol";
import {PayeeRegistry} from "../../src/agent/PayeeRegistry.sol";
import {TabbAccessControl} from "../../src/access/TabbAccessControl.sol";
import {IPayeeRegistry} from "../../src/interfaces/IPayeeRegistry.sol";
import {IAgentCreditManager} from "../../src/interfaces/IAgentCreditManager.sol";
import {MockService} from "../mocks/MockService.sol";
import {MockUSDG} from "../mocks/MockUSDG.sol";

contract PolicyAccountTest is AgentFixture {
    uint256 id;
    PolicyAccount pa;

    function setUp() public override {
        super.setUp();
        id = _newAgent(alice, 100 * ONE);
        _draw(id, alice, 100 * ONE);
        pa = _pa(id);
    }

    function test_payToPayee() public {
        vm.prank(operator);
        pa.pay(address(usdg), provider, 20 * ONE);
        assertEq(usdg.balanceOf(provider), 20 * ONE);
        assertEq(pa.spentInWindow(), 20 * ONE);
    }

    function test_revert_payNotPayee() public {
        vm.prank(operator);
        vm.expectRevert(PolicyAccount.NotPayee.selector);
        pa.pay(address(usdg), alice, 1);
    }

    function test_revert_payNotOperator() public {
        vm.prank(alice);
        vm.expectRevert(PolicyAccount.NotOperator.selector);
        pa.pay(address(usdg), provider, 1);
    }

    function test_dailyCapAndReset() public {
        // cap = 25% of limit 100 = 25
        vm.startPrank(operator);
        pa.pay(address(usdg), provider, 25 * ONE);
        vm.expectRevert(PolicyAccount.DailyCapExceeded.selector);
        pa.pay(address(usdg), provider, 1);
        vm.stopPrank();
        skip(1 days);
        assertEq(pa.spentInWindow(), 0);
        vm.prank(operator);
        pa.pay(address(usdg), provider, 25 * ONE);
    }

    function test_nonUsdgTokenNotCapped() public {
        MockUSDG other = new MockUSDG();
        other.mint(address(pa), 1_000 * ONE);
        vm.prank(operator);
        pa.pay(address(other), provider, 1_000 * ONE);
        assertEq(pa.spentInWindow(), 0);
    }

    function test_frozenWhenSpendingPaused() public {
        uint256 flag = payees.PAUSE_SPENDING();
        vm.prank(guardian);
        payees.pause(flag);
        vm.prank(operator);
        vm.expectRevert(PolicyAccount.SpendingFrozen.selector);
        pa.pay(address(usdg), provider, 1);
    }

    function test_frozenWhenDelinquent() public {
        skip(37 days);
        mgr.markDelinquent(id);
        vm.prank(operator);
        vm.expectRevert(PolicyAccount.SpendingFrozen.selector);
        pa.pay(address(usdg), provider, 1);
    }

    function test_approveAndExecute() public {
        vm.startPrank(operator);
        pa.approveSpender(address(service), 10 * ONE);
        pa.execute(address(service), 0, abi.encodeCall(MockService.buyCredits, (10 * ONE)));
        vm.stopPrank();
        assertEq(service.credits(address(pa)), 10 * ONE);
        assertEq(pa.spentInWindow(), 20 * ONE); // approval + observed outflow (conservative)
    }

    function test_executeWithValue() public {
        vm.deal(address(pa), 1 ether);
        vm.prank(operator);
        bytes memory r = pa.execute(address(service), 0.5 ether, abi.encodeCall(MockService.ping, ()));
        assertEq(abi.decode(r, (uint256)), 1);
        assertEq(address(service).balance, 0.5 ether);
    }

    function test_revert_executeBubblesError() public {
        vm.prank(operator);
        vm.expectRevert(bytes("boom"));
        pa.execute(address(service), 0, abi.encodeCall(MockService.boom, ()));
    }

    function test_revert_executeForbiddenTargets() public {
        vm.startPrank(operator);
        vm.expectRevert(PolicyAccount.CallNotAllowed.selector);
        pa.execute(address(usdg), 0, abi.encodeCall(IERC20.transfer, (operator, 1)));
        vm.expectRevert(PolicyAccount.CallNotAllowed.selector);
        pa.execute(address(pa), 0, hex"12345678");
        vm.expectRevert(PolicyAccount.CallNotAllowed.selector);
        pa.execute(address(mgr), 0, hex"12345678");
        vm.expectRevert(PolicyAccount.CallNotAllowed.selector);
        pa.execute(address(service), 0, hex"12");
        vm.expectRevert(PolicyAccount.CallNotAllowed.selector);
        pa.execute(address(service), 0, hex"deadbeef");
        vm.stopPrank();
    }

    function test_revert_approveNotPayee() public {
        vm.prank(operator);
        vm.expectRevert(PolicyAccount.NotPayee.selector);
        pa.approveSpender(alice, 1);
    }

    function test_revert_managerOnly() public {
        vm.expectRevert(PolicyAccount.NotManager.selector);
        pa.sweep(alice, 1);
        vm.expectRevert(PolicyAccount.NotManager.selector);
        pa.setOperator(alice);
    }

    function test_revert_reinitialize() public {
        vm.expectRevert(PolicyAccount.AlreadyInitialized.selector);
        pa.initialize(address(1), IPayeeRegistry(address(1)), IERC20(address(1)), 1, address(1));
        PolicyAccount impl = PolicyAccount(payable(mgr.policyAccountImpl()));
        vm.expectRevert(PolicyAccount.AlreadyInitialized.selector);
        impl.initialize(address(1), IPayeeRegistry(address(1)), IERC20(address(1)), 1, address(1));
    }

    function test_receiveEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(pa).call{value: 1 ether}("");
        assertTrue(ok);
    }
}

contract SplitterTest is AgentFixture {
    uint256 id;
    RepaymentSplitter sp;

    function setUp() public override {
        super.setUp();
        id = _newAgent(alice, 100 * ONE);
        sp = _splitter(id);
    }

    function test_distributeEmpty() public {
        (uint256 r, uint256 p) = sp.distribute();
        assertEq(r, 0);
        assertEq(p, 0);
    }

    function test_rescueToken() public {
        MockUSDG other = new MockUSDG();
        other.mint(address(sp), 7);
        sp.rescueToken(address(other));
        assertEq(other.balanceOf(alice), 7);
        vm.expectRevert(RepaymentSplitter.InvalidToken.selector);
        sp.rescueToken(address(usdg));
    }

    function test_revert_sweepNotManager() public {
        vm.expectRevert(RepaymentSplitter.NotManager.selector);
        sp.sweep(alice);
    }

    function test_revert_reinitialize() public {
        vm.expectRevert(RepaymentSplitter.AlreadyInitialized.selector);
        sp.initialize(IAgentCreditManager(address(1)), IERC20(address(1)), 1);
    }

    function test_revert_initZero() public {
        // fresh, uninitialized clone-like instance is impossible (constructor locks); use a raw clone
        address raw = _clone(mgr.splitterImpl());
        vm.expectRevert(RepaymentSplitter.ZeroAddress.selector);
        RepaymentSplitter(raw).initialize(IAgentCreditManager(address(0)), IERC20(address(usdg)), 1);
        address raw2 = _clone(mgr.policyAccountImpl());
        vm.expectRevert(PolicyAccount.ZeroAddress.selector);
        PolicyAccount(payable(raw2)).initialize(address(0), payees, usdg, 1, address(0));
    }

    function _clone(address impl) internal returns (address inst) {
        bytes memory code = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", impl, hex"5af43d82803e903d91602b57fd5bf3"
        );
        assembly {
            inst := create(0, add(code, 32), mload(code))
        }
    }
}

contract PayeeRegistryTest is AgentFixture {
    address curator = makeAddr("curator");

    function test_curatorFlow() public {
        vm.prank(alice);
        vm.expectRevert(PayeeRegistry.NotCurator.selector);
        payees.setPayee(alice, true, "x");
        vm.prank(owner);
        payees.setCurator(curator, true);
        vm.startPrank(curator);
        payees.setPayee(alice, true, "alice svc");
        payees.setPayee(alice, false, "removed");
        payees.setPayee(alice, true, "again");
        payees.setAllowedCall(alice, bytes4(0x11111111), true);
        vm.stopPrank();
        assertTrue(payees.isPayee(alice));
        assertTrue(payees.isAllowedCall(alice, bytes4(0x11111111)));
        assertEq(payees.payeeCount(), 3); // provider, service, alice (listed once)
        assertFalse(payees.spendingPaused());
    }

    function test_revert_zero() public {
        vm.startPrank(owner);
        vm.expectRevert(TabbAccessControl.ZeroAddress.selector);
        payees.setCurator(address(0), true);
        vm.expectRevert(TabbAccessControl.ZeroAddress.selector);
        payees.setPayee(address(0), true, "");
        vm.expectRevert(TabbAccessControl.ZeroAddress.selector);
        payees.setAllowedCall(address(0), bytes4(0), true);
        vm.stopPrank();
    }
}
