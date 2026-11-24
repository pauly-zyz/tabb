// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {TabbAccessControl} from "../access/TabbAccessControl.sol";
import {IOwnerStakeVault} from "../interfaces/IOwnerStakeVault.sol";
import {IAgentCreditManager} from "../interfaces/IAgentCreditManager.sol";

/// @title OwnerStakeVault
/// @notice Holds USDG stakes posted by agent owners, keyed by (agentId, staker). The stake of a tab's borrower of
///         record is first-loss capital: locked while the tab has debt (plus a cooldown) and slashable on default.
contract OwnerStakeVault is IOwnerStakeVault, TabbAccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant PAUSE_WITHDRAW = 1 << 0;

    IERC20 public immutable usdg;
    IAgentCreditManager public manager;

    mapping(uint256 agentId => mapping(address staker => uint256)) public stakeOf;
    mapping(uint256 agentId => uint256) public totalStakeOf;

    event ManagerSet(address manager);
    event Staked(uint256 indexed agentId, address indexed staker, uint256 amount);
    event Withdrawn(uint256 indexed agentId, address indexed staker, address to, uint256 amount);
    event Slashed(uint256 indexed agentId, address indexed staker, address to, uint256 amount);

    error ManagerAlreadySet();
    error NotManager();
    error StakeLocked();
    error ZeroAmount();
    error InsufficientStake();
    error UnsupportedToken();

    constructor(IERC20 usdg_, address owner_, address guardian_) TabbAccessControl(owner_, guardian_) {
        if (address(usdg_) == address(0)) revert ZeroAddress();
        usdg = usdg_;
    }

    /// @notice One-time wiring (the manager is deployed after the vault).
    function setManager(IAgentCreditManager manager_) external onlyOwner {
        if (address(manager) != address(0)) revert ManagerAlreadySet();
        if (address(manager_) == address(0)) revert ZeroAddress();
        manager = manager_;
        emit ManagerSet(address(manager_));
    }

    /// @notice Stake USDG for `agentId`. Never paused (adding stake only reduces risk).
    function stake(uint256 agentId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 before = usdg.balanceOf(address(this));
        usdg.safeTransferFrom(msg.sender, address(this), amount);
        if (usdg.balanceOf(address(this)) - before != amount) revert UnsupportedToken();
        stakeOf[agentId][msg.sender] += amount;
        totalStakeOf[agentId] += amount;
        emit Staked(agentId, msg.sender, amount);
    }

    function withdraw(uint256 agentId, uint256 amount, address to)
        external
        nonReentrant
        whenNotPaused(PAUSE_WITHDRAW)
    {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        if (address(manager) != address(0) && manager.stakeLocked(agentId, msg.sender)) revert StakeLocked();
        uint256 bal = stakeOf[agentId][msg.sender];
        if (amount > bal) revert InsufficientStake();
        stakeOf[agentId][msg.sender] = bal - amount;
        totalStakeOf[agentId] -= amount;
        usdg.safeTransfer(to, amount);
        emit Withdrawn(agentId, msg.sender, to, amount);
    }

    /// @inheritdoc IOwnerStakeVault
    function slash(uint256 agentId, address staker, uint256 amount, address to)
        external
        nonReentrant
        returns (uint256 slashed)
    {
        if (msg.sender != address(manager)) revert NotManager();
        uint256 bal = stakeOf[agentId][staker];
        slashed = amount < bal ? amount : bal;
        if (slashed == 0) return 0;
        stakeOf[agentId][staker] = bal - slashed;
        totalStakeOf[agentId] -= slashed;
        usdg.safeTransfer(to, slashed);
        emit Slashed(agentId, staker, to, slashed);
    }
}
