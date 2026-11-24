// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title TabbAccessControl
/// @notice Owner (Ownable2Step, intended to be a TimelockController) + a separate pause guardian.
/// @dev Pausing uses a bitmask so each contract can pause individual actions. The guardian can only
///      pause; unpausing is owner-only.
abstract contract TabbAccessControl is Ownable2Step {
    address public guardian;
    uint256 public pausedFlags;

    event GuardianUpdated(address indexed previousGuardian, address indexed newGuardian);
    event Paused(address indexed by, uint256 flags);
    event Unpaused(address indexed by, uint256 flags);

    error NotGuardianOrOwner();
    error ActionPaused(uint256 flag);
    error ZeroAddress();

    constructor(address initialOwner, address initialGuardian) Ownable(initialOwner) {
        guardian = initialGuardian;
        emit GuardianUpdated(address(0), initialGuardian);
    }

    modifier whenNotPaused(uint256 flag) {
        if (pausedFlags & flag != 0) revert ActionPaused(flag);
        _;
    }

    function setGuardian(address newGuardian) external onlyOwner {
        emit GuardianUpdated(guardian, newGuardian);
        guardian = newGuardian;
    }

    function pause(uint256 flags) external {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardianOrOwner();
        pausedFlags |= flags;
        emit Paused(msg.sender, flags);
    }

    function unpause(uint256 flags) external onlyOwner {
        pausedFlags &= ~flags;
        emit Unpaused(msg.sender, flags);
    }

    function isPaused(uint256 flag) public view returns (bool) {
        return pausedFlags & flag != 0;
    }
}
