// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Deterministic, on-chain credit scoring for agents.
interface IAgentCreditScore {
    struct Breakdown {
        uint256 stake;
        uint256 tier;
        uint256 leverageBps;
        uint256 revenue; // splitter revenue within the window
        uint256 revenueLimit;
        uint256 capacity; // max(baseLimit, revenueLimit)
        uint256 stakeLimit;
        uint256 limit;
        uint256 score; // 0..1000, display only
    }

    function creditLimit(uint256 agentId, address owner) external view returns (uint256);
    function tierOf(uint256 agentId) external view returns (uint256);
    function score(uint256 agentId, address owner) external view returns (uint256);
    function breakdown(uint256 agentId, address owner) external view returns (Breakdown memory);
    function revenueInWindow(uint256 agentId) external view returns (uint256);

    // manager hooks
    function onFirstSeen(uint256 agentId) external;
    function recordRevenue(uint256 agentId, uint256 amount) external;
    function onCycleCompleted(uint256 agentId, bool qualified) external;
    function onDelinquent(uint256 agentId) external;
    function onDefault(uint256 agentId) external;
}
