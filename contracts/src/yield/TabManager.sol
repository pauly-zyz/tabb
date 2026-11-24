// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {TabbAccessControl} from "../access/TabbAccessControl.sol";
import {TabbMath} from "../libraries/TabbMath.sol";
import {ICreditLine} from "../interfaces/ICreditLine.sol";
import {ITabbPool} from "../interfaces/ITabbPool.sol";
import {ICollateralAdapter} from "../interfaces/ICollateralAdapter.sol";
import {IOracleRouter} from "../interfaces/IOracleRouter.sol";
import {YieldRiskConfig} from "./YieldRiskConfig.sol";

/// @title TabManager
/// @notice Phase 2 credit line: overcollateralized, self-repaying tabs against yield-bearing collateral.
///         One tab per (owner, collateral adapter). Harvested yield pays interest first, then principal; once the
///         debt is zero, extra yield is credited to the owner (pull). Partial liquidation below HF 1.
contract TabManager is ICreditLine, TabbAccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using TabbMath for uint256;

    bytes32 public constant KIND = keccak256("TABB_YIELD_CREDIT_V1");
    uint256 public constant PAUSE_OPEN = 1 << 0;
    uint256 public constant PAUSE_BORROW = 1 << 1;
    uint256 public constant PAUSE_WITHDRAW = 1 << 2;

    uint8 internal constant BORROW = uint8(IOracleRouter.Purpose.BORROW);
    uint8 internal constant LIQ = uint8(IOracleRouter.Purpose.LIQUIDATION);
    uint8 internal constant VIEW = uint8(IOracleRouter.Purpose.VIEW);

    struct Tab {
        address owner;
        address adapter;
        bool open;
        uint64 openedAt;
        uint256 scaledDebt;
        uint256 principal;
        uint256 yieldRepaid;
        uint256 totalRepaid;
    }

    IERC20 public immutable usdg;
    ITabbPool internal immutable _pool;
    IOracleRouter public immutable oracle;
    YieldRiskConfig public immutable risk;
    address public harvester;
    address public liquidator;

    mapping(uint256 => Tab) internal _tabs;
    uint256 public nextTabId = 1;
    mapping(address => mapping(address => uint256)) public tabIdOf;
    mapping(address => uint256) public ownerCredit;
    mapping(address => uint256) public principalByAdapter;
    uint256 internal _totalScaledDebt;

    event PeripherySet(address harvester, address liquidator);
    event TabOpened(uint256 indexed tabId, address indexed owner, address indexed adapter);
    event CollateralAdded(uint256 indexed tabId, address indexed from, uint256 amount);
    event CollateralWithdrawn(uint256 indexed tabId, uint256 amount);
    event Borrowed(uint256 indexed tabId, uint256 amount, uint256 scaled);
    event Repaid(uint256 indexed tabId, address indexed from, uint256 amount, uint256 interest, uint256 principal);
    event Harvested(uint256 indexed tabId, address indexed keeper, uint256 yield, uint256 reward, uint256 repaid, uint256 credited);
    event Liquidated(uint256 indexed tabId, address indexed liquidator, uint256 repaid, uint256 seized, uint256 badDebt);
    event TabClosed(uint256 indexed tabId);
    event CreditClaimed(address indexed owner, uint256 amount);

    error NotOwner();
    error NotHarvester();
    error NotLiquidator();
    error AlreadySet();
    error InvalidStatus();
    error TabExists();
    error TabNotOpen();
    error SupplyCapExceeded();
    error BorrowCapExceeded();
    error BorrowFrozen();
    error MaturityTooClose();
    error InsufficientCollateral();
    error BelowMinDebt();
    error HasDebt();
    error HasCollateral();
    error BelowMinHarvest();
    error Healthy();
    error ZeroAmount();
    error ScaledMismatch();

    constructor(
        IERC20 usdg_,
        ITabbPool pool_,
        IOracleRouter oracle_,
        YieldRiskConfig risk_,
        address owner_,
        address guardian_
    ) TabbAccessControl(owner_, guardian_) {
        if (
            address(usdg_) == address(0) || address(pool_) == address(0) || address(oracle_) == address(0)
                || address(risk_) == address(0)
        ) revert ZeroAddress();
        usdg = usdg_;
        _pool = pool_;
        oracle = oracle_;
        risk = risk_;
        usdg_.forceApprove(address(pool_), type(uint256).max);
    }

    /// @notice One-time wiring of the permissionless keeper entrypoints.
    function setPeriphery(address harvester_, address liquidator_) external onlyOwner {
        if (harvester != address(0)) revert AlreadySet();
        if (harvester_ == address(0) || liquidator_ == address(0)) revert ZeroAddress();
        harvester = harvester_;
        liquidator = liquidator_;
        emit PeripherySet(harvester_, liquidator_);
    }

    // =========================================================================================================
    // Borrower actions
    // =========================================================================================================

    function openTab(address adapter) external nonReentrant whenNotPaused(PAUSE_OPEN) returns (uint256 tabId) {
        if (risk.collateral(adapter).status != YieldRiskConfig.Status.Active) revert InvalidStatus();
        if (tabIdOf[msg.sender][adapter] != 0) revert TabExists();
        tabId = nextTabId++;
        _tabs[tabId] = Tab({
            owner: msg.sender,
            adapter: adapter,
            open: true,
            openedAt: uint64(block.timestamp),
            scaledDebt: 0,
            principal: 0,
            yieldRepaid: 0,
            totalRepaid: 0
        });
        tabIdOf[msg.sender][adapter] = tabId;
        emit TabOpened(tabId, msg.sender, adapter);
    }

    /// @notice Add collateral (anyone may top up any open tab). Not pausable.
    function addCollateral(uint256 tabId, uint256 amount) external nonReentrant {
        Tab storage t = _open(tabId);
        if (amount == 0) revert ZeroAmount();
        YieldRiskConfig.CollateralParams memory p = risk.collateral(t.adapter);
        if (p.status == YieldRiskConfig.Status.Disabled) revert InvalidStatus();
        ICollateralAdapter a = ICollateralAdapter(t.adapter);
        if (a.valueOfAmount(a.totalBalance() + amount, VIEW) > p.supplyCap) revert SupplyCapExceeded();
        a.deposit(tabId, msg.sender, amount);
        emit CollateralAdded(tabId, msg.sender, amount);
    }

    function borrow(uint256 tabId, uint256 amount) external nonReentrant whenNotPaused(PAUSE_BORROW) {
        Tab storage t = _open(tabId);
        if (msg.sender != t.owner) revert NotOwner();
        if (amount == 0) revert ZeroAmount();
        YieldRiskConfig.CollateralParams memory p = risk.collateral(t.adapter);
        if (p.status != YieldRiskConfig.Status.Active) revert InvalidStatus();
        ICollateralAdapter a = ICollateralAdapter(t.adapter);
        if (!a.canBorrow()) revert MaturityTooClose();
        uint256 ltv = _effectiveLtv(a, p);
        if (ltv == 0) revert BorrowFrozen();
        if (principalByAdapter[t.adapter] + amount > p.borrowCap) revert BorrowCapExceeded();

        _pool.accrue();
        uint256 idx = _pool.indexOf(address(this));
        uint256 scaled = amount.toScaledUp(idx);
        uint256 newDebt = (t.scaledDebt + scaled).toAssetsUp(idx);
        if (newDebt < risk.global().minDebt) revert BelowMinDebt();
        if (newDebt * 10_000 > a.valueInUSDG(tabId, BORROW) * ltv) revert InsufficientCollateral();

        t.scaledDebt += scaled;
        t.principal += amount;
        principalByAdapter[t.adapter] += amount;
        _totalScaledDebt += scaled;
        if (_pool.draw(amount, msg.sender) != scaled) revert ScaledMismatch();
        emit Borrowed(tabId, amount, scaled);
    }

    function repay(uint256 tabId, uint256 amount) external nonReentrant returns (uint256 paid) {
        Tab storage t = _tabs[tabId];
        if (t.owner == address(0)) revert TabNotOpen();
        if (amount == 0) revert ZeroAmount();
        paid = _applyPayment(tabId, t, amount, msg.sender);
    }

    function withdrawCollateral(uint256 tabId, uint256 amount) external nonReentrant whenNotPaused(PAUSE_WITHDRAW) {
        Tab storage t = _open(tabId);
        if (msg.sender != t.owner) revert NotOwner();
        if (amount == 0) revert ZeroAmount();
        ICollateralAdapter a = ICollateralAdapter(t.adapter);
        uint256 bal = a.balanceOf(tabId);
        if (amount > bal) revert InsufficientCollateral();
        if (t.scaledDebt > 0) {
            _pool.accrue();
            uint256 debt = t.scaledDebt.toAssetsUp(_pool.indexOf(address(this)));
            uint256 ltv = _effectiveLtv(a, risk.collateral(t.adapter));
            uint256 valueAfter = a.valueOfAmount(bal - amount, BORROW);
            if (debt * 10_000 > valueAfter * ltv) revert InsufficientCollateral();
        }
        a.withdraw(tabId, t.owner, amount);
        emit CollateralWithdrawn(tabId, amount);
    }

    function closeTab(uint256 tabId) external nonReentrant {
        Tab storage t = _open(tabId);
        if (msg.sender != t.owner) revert NotOwner();
        if (t.scaledDebt != 0) revert HasDebt();
        if (ICollateralAdapter(t.adapter).balanceOf(tabId) != 0) revert HasCollateral();
        t.open = false;
        tabIdOf[t.owner][t.adapter] = 0;
        emit TabClosed(tabId);
    }

    function claimCredit() external nonReentrant returns (uint256 amount) {
        amount = ownerCredit[msg.sender];
        if (amount == 0) revert ZeroAmount();
        ownerCredit[msg.sender] = 0;
        usdg.safeTransfer(msg.sender, amount);
        emit CreditClaimed(msg.sender, amount);
    }

    // =========================================================================================================
    // Keeper entrypoints (via YieldHarvester / Liquidator)
    // =========================================================================================================

    function harvestFor(uint256 tabId, address keeper)
        external
        nonReentrant
        returns (uint256 yield_, uint256 reward, uint256 repaid, uint256 credited)
    {
        if (msg.sender != harvester) revert NotHarvester();
        Tab storage t = _tabs[tabId];
        if (t.owner == address(0)) revert TabNotOpen();
        yield_ = ICollateralAdapter(t.adapter).harvest(tabId, address(this));
        YieldRiskConfig.GlobalParams memory g = risk.global();
        if (yield_ == 0 || yield_ < g.minHarvest) revert BelowMinHarvest();
        reward = Math.min(yield_.bps(g.harvestRewardBps), g.maxHarvestReward);
        if (reward > 0) usdg.safeTransfer(keeper, reward);
        uint256 rest = yield_ - reward;
        repaid = _applyPayment(tabId, t, rest, address(this));
        t.yieldRepaid += repaid;
        credited = rest - repaid;
        if (credited > 0) ownerCredit[t.owner] += credited;
        emit Harvested(tabId, keeper, yield_, reward, repaid, credited);
    }

    struct LiqPlan {
        uint256 toRepay;
        uint256 seizeAmt;
    }

    function liquidateFor(uint256 tabId, address liq, uint256 repayAmount)
        external
        nonReentrant
        returns (uint256 repaid, uint256 seized, uint256 badDebt)
    {
        if (msg.sender != liquidator) revert NotLiquidator();
        Tab storage t = _tabs[tabId];
        if (t.scaledDebt == 0) revert Healthy();
        if (repayAmount == 0) revert ZeroAmount();
        _pool.accrue();
        LiqPlan memory plan = _liquidationPlan(tabId, t, repayAmount);
        ICollateralAdapter a = ICollateralAdapter(t.adapter);
        repaid = plan.toRepay > 0 ? _applyPayment(tabId, t, plan.toRepay, liq) : 0;
        seized = plan.seizeAmt;
        if (seized > 0) a.seize(tabId, liq, seized);

        if (a.balanceOf(tabId) == 0 && t.scaledDebt > 0) {
            uint256 s = t.scaledDebt;
            t.scaledDebt = 0;
            _totalScaledDebt -= s;
            _reducePrincipal(t, t.principal);
            badDebt = _pool.writeOff(s);
        }
        emit Liquidated(tabId, liq, repaid, seized, badDebt);
    }

    function _liquidationPlan(uint256 tabId, Tab storage t, uint256 repayAmount)
        internal
        view
        returns (LiqPlan memory plan)
    {
        ICollateralAdapter a = ICollateralAdapter(t.adapter);
        YieldRiskConfig.CollateralParams memory p = risk.collateral(t.adapter);
        YieldRiskConfig.GlobalParams memory g = risk.global();
        uint256 debt = t.scaledDebt.toAssetsUp(_pool.indexOf(address(this)));
        uint256 hf = Math.mulDiv(a.valueInUSDG(tabId, LIQ) * p.liqThresholdBps, 1e18, debt * 10_000);
        if (hf >= 1e18) revert Healthy();
        bool full = hf < g.fullLiquidationHfWad || debt <= g.dustDebt;
        plan.toRepay = Math.min(repayAmount, full ? debt : debt.bps(g.closeFactorBps));
        uint256 bal = a.balanceOf(tabId);
        plan.seizeAmt = a.amountForValue(plan.toRepay.bps(10_000 + p.liqBonusBps), LIQ);
        if (plan.seizeAmt >= bal) {
            plan.seizeAmt = bal;
            // liquidator only pays for what can actually be seized
            plan.toRepay =
                Math.min(plan.toRepay, Math.mulDiv(a.valueOfAmount(bal, LIQ), 10_000, 10_000 + p.liqBonusBps));
        }
    }

    // =========================================================================================================
    // Internals
    // =========================================================================================================

    function _open(uint256 tabId) internal view returns (Tab storage t) {
        t = _tabs[tabId];
        if (!t.open) revert TabNotOpen();
    }

    function _effectiveLtv(ICollateralAdapter a, YieldRiskConfig.CollateralParams memory p)
        internal
        view
        returns (uint256)
    {
        if (a.isEquityLinked() && !oracle.isMarketOpen(a.asset())) return p.closedMarketLtvBps;
        return p.maxLtvBps;
    }

    function _reducePrincipal(Tab storage t, uint256 amount) internal {
        t.principal -= amount;
        uint256 cur = principalByAdapter[t.adapter];
        principalByAdapter[t.adapter] = amount > cur ? 0 : cur - amount;
    }

    function _applyPayment(uint256 tabId, Tab storage t, uint256 maxAmount, address from)
        internal
        returns (uint256 paid)
    {
        if (t.scaledDebt == 0 || maxAmount == 0) return 0;
        _pool.accrue();
        uint256 idx = _pool.indexOf(address(this));
        uint256 scaled = t.scaledDebt;
        uint256 debt = scaled.toAssetsUp(idx);
        uint256 burn;
        if (maxAmount >= debt) {
            burn = scaled;
            paid = debt;
        } else {
            burn = maxAmount.toScaledDown(idx);
            if (burn == 0) return 0;
            paid = burn.toAssetsUp(idx);
        }
        uint256 interest = debt > t.principal ? debt - t.principal : 0;
        uint256 interestPaid = Math.min(paid, interest);
        uint256 principalPaid = burn == scaled ? t.principal : Math.min(paid - interestPaid, t.principal);

        t.scaledDebt = scaled - burn;
        _totalScaledDebt -= burn;
        _reducePrincipal(t, principalPaid);
        t.totalRepaid += paid;

        if (from != address(this)) usdg.safeTransferFrom(from, address(this), paid);
        _pool.repay(burn);
        emit Repaid(tabId, from, paid, interestPaid, principalPaid);
    }

    // =========================================================================================================
    // Views
    // =========================================================================================================

    function pool() external view returns (address) {
        return address(_pool);
    }

    function totalScaledDebt() external view returns (uint256) {
        return _totalScaledDebt;
    }

    function creditLineKind() external pure returns (bytes32) {
        return KIND;
    }

    function tabOf(uint256 tabId) external view returns (Tab memory) {
        return _tabs[tabId];
    }

    function debtOf(uint256 tabId) public view returns (uint256) {
        return _tabs[tabId].scaledDebt.toAssetsUp(_pool.indexOf(address(this)));
    }

    function effectiveLtvBps(uint256 tabId) public view returns (uint256) {
        address adapter = _tabs[tabId].adapter;
        return _effectiveLtv(ICollateralAdapter(adapter), risk.collateral(adapter));
    }

    /// @notice Health factor (WAD) with VIEW pricing. type(uint256).max when there is no debt.
    function healthFactor(uint256 tabId) external view returns (uint256) {
        Tab storage t = _tabs[tabId];
        uint256 debt = debtOf(tabId);
        if (debt == 0) return type(uint256).max;
        uint256 value = ICollateralAdapter(t.adapter).valueInUSDG(tabId, VIEW);
        return Math.mulDiv(value * risk.collateral(t.adapter).liqThresholdBps, 1e18, debt * 10_000);
    }

    /// @notice Additional USDG the owner could borrow now (VIEW pricing, ignores caps' remaining room except borrow cap).
    function maxBorrow(uint256 tabId) external view returns (uint256) {
        Tab storage t = _tabs[tabId];
        if (!t.open) return 0;
        uint256 value = ICollateralAdapter(t.adapter).valueInUSDG(tabId, VIEW);
        uint256 cap = value * effectiveLtvBps(tabId) / 10_000;
        uint256 debt = debtOf(tabId);
        if (cap <= debt + 1) return 0;
        YieldRiskConfig.CollateralParams memory p = risk.collateral(t.adapter);
        uint256 room = p.borrowCap > principalByAdapter[t.adapter] ? p.borrowCap - principalByAdapter[t.adapter] : 0;
        return Math.min(cap - debt - 1, room);
    }
}
