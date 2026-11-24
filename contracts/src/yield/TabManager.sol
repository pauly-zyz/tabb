// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ICreditLine} from "../interfaces/ICreditLine.sol";
import {ITabbPool} from "../interfaces/ITabbPool.sol";

/// @title TabManager (Phase 2 stub)
/// @notice Placeholder for the yield-backed credit line (docs/DESIGN.md section 9). It implements ICreditLine so the
///         pool wiring for a second credit line can be exercised now; all mutating entrypoints revert.
contract TabManager is ICreditLine {
    bytes32 public constant KIND = keccak256("TABB_YIELD_CREDIT_V1");
    ITabbPool internal immutable _pool;

    error NotImplemented();

    constructor(ITabbPool pool_) {
        _pool = pool_;
    }

    function pool() external view returns (address) {
        return address(_pool);
    }

    function totalScaledDebt() external pure returns (uint256) {
        return 0;
    }

    function creditLineKind() external pure returns (bytes32) {
        return KIND;
    }

    function openTab(address) external pure returns (uint256) {
        revert NotImplemented();
    }

    function addCollateral(uint256, uint256) external pure {
        revert NotImplemented();
    }

    function borrow(uint256, uint256) external pure {
        revert NotImplemented();
    }

    function repay(uint256, uint256) external pure {
        revert NotImplemented();
    }

    function withdrawCollateral(uint256, uint256) external pure {
        revert NotImplemented();
    }

    function closeTab(uint256) external pure {
        revert NotImplemented();
    }
}
