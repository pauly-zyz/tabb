// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {InterestRateModel} from "../../src/pool/InterestRateModel.sol";

contract InterestRateModelTest is Test {
    InterestRateModel irm;
    uint256 constant WAD = 1e18;

    function setUp() public {
        irm = new InterestRateModel(0, 0.06e18, 0.8e18, 0.6e18);
    }

    function test_zeroUtilization() public view {
        assertEq(irm.borrowRate(0), 0);
    }

    function test_atKink() public view {
        assertEq(irm.borrowRate(0.8e18), 0.06e18);
    }

    function test_belowKinkLinear() public view {
        assertEq(irm.borrowRate(0.4e18), 0.03e18);
    }

    function test_aboveKink() public view {
        assertEq(irm.borrowRate(0.9e18), 0.06e18 + 0.3e18);
        assertEq(irm.borrowRate(WAD), 0.66e18);
    }

    function test_utilizationAboveOneIsCapped() public view {
        assertEq(irm.borrowRate(2e18), irm.borrowRate(WAD));
    }

    function test_revert_invalidKink() public {
        vm.expectRevert(InterestRateModel.InvalidParams.selector);
        new InterestRateModel(0, 1, 0, 1);
        vm.expectRevert(InterestRateModel.InvalidParams.selector);
        new InterestRateModel(0, 1, WAD, 1);
    }

    function test_revert_rateTooHigh() public {
        vm.expectRevert(InterestRateModel.InvalidParams.selector);
        new InterestRateModel(5e18, 5e18, 0.5e18, 1e18);
    }

    function testFuzz_monotonic(uint256 a, uint256 b) public view {
        a = bound(a, 0, WAD);
        b = bound(b, a, WAD);
        assertLe(irm.borrowRate(a), irm.borrowRate(b));
    }
}
