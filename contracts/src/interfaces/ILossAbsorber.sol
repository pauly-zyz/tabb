// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Hook for a future junior tranche / insurance fund. When bad debt is written off, the pool asks the
///         absorber to cover it by transferring the pool's asset to the pool. MVP: not set (address(0)).
interface ILossAbsorber {
    /// @return absorbed amount of asset transferred to the pool (pool verifies via balance delta)
    function absorbLoss(uint256 loss) external returns (uint256 absorbed);
}
