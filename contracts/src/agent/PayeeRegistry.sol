// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {TabbAccessControl} from "../access/TabbAccessControl.sol";
import {IPayeeRegistry} from "../interfaces/IPayeeRegistry.sol";

/// @title PayeeRegistry
/// @notice Global, curated whitelist of where agents' borrowed funds may go: payee addresses (service providers)
///         and (target, selector) pairs for PolicyAccount.execute. Curators are appointed by the owner. The guardian
///         can freeze all PolicyAccount spending via pause(PAUSE_SPENDING).
contract PayeeRegistry is IPayeeRegistry, TabbAccessControl {
    uint256 public constant PAUSE_SPENDING = 1 << 0;

    mapping(address => bool) public isCurator;
    mapping(address => bool) public isPayee;
    mapping(address => mapping(bytes4 => bool)) internal _allowedCalls;
    address[] public payeeList;
    mapping(address => bool) internal _listed;

    event CuratorSet(address indexed curator, bool enabled);
    event PayeeSet(address indexed payee, bool allowed, string label);
    event AllowedCallSet(address indexed target, bytes4 indexed selector, bool allowed);

    error NotCurator();

    constructor(address owner_, address guardian_) TabbAccessControl(owner_, guardian_) {}

    modifier onlyCurator() {
        if (!isCurator[msg.sender] && msg.sender != owner()) revert NotCurator();
        _;
    }

    function setCurator(address curator, bool enabled) external onlyOwner {
        if (curator == address(0)) revert ZeroAddress();
        isCurator[curator] = enabled;
        emit CuratorSet(curator, enabled);
    }

    function setPayee(address payee, bool allowed, string calldata label) external onlyCurator {
        if (payee == address(0)) revert ZeroAddress();
        isPayee[payee] = allowed;
        if (allowed && !_listed[payee]) {
            _listed[payee] = true;
            payeeList.push(payee);
        }
        emit PayeeSet(payee, allowed, label);
    }

    function setAllowedCall(address target, bytes4 selector, bool allowed) external onlyCurator {
        if (target == address(0)) revert ZeroAddress();
        _allowedCalls[target][selector] = allowed;
        emit AllowedCallSet(target, selector, allowed);
    }

    function isAllowedCall(address target, bytes4 selector) external view returns (bool) {
        return _allowedCalls[target][selector];
    }

    function spendingPaused() external view returns (bool) {
        return isPaused(PAUSE_SPENDING);
    }

    function payeeCount() external view returns (uint256) {
        return payeeList.length;
    }
}
