// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Surface of AgentCreditManager used by the stake vault, PolicyAccount and RepaymentSplitter.
interface IAgentCreditManager {
    function stakeLocked(uint256 agentId, address staker) external view returns (bool);
    function canSpend(uint256 agentId) external view returns (bool);
    function dailySpendCap(uint256 agentId) external view returns (uint256);
    function payoutOf(uint256 agentId) external view returns (address);
    /// @notice Called by the agent's splitter with `amount` of fresh revenue it has approved to the manager.
    /// @return payout where the splitter must send whatever the manager did not pull
    function processRevenue(uint256 agentId, uint256 amount) external returns (address payout);
}
