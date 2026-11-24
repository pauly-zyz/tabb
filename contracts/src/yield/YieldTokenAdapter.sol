// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ICollateralAdapter} from "../interfaces/ICollateralAdapter.sol";
import {IClipYieldToken} from "../interfaces/IClipYieldToken.sol";
import {IOracleRouter} from "../interfaces/IOracleRouter.sol";

/// @title YieldTokenAdapter
/// @notice Custodies Clipt stock-dividend YT per tab. The adapter claims dividends in aggregate and attributes them
///         per tab with an accumulator (checkpoint before every balance change). Valuation = oracle price ×
///         (1 − maturity haircut) + pending dividends; equity-linked → subject to "market closed" mode.
/// @dev Assumes 18-decimal YT, 6-decimal USDG, dividends paid in USDG (Q-Y2).
contract YieldTokenAdapter is ICollateralAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant ACC = 1e30;

    IClipYieldToken public immutable yt;
    IERC20 internal immutable _usdg;
    IOracleRouter public immutable oracle;
    address public immutable tabManager;
    uint16 public immutable baseHaircutBps;
    uint16 public immutable annualHaircutBps;
    uint16 public immutable maxHaircutBps;
    uint32 public immutable minTimeToMaturity;

    mapping(uint256 => uint256) public balanceOf;
    mapping(uint256 => uint256) public rewardDebt;
    mapping(uint256 => uint256) public storedYield;
    uint256 public totalBalance;
    uint256 public accPerToken;

    event Deposited(uint256 indexed tabId, uint256 amount);
    event Withdrawn(uint256 indexed tabId, address to, uint256 amount, bool seized);
    event Harvested(uint256 indexed tabId, uint256 usdgOut);

    error NotTabManager();
    error InsufficientBalance();
    error ZeroAddress();
    error InvalidHaircut();

    struct Haircut {
        uint16 baseBps;
        uint16 annualBps;
        uint16 maxBps;
        uint32 minTimeToMaturity;
    }

    constructor(IClipYieldToken yt_, IERC20 usdg_, IOracleRouter oracle_, address tabManager_, Haircut memory h) {
        if (
            address(yt_) == address(0) || address(usdg_) == address(0) || address(oracle_) == address(0)
                || tabManager_ == address(0)
        ) revert ZeroAddress();
        if (h.baseBps > h.maxBps || h.maxBps >= 10_000) revert InvalidHaircut();
        yt = yt_;
        _usdg = usdg_;
        oracle = oracle_;
        tabManager = tabManager_;
        baseHaircutBps = h.baseBps;
        annualHaircutBps = h.annualBps;
        maxHaircutBps = h.maxBps;
        minTimeToMaturity = h.minTimeToMaturity;
    }

    modifier onlyTabManager() {
        if (msg.sender != tabManager) revert NotTabManager();
        _;
    }

    // ------------------------------------------------------------------ views

    function asset() external view returns (address) {
        return address(yt);
    }

    function usdg() external view returns (address) {
        return address(_usdg);
    }

    function isEquityLinked() external pure returns (bool) {
        return true;
    }

    function timeToMaturity() public view returns (uint256) {
        uint256 m = yt.maturity();
        return m > block.timestamp ? m - block.timestamp : 0;
    }

    function canBorrow() external view returns (bool) {
        return timeToMaturity() >= minTimeToMaturity;
    }

    /// @notice Haircut grows with remaining tenor: longer = more uncertain dividends.
    function haircutBps() public view returns (uint256) {
        uint256 h = baseHaircutBps + Math.mulDiv(annualHaircutBps, timeToMaturity(), 365 days);
        return Math.min(h, maxHaircutBps);
    }

    /// @dev USDG per 1e18 YT (6 decimals), after haircut and USD->USDG conversion.
    function _unitValue(uint8 purpose) internal view returns (uint256) {
        uint256 px = oracle.getPrice(address(yt), IOracleRouter.Purpose(purpose)); // USD WAD per YT
        uint256 usdgPx = 1e18;
        try oracle.getPrice(address(_usdg), IOracleRouter.Purpose.VIEW) returns (uint256 p) {
            usdgPx = Math.max(p, 1e18); // conservative: never value USDG above $1
        } catch {}
        uint256 haircut = haircutBps();
        // px [1e18 USD] * (1 - h) / usdgPx -> USD per YT in 1e18; /1e12 -> 6 decimals
        return Math.mulDiv(px * (10_000 - haircut), 1e6, usdgPx * 10_000);
    }

    function valueOfAmount(uint256 amount, uint8 purpose) public view returns (uint256) {
        if (amount == 0) return 0;
        return Math.mulDiv(amount, _unitValue(purpose), 1e18);
    }

    function amountForValue(uint256 usdgValue, uint8 purpose) external view returns (uint256) {
        uint256 u = _unitValue(purpose);
        return u == 0 ? 0 : Math.mulDiv(usdgValue, 1e18, u);
    }

    function valueInUSDG(uint256 tabId, uint8 purpose) external view returns (uint256) {
        return valueOfAmount(balanceOf[tabId], purpose) + pendingYield(tabId);
    }

    function pendingYield(uint256 tabId) public view returns (uint256) {
        uint256 acc = accPerToken;
        if (totalBalance > 0) acc += Math.mulDiv(yt.claimable(address(this)), ACC, totalBalance);
        return storedYield[tabId] + Math.mulDiv(balanceOf[tabId], acc, ACC) - rewardDebt[tabId];
    }

    // ------------------------------------------------------------------ mutating

    function deposit(uint256 tabId, address from, uint256 amount) external onlyTabManager nonReentrant {
        _checkpoint();
        _settle(tabId);
        IERC20(address(yt)).safeTransferFrom(from, address(this), amount);
        balanceOf[tabId] += amount;
        totalBalance += amount;
        rewardDebt[tabId] = Math.mulDiv(balanceOf[tabId], accPerToken, ACC);
        emit Deposited(tabId, amount);
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
        _checkpoint();
        _settle(tabId);
        usdgOut = storedYield[tabId];
        if (usdgOut == 0) return 0;
        storedYield[tabId] = 0;
        _usdg.safeTransfer(to, usdgOut);
        emit Harvested(tabId, usdgOut);
    }

    function _out(uint256 tabId, address to, uint256 amount) internal {
        if (amount > balanceOf[tabId]) revert InsufficientBalance();
        _checkpoint();
        _settle(tabId);
        balanceOf[tabId] -= amount;
        totalBalance -= amount;
        rewardDebt[tabId] = Math.mulDiv(balanceOf[tabId], accPerToken, ACC);
        IERC20(address(yt)).safeTransfer(to, amount);
    }

    /// @dev Claims all dividends owed to the adapter and spreads them over the YT it holds.
    function _checkpoint() internal {
        if (totalBalance == 0) return;
        uint256 before = _usdg.balanceOf(address(this));
        yt.claim();
        uint256 claimed = _usdg.balanceOf(address(this)) - before;
        if (claimed > 0) accPerToken += Math.mulDiv(claimed, ACC, totalBalance);
    }

    function _settle(uint256 tabId) internal {
        uint256 accrued = Math.mulDiv(balanceOf[tabId], accPerToken, ACC);
        storedYield[tabId] += accrued - rewardDebt[tabId];
        rewardDebt[tabId] = accrued;
    }
}
