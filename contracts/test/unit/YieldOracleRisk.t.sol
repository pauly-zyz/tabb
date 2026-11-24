// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {YieldFixture} from "../utils/YieldFixture.sol";
import {OracleRouter} from "../../src/yield/OracleRouter.sol";
import {YieldRiskConfig} from "../../src/yield/YieldRiskConfig.sol";
import {IOracleRouter} from "../../src/interfaces/IOracleRouter.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {TabbAccessControl} from "../../src/access/TabbAccessControl.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";

contract OracleRouterTest is YieldFixture {
    function test_priceNormalized() public view {
        assertEq(oracle.getPrice(address(yt), IOracleRouter.Purpose.BORROW), 10e18);
    }

    function test_revert_noFeed() public {
        vm.expectRevert(OracleRouter.NoFeed.selector);
        oracle.getPrice(address(1), IOracleRouter.Purpose.VIEW);
    }

    function test_revert_invalidAndStale() public {
        ytFeed.set(0);
        vm.expectRevert(OracleRouter.InvalidPrice.selector);
        oracle.getPrice(address(yt), IOracleRouter.Purpose.BORROW);
        ytFeed.set(-1);
        vm.expectRevert(OracleRouter.InvalidPrice.selector);
        oracle.getPrice(address(yt), IOracleRouter.Purpose.BORROW);
        ytFeed.set(10e8);
        ytFeed.setAnsweredInRound(0);
        vm.expectRevert(OracleRouter.StalePrice.selector);
        oracle.getPrice(address(yt), IOracleRouter.Purpose.BORROW);
        ytFeed.set(10e8);
        ytFeed.setUpdatedAt(0);
        vm.expectRevert(OracleRouter.StalePrice.selector);
        oracle.getPrice(address(yt), IOracleRouter.Purpose.BORROW);
    }

    function test_heartbeat() public {
        skip(1 hours + 1);
        vm.expectRevert(OracleRouter.StalePrice.selector);
        oracle.getPrice(address(yt), IOracleRouter.Purpose.BORROW);
        // VIEW skips staleness
        assertEq(oracle.getPrice(address(yt), IOracleRouter.Purpose.VIEW), 10e18);
        // liquidation while market open uses the open heartbeat
        vm.expectRevert(OracleRouter.StalePrice.selector);
        oracle.getPrice(address(yt), IOracleRouter.Purpose.LIQUIDATION);
        // market closed -> extended heartbeat for liquidations only
        vm.prank(owner);
        oracle.setMarketOpen(address(yt), false);
        assertEq(oracle.getPrice(address(yt), IOracleRouter.Purpose.LIQUIDATION), 10e18);
        vm.expectRevert(OracleRouter.StalePrice.selector);
        oracle.getPrice(address(yt), IOracleRouter.Purpose.BORROW);
        skip(80 hours);
        vm.expectRevert(OracleRouter.StalePrice.selector);
        oracle.getPrice(address(yt), IOracleRouter.Purpose.LIQUIDATION);
    }

    function test_sequencer() public {
        seqFeed.set(1); // down
        assertFalse(oracle.isSequencerHealthy());
        vm.expectRevert(OracleRouter.SequencerDown.selector);
        oracle.getPrice(address(yt), IOracleRouter.Purpose.BORROW);
        seqFeed.set(0);
        seqFeed.setStartedAt(block.timestamp - 10); // just restarted
        vm.expectRevert(OracleRouter.GracePeriodNotOver.selector);
        oracle.getPrice(address(yt), IOracleRouter.Purpose.LIQUIDATION);
        assertFalse(oracle.isSequencerHealthy());
        assertEq(oracle.getPrice(address(yt), IOracleRouter.Purpose.VIEW), 10e18);
        skip(3601);
        ytFeed.set(10e8);
        assertTrue(oracle.isSequencerHealthy());
        oracle.getPrice(address(yt), IOracleRouter.Purpose.BORROW);
        vm.prank(owner);
        oracle.setSequencer(IAggregatorV3(address(0)), 0, false);
        assertTrue(oracle.isSequencerHealthy());
    }

    function test_marketStatus() public {
        assertTrue(oracle.isMarketOpen(address(yt)));
        address mk = makeAddr("marketKeeper");
        vm.expectRevert(OracleRouter.NotMarketKeeper.selector);
        vm.prank(mk);
        oracle.setMarketOpen(address(yt), false);
        vm.prank(owner);
        oracle.setMarketKeeper(mk, true);
        vm.prank(mk);
        oracle.setMarketOpen(address(yt), false);
        assertFalse(oracle.isMarketOpen(address(yt)));
        // a status feed overrides the manual flag
        MockAggregator status = new MockAggregator(0, 1);
        vm.prank(owner);
        oracle.setMarketStatusFeed(address(yt), IAggregatorV3(address(status)));
        assertTrue(oracle.isMarketOpen(address(yt)));
        status.set(0);
        assertFalse(oracle.isMarketOpen(address(yt)));
        // broken feed fails closed
        vm.prank(owner);
        oracle.setMarketStatusFeed(address(yt), IAggregatorV3(address(0xdead)));
        assertFalse(oracle.isMarketOpen(address(yt)));
    }

    function test_adminValidation() public {
        vm.startPrank(owner);
        vm.expectRevert(TabbAccessControl.ZeroAddress.selector);
        oracle.setFeed(address(0), IAggregatorV3(address(ytFeed)), 1, 1);
        vm.expectRevert(OracleRouter.InvalidParam.selector);
        oracle.setFeed(address(yt), IAggregatorV3(address(ytFeed)), 0, 1);
        vm.expectRevert(OracleRouter.InvalidParam.selector);
        oracle.setFeed(address(yt), IAggregatorV3(address(ytFeed)), 10, 5);
        vm.expectRevert(TabbAccessControl.ZeroAddress.selector);
        oracle.setSequencer(IAggregatorV3(address(0)), 0, true);
        vm.expectRevert(OracleRouter.InvalidParam.selector);
        oracle.setSequencer(IAggregatorV3(address(seqFeed)), 2 days, true);
        oracle.setFeed(address(yt), IAggregatorV3(address(0)), 0, 0); // remove feed
        vm.stopPrank();
    }
}

contract YieldRiskConfigTest is YieldFixture {
    function _p() internal pure returns (YieldRiskConfig.CollateralParams memory) {
        return YieldRiskConfig.CollateralParams({
            status: YieldRiskConfig.Status.Active,
            maxLtvBps: 8_000,
            liqThresholdBps: 8_500,
            liqBonusBps: 500,
            closedMarketLtvBps: 0,
            supplyCap: 1,
            borrowCap: 1
        });
    }

    function _expect(YieldRiskConfig.CollateralParams memory p) internal {
        vm.prank(owner);
        vm.expectRevert(YieldRiskConfig.InvalidParams.selector);
        risk.setCollateral(address(0xA), p);
    }

    function test_collateralValidation() public {
        YieldRiskConfig.CollateralParams memory p = _p();
        p.status = YieldRiskConfig.Status.None;
        _expect(p);
        p = _p();
        p.maxLtvBps = 0;
        _expect(p);
        p = _p();
        p.maxLtvBps = 8_500;
        _expect(p);
        p = _p();
        p.liqThresholdBps = 9_600;
        _expect(p);
        p = _p();
        p.liqBonusBps = 2_001;
        _expect(p);
        p = _p();
        p.liqThresholdBps = 9_500;
        p.liqBonusBps = 600; // 95% * 1.06 > 100%
        _expect(p);
        p = _p();
        p.closedMarketLtvBps = 9_000;
        _expect(p);
        vm.prank(owner);
        vm.expectRevert(TabbAccessControl.ZeroAddress.selector);
        risk.setCollateral(address(0), _p());
        vm.prank(owner);
        risk.setCollateral(address(0xA), _p());
        assertEq(risk.adapterCount(), 3);
        vm.prank(owner);
        risk.setCollateral(address(0xA), _p()); // update does not duplicate
        assertEq(risk.adapterCount(), 3);
    }

    function test_globalValidation() public {
        YieldRiskConfig.GlobalParams memory g = risk.defaultGlobal();
        assertEq(g.closeFactorBps, 5_000);
        vm.startPrank(owner);
        g.closeFactorBps = 0;
        vm.expectRevert(YieldRiskConfig.InvalidParams.selector);
        risk.setGlobal(g);
        g = risk.defaultGlobal();
        g.fullLiquidationHfWad = 1.1e18;
        vm.expectRevert(YieldRiskConfig.InvalidParams.selector);
        risk.setGlobal(g);
        g = risk.defaultGlobal();
        g.harvestRewardBps = 501;
        vm.expectRevert(YieldRiskConfig.InvalidParams.selector);
        risk.setGlobal(g);
        g = risk.defaultGlobal();
        g.minDebt = 1;
        risk.setGlobal(g);
        vm.stopPrank();
        assertEq(risk.global().minDebt, 1);
    }
}
