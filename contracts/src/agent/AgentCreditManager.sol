// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {TabbAccessControl} from "../access/TabbAccessControl.sol";
import {TabbMath} from "../libraries/TabbMath.sol";
import {ITabbPool} from "../interfaces/ITabbPool.sol";
import {ICreditLine} from "../interfaces/ICreditLine.sol";
import {IAgentRegistry} from "../interfaces/IAgentRegistry.sol";
import {IAgentRiskConfig} from "../interfaces/IAgentRiskConfig.sol";
import {IAgentCreditScore} from "../interfaces/IAgentCreditScore.sol";
import {IOwnerStakeVault} from "../interfaces/IOwnerStakeVault.sol";
import {IPayeeRegistry} from "../interfaces/IPayeeRegistry.sol";
import {IAgentCreditManager} from "../interfaces/IAgentCreditManager.sol";
import {IPolicyAccount} from "../interfaces/IPolicyAccount.sol";
import {IRepaymentSplitter} from "../interfaces/IRepaymentSplitter.sol";
import {PolicyAccount} from "./PolicyAccount.sol";
import {RepaymentSplitter} from "./RepaymentSplitter.sol";

/// @title AgentCreditManager
/// @notice Phase 1 credit line: reputation/stake-based tabs for ERC-8004 agents.
///         - One tab per agentId; the agent owner at open time is the borrower of record.
///         - Draws go to the agent's PolicyAccount (curated spending only), never to a free wallet.
///         - Revenue flows through the agent's RepaymentSplitter, which repays `splitBps` of it automatically.
///         - Minimum payment per period; missing it leads to Delinquent -> Defaulted with a deterministic recovery
///           waterfall: PolicyAccount balance, splitter balance, owner stake, then pool write-off.
contract AgentCreditManager is ICreditLine, IAgentCreditManager, TabbAccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using TabbMath for uint256;

    uint256 public constant PAUSE_OPEN = 1 << 0;
    uint256 public constant PAUSE_DRAW = 1 << 1;
    bytes32 public constant KIND = keccak256("TABB_AGENT_CREDIT_V1");
    uint256 internal constant MAX_PERIOD_ROLLS = 12;

    enum Status {
        None,
        Active,
        Delinquent,
        Defaulted,
        Closed
    }

    struct AgentTab {
        address owner; // borrower of record
        address policyAccount;
        address splitter;
        address payout;
        Status status;
        uint16 splitBps;
        bool cycleDirty;
        uint64 openedAt;
        uint64 periodStart; // 0 when no debt
        uint64 delinquentSince;
        uint64 zeroDebtAt; // last time debt went to zero (stake cooldown)
        uint64 cycleStart;
        uint256 scaledDebt;
        uint256 principal;
        uint256 periodBase; // debt at period start; min payment = periodBase * minPaymentBps
        uint256 paidThisPeriod;
        uint256 cyclePeak;
        uint256 totalRepaid;
        uint256 revenueRepaid; // repaid out of splitter revenue ("your yield pays it back")
        uint256 lossWrittenOff;
        uint256 recovered;
    }

    struct PaymentStatus {
        uint256 debt;
        uint256 periodEnd;
        uint256 minPaymentDue;
        uint256 paidThisPeriod;
        bool pastDue;
        uint256 delinquentEligibleAt;
        uint256 defaultEligibleAt;
    }

    IERC20 public immutable usdg;
    ITabbPool internal immutable _pool;
    IAgentRegistry public immutable registry;
    IAgentRiskConfig public immutable config;
    IAgentCreditScore public immutable score;
    IOwnerStakeVault public immutable vault;
    IPayeeRegistry public immutable payees;
    address public immutable policyAccountImpl;
    address public immutable splitterImpl;

    mapping(uint256 => AgentTab) internal _tabs;
    uint256[] public agentIds;
    mapping(address => uint256) public ownerPrincipal;
    mapping(uint256 => bool) public blacklistedAgent;
    mapping(address => bool) public blacklistedOwner;
    uint256 internal _totalScaledDebt;

    event TabOpened(uint256 indexed agentId, address indexed owner, address policyAccount, address splitter);
    event Drawn(uint256 indexed agentId, uint256 amount, uint256 scaled);
    event Repaid(uint256 indexed agentId, address indexed from, uint256 amount, uint256 interest, uint256 principal);
    event RevenueProcessed(uint256 indexed agentId, uint256 revenue, uint256 fee, uint256 repaid);
    event Recovery(uint256 indexed agentId, uint256 amount);
    event CycleClosed(uint256 indexed agentId, bool qualified);
    event MarkedDelinquent(uint256 indexed agentId, address indexed by);
    event Cured(uint256 indexed agentId);
    event MarkedDefault(
        uint256 indexed agentId, address indexed by, uint256 recoveredFunds, uint256 slashed, uint256 writtenOff
    );
    event TabClosed(uint256 indexed agentId);
    event PayoutSet(uint256 indexed agentId, address payout);
    event SplitSet(uint256 indexed agentId, uint16 splitBps);
    event OperatorSet(uint256 indexed agentId, address operator);

    error NotAgentOwner();
    error OwnerChanged();
    error Blacklisted();
    error NotAllowed();
    error TabExists();
    error InvalidStatus();
    error InsufficientStake();
    error LimitExceeded();
    error OwnerCapExceeded();
    error BelowMinDebt();
    error PastDue();
    error NotPastDue();
    error TooEarly();
    error HasDebt();
    error NotSplitter();
    error InvalidSplit();
    error ScaledMismatch();
    error ZeroAmount();

    struct Deps {
        IERC20 usdg;
        ITabbPool pool;
        IAgentRegistry registry;
        IAgentRiskConfig config;
        IAgentCreditScore score;
        IOwnerStakeVault vault;
        IPayeeRegistry payees;
        address policyAccountImpl;
        address splitterImpl;
    }

    constructor(Deps memory d, address owner_, address guardian_) TabbAccessControl(owner_, guardian_) {
        if (
            address(d.usdg) == address(0) || address(d.pool) == address(0) || address(d.registry) == address(0)
                || address(d.config) == address(0) || address(d.score) == address(0) || address(d.vault) == address(0)
                || address(d.payees) == address(0) || d.policyAccountImpl == address(0) || d.splitterImpl == address(0)
        ) revert ZeroAddress();
        usdg = d.usdg;
        _pool = d.pool;
        registry = d.registry;
        config = d.config;
        score = d.score;
        vault = d.vault;
        payees = d.payees;
        policyAccountImpl = d.policyAccountImpl;
        splitterImpl = d.splitterImpl;
        d.usdg.forceApprove(address(d.pool), type(uint256).max);
    }

    // =========================================================================================================
    // Owner (borrower) actions
    // =========================================================================================================

    /// @notice Open (or reopen) a tab for an ERC-8004 agent you own. Requires stake >= minStake in the vault.
    function openTab(uint256 agentId, address operator, address payout)
        external
        nonReentrant
        whenNotPaused(PAUSE_OPEN)
    {
        if (registry.ownerOf(agentId) != msg.sender) revert NotAgentOwner();
        if (blacklistedAgent[agentId] || blacklistedOwner[msg.sender]) revert Blacklisted();
        if (!config.isOwnerAllowed(msg.sender)) revert NotAllowed();
        AgentTab storage t = _tabs[agentId];
        if (t.status != Status.None && t.status != Status.Closed) revert TabExists();
        IAgentRiskConfig.Params memory p = config.params();
        if (vault.stakeOf(agentId, msg.sender) < p.minStake) revert InsufficientStake();

        if (t.policyAccount == address(0)) {
            address pa = Clones.clone(policyAccountImpl);
            PolicyAccount(payable(pa)).initialize(address(this), payees, usdg, agentId, operator);
            address sp = Clones.clone(splitterImpl);
            RepaymentSplitter(sp).initialize(this, usdg, agentId);
            t.policyAccount = pa;
            t.splitter = sp;
            agentIds.push(agentId);
        } else {
            IPolicyAccount(t.policyAccount).setOperator(operator);
        }
        t.owner = msg.sender;
        t.payout = payout == address(0) ? msg.sender : payout;
        t.status = Status.Active;
        t.splitBps = p.defaultSplitBps;
        t.openedAt = uint64(block.timestamp);
        score.onFirstSeen(agentId);
        emit TabOpened(agentId, msg.sender, t.policyAccount, t.splitter);
    }

    /// @notice Borrow `amount` USDG into the agent's PolicyAccount.
    function draw(uint256 agentId, uint256 amount) external nonReentrant whenNotPaused(PAUSE_DRAW) {
        AgentTab storage t = _tabs[agentId];
        if (msg.sender != t.owner) revert NotAgentOwner();
        if (t.status != Status.Active) revert InvalidStatus();
        if (registry.ownerOf(agentId) != t.owner) revert OwnerChanged();
        if (blacklistedOwner[t.owner]) revert Blacklisted();
        if (amount == 0) revert ZeroAmount();

        _pool.accrue();
        uint256 idx = _pool.indexOf(address(this));
        _syncPeriod(t, t.scaledDebt.toAssetsUp(idx));
        if (_isPastDue(t)) revert PastDue();

        IAgentRiskConfig.Params memory p = config.params();
        uint256 scaled = amount.toScaledUp(idx);
        // exact post-draw debt (includes rounding) must fit the limit
        uint256 newDebt = (t.scaledDebt + scaled).toAssetsUp(idx);
        if (newDebt > score.creditLimit(agentId, t.owner)) revert LimitExceeded();
        if (newDebt < p.minDebt) revert BelowMinDebt();
        if (ownerPrincipal[t.owner] + amount > p.maxPerOwner) revert OwnerCapExceeded();

        if (t.scaledDebt == 0) {
            t.cycleStart = uint64(block.timestamp);
            t.cyclePeak = 0;
            t.cycleDirty = false;
            t.periodStart = uint64(block.timestamp);
            t.periodBase = 0;
            t.paidThisPeriod = 0;
        }
        t.scaledDebt += scaled;
        t.principal += amount;
        ownerPrincipal[t.owner] += amount;
        _totalScaledDebt += scaled;
        if (t.periodBase == 0) t.periodBase = newDebt;
        if (newDebt > t.cyclePeak) t.cyclePeak = newDebt;

        if (_pool.draw(amount, t.policyAccount) != scaled) revert ScaledMismatch();
        emit Drawn(agentId, amount, scaled);
    }

    /// @notice Repay on behalf of any agent. Pulls at most `amount` (never more than the debt).
    function repay(uint256 agentId, uint256 amount) external nonReentrant returns (uint256 paid) {
        AgentTab storage t = _tabs[agentId];
        if (t.status != Status.Active && t.status != Status.Delinquent) revert InvalidStatus();
        if (amount == 0) revert ZeroAmount();
        paid = _applyPayment(agentId, t, amount, msg.sender);
    }

    /// @notice Return unspent funds from the PolicyAccount to the pool (owner or operator).
    function repayFromPolicyAccount(uint256 agentId, uint256 amount) external nonReentrant returns (uint256 paid) {
        AgentTab storage t = _tabs[agentId];
        if (msg.sender != t.owner && msg.sender != IPolicyAccount(t.policyAccount).operator()) revert NotAgentOwner();
        if (t.status != Status.Active && t.status != Status.Delinquent) revert InvalidStatus();
        uint256 swept = IPolicyAccount(t.policyAccount).sweep(address(this), amount);
        paid = _applyPayment(agentId, t, swept, address(this));
        if (swept > paid) usdg.safeTransfer(t.policyAccount, swept - paid);
    }

    function closeTab(uint256 agentId) external nonReentrant {
        AgentTab storage t = _tabs[agentId];
        if (msg.sender != t.owner) revert NotAgentOwner();
        if (t.status != Status.Active) revert InvalidStatus();
        if (t.scaledDebt != 0) revert HasDebt();
        t.status = Status.Closed;
        IPolicyAccount(t.policyAccount).sweep(t.owner, type(uint256).max);
        emit TabClosed(agentId);
    }

    function setOperator(uint256 agentId, address operator) external {
        AgentTab storage t = _tabs[agentId];
        if (msg.sender != t.owner) revert NotAgentOwner();
        IPolicyAccount(t.policyAccount).setOperator(operator);
        emit OperatorSet(agentId, operator);
    }

    function setPayout(uint256 agentId, address payout) external {
        AgentTab storage t = _tabs[agentId];
        if (msg.sender != t.owner) revert NotAgentOwner();
        if (payout == address(0)) revert ZeroAddress();
        t.payout = payout;
        emit PayoutSet(agentId, payout);
    }

    function setSplitBps(uint256 agentId, uint16 splitBps) external {
        AgentTab storage t = _tabs[agentId];
        if (msg.sender != t.owner) revert NotAgentOwner();
        if (splitBps < config.params().minSplitBps || splitBps > 10_000) revert InvalidSplit();
        t.splitBps = splitBps;
        emit SplitSet(agentId, splitBps);
    }

    // =========================================================================================================
    // Splitter
    // =========================================================================================================

    /// @inheritdoc IAgentCreditManager
    function processRevenue(uint256 agentId, uint256 amount) external nonReentrant returns (address) {
        AgentTab storage t = _tabs[agentId];
        if (msg.sender != t.splitter || t.splitter == address(0)) revert NotSplitter();

        if (t.status == Status.Defaulted) {
            uint256 need = t.lossWrittenOff > t.recovered ? t.lossWrittenOff - t.recovered : 0;
            uint256 take = Math.min(amount, need);
            if (take > 0) {
                t.recovered += take;
                // donation to the pool restores lender assets (cash-based accounting)
                usdg.safeTransferFrom(msg.sender, address(_pool), take);
                emit Recovery(agentId, take);
            }
            return t.payout;
        }

        IAgentRiskConfig.Params memory p = config.params();
        uint256 fee;
        address feeTo = config.feeRecipient();
        if (p.distributeFeeBps > 0 && feeTo != address(0)) {
            fee = amount.bps(p.distributeFeeBps);
            if (fee > 0) usdg.safeTransferFrom(msg.sender, feeTo, fee);
        }
        score.recordRevenue(agentId, amount);

        uint256 paid;
        if (t.scaledDebt > 0 && (t.status == Status.Active || t.status == Status.Delinquent)) {
            uint256 splitBps = t.status == Status.Delinquent ? 10_000 : Math.max(t.splitBps, p.minSplitBps);
            uint256 toRepay = (amount - fee).bps(splitBps);
            if (toRepay > 0) paid = _applyPayment(agentId, t, toRepay, msg.sender);
            t.revenueRepaid += paid;
        }
        emit RevenueProcessed(agentId, amount, fee, paid);
        return t.payout;
    }

    // =========================================================================================================
    // Keeper actions (permissionless)
    // =========================================================================================================

    function markDelinquent(uint256 agentId) external nonReentrant {
        AgentTab storage t = _tabs[agentId];
        if (t.status != Status.Active) revert InvalidStatus();
        _pool.accrue();
        _syncPeriod(t, t.scaledDebt.toAssetsUp(_pool.indexOf(address(this))));
        if (!_isPastDue(t)) revert NotPastDue();
        if (block.timestamp < _periodEnd(t) + config.params().gracePeriod) revert TooEarly();
        t.status = Status.Delinquent;
        t.delinquentSince = uint64(block.timestamp);
        t.cycleDirty = true;
        score.onDelinquent(agentId);
        emit MarkedDelinquent(agentId, msg.sender);
    }

    /// @notice Default a tab that has been delinquent for `defaultDelay`, running the recovery waterfall.
    function markDefault(uint256 agentId) external nonReentrant {
        AgentTab storage t = _tabs[agentId];
        if (t.status != Status.Delinquent) revert InvalidStatus();
        if (block.timestamp < uint256(t.delinquentSince) + config.params().defaultDelay) revert TooEarly();

        address owner_ = t.owner;
        t.status = Status.Defaulted;
        blacklistedAgent[agentId] = true;
        blacklistedOwner[owner_] = true;

        // 1+2: unspent PolicyAccount funds and undistributed splitter revenue
        uint256 funds = IPolicyAccount(t.policyAccount).sweep(address(this), type(uint256).max);
        funds += IRepaymentSplitter(t.splitter).sweep(address(this));
        uint256 paid = funds > 0 ? _applyPayment(agentId, t, funds, address(this)) : 0;
        if (funds > paid) usdg.safeTransfer(owner_, funds - paid);

        // 3: slash the borrower-of-record's stake
        uint256 slashed;
        if (t.scaledDebt > 0) {
            uint256 debt = t.scaledDebt.toAssetsUp(_pool.indexOf(address(this)));
            slashed = vault.slash(agentId, owner_, debt, address(this));
            uint256 paid2 = slashed > 0 ? _applyPayment(agentId, t, slashed, address(this)) : 0;
            if (slashed > paid2) usdg.safeTransfer(owner_, slashed - paid2);
        }

        // 4: write off the remainder (absorber -> treasury shares -> lenders)
        uint256 loss;
        if (t.scaledDebt > 0) {
            uint256 s = t.scaledDebt;
            t.scaledDebt = 0;
            _totalScaledDebt -= s;
            _reduceOwnerPrincipal(owner_, t.principal);
            t.principal = 0;
            t.periodStart = 0;
            loss = _pool.writeOff(s);
            t.lossWrittenOff = loss;
        }
        score.onDefault(agentId);
        emit MarkedDefault(agentId, msg.sender, funds, slashed, loss);
    }

    // =========================================================================================================
    // Internals
    // =========================================================================================================

    function _applyPayment(uint256 agentId, AgentTab storage t, uint256 maxAmount, address from)
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

        // effects
        t.scaledDebt = scaled - burn;
        _totalScaledDebt -= burn;
        t.principal -= principalPaid;
        _reduceOwnerPrincipal(t.owner, principalPaid);
        t.paidThisPeriod += paid;
        t.totalRepaid += paid;

        // interactions
        if (from != address(this)) usdg.safeTransferFrom(from, address(this), paid);
        _pool.repay(burn);
        emit Repaid(agentId, from, paid, interestPaid, principalPaid);

        if (t.scaledDebt == 0) {
            _onDebtCleared(agentId, t);
        } else {
            _syncPeriod(t, t.scaledDebt.toAssetsUp(idx));
            if (t.status == Status.Delinquent && !_isPastDue(t)) {
                t.status = Status.Active;
                t.delinquentSince = 0;
                emit Cured(agentId);
            }
        }
    }

    function _onDebtCleared(uint256 agentId, AgentTab storage t) internal {
        IAgentRiskConfig.Params memory p = config.params();
        bool qualified = !t.cycleDirty && block.timestamp - t.cycleStart >= p.minCycleDuration
            && t.cyclePeak >= p.minCyclePeak;
        t.principal = 0;
        t.zeroDebtAt = uint64(block.timestamp);
        t.periodStart = 0;
        t.periodBase = 0;
        t.paidThisPeriod = 0;
        if (t.status == Status.Delinquent) {
            t.status = Status.Active;
            t.delinquentSince = 0;
            emit Cured(agentId);
        }
        if (t.status == Status.Active) {
            score.onCycleCompleted(agentId, qualified);
            emit CycleClosed(agentId, qualified);
        }
    }

    function _reduceOwnerPrincipal(address owner_, uint256 amount) internal {
        uint256 cur = ownerPrincipal[owner_];
        ownerPrincipal[owner_] = amount > cur ? 0 : cur - amount;
    }

    function _periodEnd(AgentTab storage t) internal view returns (uint256) {
        return uint256(t.periodStart) + config.params().paymentPeriod;
    }

    function _minDue(AgentTab storage t) internal view returns (uint256) {
        return t.periodBase.bps(config.params().minPaymentBps);
    }

    function _isPastDue(AgentTab storage t) internal view returns (bool) {
        return t.periodStart != 0 && block.timestamp >= _periodEnd(t) && t.paidThisPeriod < _minDue(t);
    }

    /// @dev Rolls satisfied periods forward. An unsatisfied, elapsed period stays put (past due) until paid.
    function _syncPeriod(AgentTab storage t, uint256 debt) internal {
        if (t.periodStart == 0) return;
        uint256 period = config.params().paymentPeriod;
        for (uint256 i; i < MAX_PERIOD_ROLLS; ++i) {
            if (block.timestamp < uint256(t.periodStart) + period) return;
            if (t.paidThisPeriod < _minDue(t)) return;
            t.periodStart += uint64(period);
            t.periodBase = debt;
            t.paidThisPeriod = 0;
        }
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

    function tabOf(uint256 agentId) external view returns (AgentTab memory) {
        return _tabs[agentId];
    }

    function agentCount() external view returns (uint256) {
        return agentIds.length;
    }

    function debtOf(uint256 agentId) public view returns (uint256) {
        return _tabs[agentId].scaledDebt.toAssetsUp(_pool.indexOf(address(this)));
    }

    function creditLimitOf(uint256 agentId) public view returns (uint256) {
        AgentTab storage t = _tabs[agentId];
        if (t.owner == address(0)) return 0;
        return score.creditLimit(agentId, t.owner);
    }

    /// @notice How much the owner can draw right now (limit, owner cap and pool liquidity).
    function availableCredit(uint256 agentId) external view returns (uint256) {
        AgentTab storage t = _tabs[agentId];
        if (t.status != Status.Active) return 0;
        uint256 idx = _pool.indexOf(address(this));
        uint256 debt = t.scaledDebt.toAssetsUp(idx);
        uint256 lim = creditLimitOf(agentId);
        if (debt >= lim) return 0;
        uint256 avail = lim - debt;
        // account for scaled rounding so that draw(availableCredit) always succeeds
        for (uint256 i; i < 3 && avail > 0; ++i) {
            if ((t.scaledDebt + avail.toScaledUp(idx)).toAssetsUp(idx) <= lim) break;
            avail -= 1;
        }
        uint256 maxOwner = config.params().maxPerOwner;
        uint256 op = ownerPrincipal[t.owner];
        avail = Math.min(avail, op >= maxOwner ? 0 : maxOwner - op);
        return Math.min(avail, _pool.availableLiquidity());
    }

    function paymentStatus(uint256 agentId) external view returns (PaymentStatus memory s) {
        AgentTab storage t = _tabs[agentId];
        IAgentRiskConfig.Params memory p = config.params();
        s.debt = debtOf(agentId);
        if (t.periodStart == 0) return s;
        // simulate lazy roll-forward of satisfied periods
        uint256 start = t.periodStart;
        uint256 base = t.periodBase;
        uint256 paidP = t.paidThisPeriod;
        for (uint256 i; i < MAX_PERIOD_ROLLS; ++i) {
            if (block.timestamp < start + p.paymentPeriod || paidP < base.bps(p.minPaymentBps)) break;
            start += p.paymentPeriod;
            base = s.debt;
            paidP = 0;
        }
        s.periodEnd = start + p.paymentPeriod;
        s.minPaymentDue = base.bps(p.minPaymentBps);
        s.paidThisPeriod = paidP;
        s.pastDue = block.timestamp >= s.periodEnd && paidP < s.minPaymentDue;
        s.delinquentEligibleAt = s.periodEnd + p.gracePeriod;
        if (t.status == Status.Delinquent) s.defaultEligibleAt = uint256(t.delinquentSince) + p.defaultDelay;
    }

    /// @inheritdoc IAgentCreditManager
    function stakeLocked(uint256 agentId, address staker) external view returns (bool) {
        AgentTab storage t = _tabs[agentId];
        if (staker != t.owner) return false;
        if (t.status == Status.Defaulted) return false;
        if (t.scaledDebt > 0) return true;
        return t.zeroDebtAt != 0 && block.timestamp < uint256(t.zeroDebtAt) + config.params().stakeCooldown;
    }

    /// @inheritdoc IAgentCreditManager
    function canSpend(uint256 agentId) external view returns (bool) {
        AgentTab storage t = _tabs[agentId];
        return t.status == Status.Active && !payees.spendingPaused() && registry.ownerOf(agentId) == t.owner;
    }

    /// @inheritdoc IAgentCreditManager
    function dailySpendCap(uint256 agentId) external view returns (uint256) {
        AgentTab storage t = _tabs[agentId];
        uint256 base = Math.max(creditLimitOf(agentId), t.principal);
        return base.bps(config.params().dailySpendCapBps);
    }

    /// @inheritdoc IAgentCreditManager
    function payoutOf(uint256 agentId) external view returns (address) {
        return _tabs[agentId].payout;
    }
}
