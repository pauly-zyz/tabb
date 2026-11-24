// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IAgentRiskConfig {
    struct Params {
        uint256 minStake; // USDG units
        uint256 baseLimit; // starting limit for a staked agent
        uint256 maxPerAgent;
        uint256 maxPerOwner; // across all agents of one borrower of record (principal)
        uint256 minDebt;
        uint256 minCyclePeak; // min peak debt for a cycle to count
        uint16 revenueAdvanceBps; // share of windowed splitter revenue that can be advanced
        uint16 defaultSplitBps;
        uint16 minSplitBps;
        uint16 minPaymentBps; // min payment per period, bps of debt at period start
        uint16 dailySpendCapBps; // PolicyAccount spend cap per 24h, bps of credit limit
        uint16 distributeFeeBps; // protocol fee on splitter revenue
        uint32 paymentPeriod;
        uint32 gracePeriod;
        uint32 defaultDelay;
        uint32 stakeCooldown;
        uint32 minCycleDuration;
        uint8 windowEpochs; // revenue window in 7-day epochs (<= 26)
    }

    struct Tier {
        uint16 minCycles;
        uint32 minAge;
        uint32 cleanWindow; // no delinquency within this window
        uint32 leverageBps; // credit limit <= stake * leverage
    }

    function params() external view returns (Params memory);
    function tier(uint256 i) external view returns (Tier memory);
    function tierCount() external view returns (uint256);
    function feeRecipient() external view returns (address);
    function isOwnerAllowed(address owner) external view returns (bool);
}
