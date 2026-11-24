// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IRepaymentSplitter {
    function agentId() external view returns (uint256);
    /// @notice Split the splitter's USDG balance: repayment share to the manager, rest to the agent's payout wallet.
    function distribute() external returns (uint256 revenue, uint256 toPayout);
    /// @notice Forward a non-USDG token to the payout wallet (not counted as revenue).
    function rescueToken(address token) external;
    // manager only
    function sweep(address to) external returns (uint256);
}
