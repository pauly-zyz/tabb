// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPolicyAccount} from "../interfaces/IPolicyAccount.sol";
import {IPayeeRegistry} from "../interfaces/IPayeeRegistry.sol";
import {IAgentCreditManager} from "../interfaces/IAgentCreditManager.sol";

/// @title PolicyAccount
/// @notice Per-agent account (EIP-1167 clone) that receives borrowed USDG. The agent's operator key can only:
///         - pay(): send tokens to curated payees (USDG counted against a rolling 24h cap),
///         - approveSpender(): approve USDG to a curated payee (counted against the cap),
///         - execute(): call curated (target, selector) pairs; USDG itself can never be a target.
///         The manager can rotate the operator and sweep funds back on repay / default / close.
contract PolicyAccount is IPolicyAccount, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bool public initialized;
    address public manager;
    IPayeeRegistry public payees;
    IERC20 public usdg;
    uint256 public agentId;
    address public operator;
    uint64 public windowStart;
    uint256 internal _spent;

    event Initialized(address manager, uint256 agentId, address operator);
    event OperatorSet(address operator);
    event Paid(address indexed token, address indexed payee, uint256 amount);
    event SpenderApproved(address indexed spender, uint256 amount);
    event Executed(address indexed target, bytes4 selector, uint256 value);
    event Swept(address indexed to, uint256 amount);

    error AlreadyInitialized();
    error NotOperator();
    error NotManager();
    error NotPayee();
    error CallNotAllowed();
    error SpendingFrozen();
    error DailyCapExceeded();
    error ZeroAddress();

    constructor() {
        initialized = true; // lock the implementation
    }

    function initialize(address manager_, IPayeeRegistry payees_, IERC20 usdg_, uint256 agentId_, address operator_)
        external
    {
        if (initialized) revert AlreadyInitialized();
        if (manager_ == address(0) || address(payees_) == address(0) || address(usdg_) == address(0)) {
            revert ZeroAddress();
        }
        initialized = true;
        manager = manager_;
        payees = payees_;
        usdg = usdg_;
        agentId = agentId_;
        operator = operator_;
        emit Initialized(manager_, agentId_, operator_);
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    modifier onlyManager() {
        if (msg.sender != manager) revert NotManager();
        _;
    }

    receive() external payable {}

    // ------------------------------------------------------------------ operator actions

    function pay(address token, address payee, uint256 amount) external onlyOperator nonReentrant {
        if (!payees.isPayee(payee)) revert NotPayee();
        _checkSpend(token == address(usdg) ? amount : 0);
        IERC20(token).safeTransfer(payee, amount);
        emit Paid(token, payee, amount);
    }

    function approveSpender(address spender, uint256 amount) external onlyOperator nonReentrant {
        if (!payees.isPayee(spender)) revert NotPayee();
        _checkSpend(amount);
        usdg.forceApprove(spender, amount);
        emit SpenderApproved(spender, amount);
    }

    function execute(address target, uint256 value, bytes calldata data)
        external
        onlyOperator
        nonReentrant
        returns (bytes memory result)
    {
        if (target == address(usdg) || target == address(this) || target == manager || data.length < 4) {
            revert CallNotAllowed();
        }
        bytes4 selector = bytes4(data[:4]);
        if (!payees.isAllowedCall(target, selector)) revert CallNotAllowed();
        _checkSpend(0);
        uint256 before = usdg.balanceOf(address(this));
        bool ok;
        (ok, result) = target.call{value: value}(data);
        if (!ok) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
        // USDG may only leave through allowances already counted by approveSpender
        uint256 afterBal = usdg.balanceOf(address(this));
        if (afterBal < before) _consume(before - afterBal);
        emit Executed(target, selector, value);
    }

    // ------------------------------------------------------------------ manager actions

    function setOperator(address newOperator) external onlyManager {
        operator = newOperator;
        emit OperatorSet(newOperator);
    }

    function sweep(address to, uint256 amount) external onlyManager nonReentrant returns (uint256 swept) {
        uint256 bal = usdg.balanceOf(address(this));
        swept = amount < bal ? amount : bal;
        if (swept > 0) usdg.safeTransfer(to, swept);
        emit Swept(to, swept);
    }

    // ------------------------------------------------------------------ views / internals

    function spentInWindow() public view returns (uint256) {
        return block.timestamp >= uint256(windowStart) + 1 days ? 0 : _spent;
    }

    function _checkSpend(uint256 usdgAmount) internal {
        if (!IAgentCreditManager(manager).canSpend(agentId)) revert SpendingFrozen();
        if (usdgAmount > 0) _consume(usdgAmount);
    }

    function _consume(uint256 amount) internal {
        if (block.timestamp >= uint256(windowStart) + 1 days) {
            windowStart = uint64(block.timestamp);
            _spent = 0;
        }
        uint256 newSpent = _spent + amount;
        if (newSpent > IAgentCreditManager(manager).dailySpendCap(agentId)) revert DailyCapExceeded();
        _spent = newSpent;
    }
}
