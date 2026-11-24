// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IAgentRiskConfig} from "../interfaces/IAgentRiskConfig.sol";

/// @notice Conservative default agent-credit parameters from docs/DESIGN.md section 7 (6-decimal USDG).
library AgentRiskDefaults {
    function params() internal pure returns (IAgentRiskConfig.Params memory p) {
        uint256 one = 1e6;
        p = IAgentRiskConfig.Params({
            minStake: 100 * one,
            baseLimit: 100 * one,
            maxPerAgent: 1_000 * one,
            maxPerOwner: 3_000 * one,
            minDebt: 10 * one,
            minCyclePeak: 50 * one,
            revenueAdvanceBps: 2_500,
            defaultSplitBps: 2_000,
            minSplitBps: 1_000,
            minPaymentBps: 1_200,
            dailySpendCapBps: 2_500,
            distributeFeeBps: 0,
            paymentPeriod: 30 days,
            gracePeriod: 7 days,
            defaultDelay: 30 days,
            stakeCooldown: 7 days,
            minCycleDuration: 7 days,
            windowEpochs: 13
        });
    }

    function tiers() internal pure returns (IAgentRiskConfig.Tier[] memory t) {
        t = new IAgentRiskConfig.Tier[](3);
        t[0] = IAgentRiskConfig.Tier({minCycles: 0, minAge: 0, cleanWindow: 0, leverageBps: 10_000});
        t[1] = IAgentRiskConfig.Tier({minCycles: 3, minAge: 30 days, cleanWindow: 90 days, leverageBps: 15_000});
        t[2] = IAgentRiskConfig.Tier({minCycles: 10, minAge: 90 days, cleanWindow: 180 days, leverageBps: 20_000});
    }
}
