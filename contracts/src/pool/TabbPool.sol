// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {TabbAccessControl} from "../access/TabbAccessControl.sol";
import {TabbMath} from "../libraries/TabbMath.sol";
import {IInterestRateModel} from "../interfaces/IInterestRateModel.sol";
import {ILossAbsorber} from "../interfaces/ILossAbsorber.sol";
import {ITabbPool} from "../interfaces/ITabbPool.sol";

/// @title TabbPool
/// @notice ERC-4626 USDG lending pool. Lenders deposit the asset; whitelisted credit lines (AgentCreditManager,
///         later TabManager) borrow from it. Each credit line has its own interest index so it can pay a risk
///         spread on top of the utilization-based base rate.
/// @dev totalAssets = cash + totalDebt. The protocol's cut of interest (reserve factor) is minted as pool shares to
///      the treasury (Aave-style), so reserves always share pool risk and `totalDebt <= totalAssets` holds by
///      construction. On bad debt, treasury shares are burned first (insurance layer). Inflation attack mitigated
///      with a 6-decimal virtual offset (plus a seed deposit at deploy time). Withdrawals are capped by idle cash.
contract TabbPool is ERC4626, TabbAccessControl, ReentrancyGuard, ITabbPool {
    using SafeERC20 for IERC20;
    using TabbMath for uint256;

    uint256 public constant PAUSE_DEPOSIT = 1 << 0;
    uint256 public constant PAUSE_WITHDRAW = 1 << 1;
    uint256 public constant PAUSE_DRAW = 1 << 2;

    uint256 public constant MAX_LINES = 8;
    uint256 public constant MAX_RESERVE_FACTOR_BPS = 5_000;
    uint256 public constant MAX_SPREAD_BPS = 5_000;

    struct CreditLine {
        bool registered;
        bool active;
        uint256 cap; // max debt (assets)
        uint256 spreadBps; // annual spread over base rate
        uint256 index; // RAY
        uint256 scaledDebt;
    }

    mapping(address => CreditLine) internal _lines;
    address[] public lineList;

    IInterestRateModel public interestRateModel;
    ILossAbsorber public lossAbsorber;
    address public treasury;
    uint256 public reserveFactorBps;
    uint256 public lastAccrual;

    event Accrued(uint256 baseRateWad, uint256 interest, uint256 reserveAssets, uint256 treasuryShares);
    event CreditLineSet(address indexed line, uint256 cap, uint256 spreadBps, bool active);
    event Drawn(address indexed line, address indexed to, uint256 amount, uint256 scaled);
    event Repaid(address indexed line, uint256 assets, uint256 scaled);
    event BadDebt(address indexed line, uint256 loss, uint256 absorbed, uint256 treasurySharesBurned, uint256 toLenders);
    event InterestRateModelSet(address model);
    event LossAbsorberSet(address absorber);
    event ReserveFactorSet(uint256 bps);
    event TreasurySet(address treasury);

    error NotCreditLine();
    error CreditLineInactive();
    error TooManyLines();
    error InvalidParam();
    error CapExceeded();
    error InsufficientLiquidity();
    error ZeroAmount();
    error ExceedsDebt();

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address owner_,
        address guardian_,
        IInterestRateModel irm_,
        address treasury_,
        uint256 reserveFactorBps_
    ) ERC20(name_, symbol_) ERC4626(asset_) TabbAccessControl(owner_, guardian_) {
        if (address(irm_) == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (reserveFactorBps_ > MAX_RESERVE_FACTOR_BPS) revert InvalidParam();
        interestRateModel = irm_;
        treasury = treasury_;
        reserveFactorBps = reserveFactorBps_;
        lastAccrual = block.timestamp;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Interest accrual
    // ---------------------------------------------------------------------------------------------------------

    struct Snapshot {
        uint256[] indexes;
        uint256 totalDebt;
        uint256 interest;
        uint256 baseRate;
        uint256 treasuryShares; // shares to mint to treasury for the pending reserve cut
    }

    function _cash() internal view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function _storedTotalDebt() internal view returns (uint256 d) {
        uint256 n = lineList.length;
        for (uint256 i; i < n; ++i) {
            CreditLine storage l = _lines[lineList[i]];
            d += l.scaledDebt.toAssetsUp(l.index);
        }
    }

    function _utilization(uint256 cash, uint256 debt) internal pure returns (uint256) {
        uint256 denom = cash + debt;
        if (denom == 0 || debt == 0) return 0;
        return Math.mulDiv(debt, TabbMath.WAD, denom);
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        uint256 n = lineList.length;
        s.indexes = new uint256[](n);
        uint256 dt = block.timestamp - lastAccrual;
        uint256 cash = _cash();
        s.baseRate = interestRateModel.borrowRate(_utilization(cash, _storedTotalDebt()));
        for (uint256 i; i < n; ++i) {
            CreditLine storage l = _lines[lineList[i]];
            uint256 idx = l.index;
            if (dt > 0) {
                uint256 rate = s.baseRate + l.spreadBps * 1e14;
                idx = Math.mulDiv(idx, TabbMath.growthFactor(rate, dt), TabbMath.RAY);
            }
            s.indexes[i] = idx;
            uint256 newDebt = l.scaledDebt.toAssetsUp(idx);
            s.interest += newDebt - l.scaledDebt.toAssetsUp(l.index);
            s.totalDebt += newDebt;
        }
        uint256 reserveAssets = s.interest.bps(reserveFactorBps);
        if (reserveAssets > 0) {
            uint256 ta = cash + s.totalDebt;
            // mint so that the treasury owns `reserveAssets` worth after the mint
            s.treasuryShares = Math.mulDiv(
                reserveAssets, super.totalSupply() + 10 ** _decimalsOffset(), ta - reserveAssets + 1
            );
        }
    }

    function _accrue() internal {
        if (block.timestamp == lastAccrual) return;
        Snapshot memory s = _snapshot();
        uint256 n = lineList.length;
        for (uint256 i; i < n; ++i) {
            _lines[lineList[i]].index = s.indexes[i];
        }
        lastAccrual = block.timestamp;
        if (s.treasuryShares > 0) _mint(treasury, s.treasuryShares);
        emit Accrued(s.baseRate, s.interest, s.interest.bps(reserveFactorBps), s.treasuryShares);
    }

    function accrue() external nonReentrant {
        _accrue();
    }

    // ---------------------------------------------------------------------------------------------------------
    // ERC-4626
    // ---------------------------------------------------------------------------------------------------------

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function totalAssets() public view override returns (uint256) {
        return _cash() + _snapshot().totalDebt;
    }

    /// @dev Includes treasury shares that will be minted at the next accrual so previews are exact.
    function totalSupply() public view override(ERC20, IERC20) returns (uint256) {
        return super.totalSupply() + _snapshot().treasuryShares;
    }

    /// @notice Idle asset that lenders can withdraw / credit lines can draw.
    function availableLiquidity() public view returns (uint256) {
        return _cash();
    }

    function maxDeposit(address receiver) public view override returns (uint256) {
        if (isPaused(PAUSE_DEPOSIT)) return 0;
        return super.maxDeposit(receiver);
    }

    function maxMint(address receiver) public view override returns (uint256) {
        if (isPaused(PAUSE_DEPOSIT)) return 0;
        return super.maxMint(receiver);
    }

    function maxWithdraw(address owner_) public view override returns (uint256) {
        if (isPaused(PAUSE_WITHDRAW)) return 0;
        return Math.min(super.maxWithdraw(owner_), availableLiquidity());
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        if (isPaused(PAUSE_WITHDRAW)) return 0;
        return Math.min(balanceOf(owner_), _convertToShares(availableLiquidity(), Math.Rounding.Floor));
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        _accrue();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        _accrue();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        nonReentrant
        returns (uint256)
    {
        _accrue();
        return super.withdraw(assets, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_) public override nonReentrant returns (uint256) {
        _accrue();
        return super.redeem(shares, receiver, owner_);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Credit lines
    // ---------------------------------------------------------------------------------------------------------

    function _line(address who) internal view returns (CreditLine storage l) {
        l = _lines[who];
        if (!l.registered) revert NotCreditLine();
    }

    /// @inheritdoc ITabbPool
    function draw(uint256 amount, address to)
        external
        nonReentrant
        whenNotPaused(PAUSE_DRAW)
        returns (uint256 scaled)
    {
        CreditLine storage l = _line(msg.sender);
        if (!l.active) revert CreditLineInactive();
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        _accrue();
        if (amount > availableLiquidity()) revert InsufficientLiquidity();
        scaled = amount.toScaledUp(l.index);
        uint256 newScaled = l.scaledDebt + scaled;
        if (newScaled.toAssetsUp(l.index) > l.cap) revert CapExceeded();
        l.scaledDebt = newScaled;
        IERC20(asset()).safeTransfer(to, amount);
        emit Drawn(msg.sender, to, amount, scaled);
    }

    /// @inheritdoc ITabbPool
    function repay(uint256 scaled) external nonReentrant returns (uint256 assetsPaid) {
        CreditLine storage l = _line(msg.sender);
        if (scaled == 0) revert ZeroAmount();
        _accrue();
        if (scaled > l.scaledDebt) revert ExceedsDebt();
        assetsPaid = scaled.toAssetsUp(l.index);
        l.scaledDebt -= scaled;
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assetsPaid);
        emit Repaid(msg.sender, assetsPaid, scaled);
    }

    /// @inheritdoc ITabbPool
    function writeOff(uint256 scaled) external nonReentrant returns (uint256 loss) {
        CreditLine storage l = _line(msg.sender);
        if (scaled == 0) revert ZeroAmount();
        _accrue();
        if (scaled > l.scaledDebt) revert ExceedsDebt();
        loss = scaled.toAssetsUp(l.index);
        l.scaledDebt -= scaled;

        uint256 remaining = loss;
        uint256 absorbed;
        if (address(lossAbsorber) != address(0)) {
            uint256 before = _cash();
            try lossAbsorber.absorbLoss(loss) {} catch {}
            uint256 afterBal = _cash();
            absorbed = afterBal > before ? Math.min(afterBal - before, remaining) : 0;
            remaining -= absorbed;
        }
        // Insurance layer: burn treasury shares worth up to the remaining loss (valued after the loss).
        uint256 burned;
        if (remaining > 0) {
            uint256 tBal = balanceOf(treasury);
            uint256 sharesForLoss = _convertToShares(remaining, Math.Rounding.Ceil);
            burned = Math.min(tBal, sharesForLoss);
            if (burned > 0) {
                uint256 covered = Math.min(_convertToAssets(burned, Math.Rounding.Floor), remaining);
                _burn(treasury, burned);
                remaining -= covered;
            }
        }
        emit BadDebt(msg.sender, loss, absorbed, burned, remaining);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------

    function _lineIdx(address line) internal view returns (uint256) {
        uint256 n = lineList.length;
        for (uint256 i; i < n; ++i) {
            if (lineList[i] == line) return i;
        }
        revert NotCreditLine();
    }

    function indexOf(address line) public view returns (uint256) {
        return _snapshot().indexes[_lineIdx(line)];
    }

    function scaledDebtOf(address line) external view returns (uint256) {
        return _lines[line].scaledDebt;
    }

    function debtOf(address line) external view returns (uint256) {
        return _lines[line].scaledDebt.toAssetsUp(indexOf(line));
    }

    function totalDebt() public view returns (uint256) {
        return _snapshot().totalDebt;
    }

    function creditLine(address line) external view returns (CreditLine memory) {
        return _lines[line];
    }

    function lineCount() external view returns (uint256) {
        return lineList.length;
    }

    function utilization() public view returns (uint256) {
        Snapshot memory s = _snapshot();
        return _utilization(_cash(), s.totalDebt);
    }

    /// @notice Current annual borrow rate (WAD) paid by `line` (base + spread).
    function borrowRateOf(address line) external view returns (uint256) {
        return interestRateModel.borrowRate(utilization()) + _line(line).spreadBps * 1e14;
    }

    /// @notice Approximate annual lender rate (WAD): debt-weighted borrow rate * debt / totalAssets * (1 - rf).
    function supplyRate() external view returns (uint256) {
        Snapshot memory s = _snapshot();
        uint256 ta = _cash() + s.totalDebt;
        if (ta == 0) return 0;
        uint256 base = interestRateModel.borrowRate(_utilization(_cash(), s.totalDebt));
        uint256 weighted; // sum(rate_i * debt_i)
        uint256 n = lineList.length;
        for (uint256 i; i < n; ++i) {
            CreditLine storage l = _lines[lineList[i]];
            uint256 d = l.scaledDebt.toAssetsUp(s.indexes[i]);
            weighted += (base + l.spreadBps * 1e14) * d;
        }
        return Math.mulDiv(weighted / ta, TabbMath.BPS - reserveFactorBps, TabbMath.BPS);
    }

    // ---------------------------------------------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------------------------------------------

    function setCreditLine(address line, uint256 cap, uint256 spreadBps, bool active) external onlyOwner {
        if (line == address(0)) revert ZeroAddress();
        if (spreadBps > MAX_SPREAD_BPS) revert InvalidParam();
        _accrue();
        CreditLine storage l = _lines[line];
        if (!l.registered) {
            if (lineList.length >= MAX_LINES) revert TooManyLines();
            l.registered = true;
            l.index = TabbMath.RAY;
            lineList.push(line);
        }
        l.cap = cap;
        l.spreadBps = spreadBps;
        l.active = active;
        emit CreditLineSet(line, cap, spreadBps, active);
    }

    function setInterestRateModel(IInterestRateModel model) external onlyOwner {
        if (address(model) == address(0)) revert ZeroAddress();
        _accrue();
        interestRateModel = model;
        emit InterestRateModelSet(address(model));
    }

    function setReserveFactor(uint256 bps_) external onlyOwner {
        if (bps_ > MAX_RESERVE_FACTOR_BPS) revert InvalidParam();
        _accrue();
        reserveFactorBps = bps_;
        emit ReserveFactorSet(bps_);
    }

    function setLossAbsorber(ILossAbsorber absorber) external onlyOwner {
        lossAbsorber = absorber;
        emit LossAbsorberSet(address(absorber));
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        _accrue();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    /// @notice Treasury balance in assets, including shares pending mint.
    function treasuryAssets() external view returns (uint256) {
        Snapshot memory s = _snapshot();
        return convertToAssets(super.balanceOf(treasury) + s.treasuryShares);
    }
}
