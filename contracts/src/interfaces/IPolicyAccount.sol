// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Smart account holding an agent's borrowed funds. Funds can only go to whitelisted payees / calls,
///         or back to the protocol. Kept implementation-neutral so it can later be swapped for an ERC-7579 module.
interface IPolicyAccount {
    function agentId() external view returns (uint256);
    function operator() external view returns (address);
    function pay(address token, address payee, uint256 amount) external;
    function execute(address target, uint256 value, bytes calldata data) external returns (bytes memory);
    function approveSpender(address spender, uint256 amount) external;
    function spentInWindow() external view returns (uint256);
    // manager only
    function setOperator(address newOperator) external;
    function sweep(address to, uint256 amount) external returns (uint256 swept);
}
