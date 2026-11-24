// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IPayeeRegistry {
    function isPayee(address payee) external view returns (bool);
    function isAllowedCall(address target, bytes4 selector) external view returns (bool);
    function spendingPaused() external view returns (bool);
}
