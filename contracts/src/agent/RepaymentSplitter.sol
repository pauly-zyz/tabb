// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IRepaymentSplitter} from "../interfaces/IRepaymentSplitter.sol";
import {IAgentCreditManager} from "../interfaces/IAgentCreditManager.sol";

/// @title RepaymentSplitter
/// @notice An agent's public payment address (EIP-1167 clone). Anyone can call distribute(): the manager pulls the
///         repayment share (splitBps, 100% while delinquent, recovery after default) and the rest goes to the agent's
///         payout wallet. Revenue that flows through here is what builds the agent's credit limit.
contract RepaymentSplitter is IRepaymentSplitter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bool public initialized;
    IAgentCreditManager public manager;
    IERC20 public usdg;
    uint256 public agentId;
    uint256 public totalRevenue;

    event Initialized(address manager, uint256 agentId);
    event Distributed(uint256 revenue, uint256 toManager, uint256 toPayout, address payout);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event Swept(address indexed to, uint256 amount);

    error AlreadyInitialized();
    error NotManager();
    error InvalidToken();
    error ZeroAddress();

    constructor() {
        initialized = true;
    }

    function initialize(IAgentCreditManager manager_, IERC20 usdg_, uint256 agentId_) external {
        if (initialized) revert AlreadyInitialized();
        if (address(manager_) == address(0) || address(usdg_) == address(0)) revert ZeroAddress();
        initialized = true;
        manager = manager_;
        usdg = usdg_;
        agentId = agentId_;
        emit Initialized(address(manager_), agentId_);
    }

    /// @inheritdoc IRepaymentSplitter
    function distribute() external nonReentrant returns (uint256 revenue, uint256 toPayout) {
        revenue = usdg.balanceOf(address(this));
        if (revenue == 0) return (0, 0);
        totalRevenue += revenue;
        usdg.forceApprove(address(manager), revenue);
        address payout = manager.processRevenue(agentId, revenue);
        usdg.forceApprove(address(manager), 0);
        toPayout = usdg.balanceOf(address(this));
        if (toPayout > 0 && payout != address(0)) usdg.safeTransfer(payout, toPayout);
        emit Distributed(revenue, revenue - toPayout, toPayout, payout);
    }

    /// @inheritdoc IRepaymentSplitter
    function rescueToken(address token) external nonReentrant {
        if (token == address(usdg)) revert InvalidToken();
        address payout = manager.payoutOf(agentId);
        if (payout == address(0)) revert ZeroAddress();
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(payout, bal);
        emit Rescued(token, payout, bal);
    }

    /// @inheritdoc IRepaymentSplitter
    function sweep(address to) external nonReentrant returns (uint256 amount) {
        if (msg.sender != address(manager)) revert NotManager();
        amount = usdg.balanceOf(address(this));
        if (amount > 0) usdg.safeTransfer(to, amount);
        emit Swept(to, amount);
    }
}
