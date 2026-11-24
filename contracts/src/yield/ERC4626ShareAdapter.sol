// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ICollateralAdapter} from "../interfaces/ICollateralAdapter.sol";

/// @title ERC4626ShareAdapter
/// @notice Custodies shares of a USDG ERC-4626 vault per tab. Yield = growth of the position above a per-tab
///         high-water mark (`principalAssets`); harvest redeems exactly that growth into USDG.
/// @dev Valued in USDG directly (vault asset == debt asset), so no price oracle is needed. Only whitelist vaults
///      whose share price cannot be pushed up cheaply (donation-resistant accounting) — see SECURITY.md.
contract ERC4626ShareAdapter is ICollateralAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC4626 public immutable vault;
    IERC20 internal immutable _usdg;
    address public immutable tabManager;

    mapping(uint256 => uint256) public balanceOf;
    mapping(uint256 => uint256) public principalAssets;
    uint256 public totalBalance;

    event Deposited(uint256 indexed tabId, uint256 shares, uint256 assets);
    event Withdrawn(uint256 indexed tabId, address to, uint256 shares, bool seized);
    event Harvested(uint256 indexed tabId, uint256 shares, uint256 usdgOut);

    error NotTabManager();
    error InsufficientBalance();
    error ZeroAddress();

    constructor(IERC4626 vault_, address tabManager_) {
        if (address(vault_) == address(0) || tabManager_ == address(0)) revert ZeroAddress();
        vault = vault_;
        _usdg = IERC20(vault_.asset());
        tabManager = tabManager_;
    }

    modifier onlyTabManager() {
        if (msg.sender != tabManager) revert NotTabManager();
        _;
    }

    function asset() external view returns (address) {
        return address(vault);
    }

    function usdg() external view returns (address) {
        return address(_usdg);
    }

    function isEquityLinked() external pure returns (bool) {
        return false;
    }

    function canBorrow() external pure returns (bool) {
        return true;
    }

    function valueInUSDG(uint256 tabId, uint8) external view returns (uint256) {
        return vault.previewRedeem(balanceOf[tabId]);
    }

    function valueOfAmount(uint256 amount, uint8) external view returns (uint256) {
        return vault.previewRedeem(amount);
    }

    function amountForValue(uint256 usdgValue, uint8) external view returns (uint256) {
        return vault.convertToShares(usdgValue);
    }

    function pendingYield(uint256 tabId) public view returns (uint256) {
        uint256 v = vault.previewRedeem(balanceOf[tabId]);
        uint256 p = principalAssets[tabId];
        return v > p ? v - p : 0;
    }

    function deposit(uint256 tabId, address from, uint256 amount) external onlyTabManager nonReentrant {
        IERC20(address(vault)).safeTransferFrom(from, address(this), amount);
        balanceOf[tabId] += amount;
        totalBalance += amount;
        uint256 assets = vault.previewRedeem(amount);
        principalAssets[tabId] += assets;
        emit Deposited(tabId, amount, assets);
    }

    function withdraw(uint256 tabId, address to, uint256 amount) external onlyTabManager nonReentrant {
        _out(tabId, to, amount);
        emit Withdrawn(tabId, to, amount, false);
    }

    function seize(uint256 tabId, address to, uint256 amount) external onlyTabManager nonReentrant {
        _out(tabId, to, amount);
        emit Withdrawn(tabId, to, amount, true);
    }

    function harvest(uint256 tabId, address to) external onlyTabManager nonReentrant returns (uint256 usdgOut) {
        uint256 y = pendingYield(tabId);
        if (y == 0) return 0;
        uint256 shares = Math.min(vault.previewWithdraw(y), balanceOf[tabId]);
        balanceOf[tabId] -= shares;
        totalBalance -= shares;
        usdgOut = vault.redeem(shares, to, address(this));
        // keep the high-water mark at or below the remaining value
        uint256 v = vault.previewRedeem(balanceOf[tabId]);
        if (principalAssets[tabId] > v) principalAssets[tabId] = v;
        emit Harvested(tabId, shares, usdgOut);
    }

    function _out(uint256 tabId, address to, uint256 amount) internal {
        uint256 bal = balanceOf[tabId];
        if (amount > bal) revert InsufficientBalance();
        principalAssets[tabId] -= Math.mulDiv(principalAssets[tabId], amount, bal);
        balanceOf[tabId] = bal - amount;
        totalBalance -= amount;
        IERC20(address(vault)).safeTransfer(to, amount);
    }
}
