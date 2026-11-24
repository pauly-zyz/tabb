// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {TabbAccessControl} from "../access/TabbAccessControl.sol";
import {IAgentRiskConfig} from "../interfaces/IAgentRiskConfig.sol";

/// @title AgentRiskConfig
/// @notice Risk parameters for agent credit. Owner-controlled (intended: timelock), every setter is bounded.
contract AgentRiskConfig is IAgentRiskConfig, TabbAccessControl {
    uint256 public constant MAX_TIERS = 3;
    uint32 public constant MAX_LEVERAGE_BPS = 50_000; // 5x
    uint16 public constant MIN_SPLIT_FLOOR_BPS = 500; // 5%
    uint16 public constant MAX_DISTRIBUTE_FEE_BPS = 500; // 5%
    uint32 public constant MIN_DEFAULT_DELAY = 7 days;
    uint8 public constant MAX_WINDOW_EPOCHS = 26;

    Params internal _params;
    Tier[] internal _tiers;
    address public feeRecipient;

    bool public ownerAllowlistEnabled;
    mapping(address => bool) public ownerAllowlisted;

    event ParamsSet(Params params);
    event TiersSet(Tier[] tiers);
    event FeeRecipientSet(address recipient);
    event OwnerAllowlistSet(bool enabled);
    event OwnerAllowlisted(address indexed owner, bool allowed);

    error InvalidParams();

    constructor(address owner_, address guardian_, Params memory p, Tier[] memory t, address feeRecipient_)
        TabbAccessControl(owner_, guardian_)
    {
        _setParams(p);
        _setTiers(t);
        feeRecipient = feeRecipient_;
    }

    function params() external view returns (Params memory) {
        return _params;
    }

    function tier(uint256 i) external view returns (Tier memory) {
        return _tiers[i];
    }

    function tierCount() external view returns (uint256) {
        return _tiers.length;
    }

    function isOwnerAllowed(address who) external view returns (bool) {
        return !ownerAllowlistEnabled || ownerAllowlisted[who];
    }

    function setParams(Params calldata p) external onlyOwner {
        _setParams(p);
    }

    function setTiers(Tier[] calldata t) external onlyOwner {
        _setTiers(t);
    }

    function setFeeRecipient(address r) external onlyOwner {
        feeRecipient = r;
        emit FeeRecipientSet(r);
    }

    function setOwnerAllowlistEnabled(bool enabled) external onlyOwner {
        ownerAllowlistEnabled = enabled;
        emit OwnerAllowlistSet(enabled);
    }

    function setOwnerAllowlisted(address who, bool allowed) external onlyOwner {
        ownerAllowlisted[who] = allowed;
        emit OwnerAllowlisted(who, allowed);
    }

    function _setParams(Params memory p) internal {
        if (p.minStake == 0 || p.baseLimit == 0) revert InvalidParams();
        if (p.maxPerAgent == 0 || p.maxPerAgent > p.maxPerOwner) revert InvalidParams();
        if (p.minDebt > p.maxPerAgent) revert InvalidParams();
        if (p.revenueAdvanceBps > 10_000) revert InvalidParams();
        if (p.minSplitBps < MIN_SPLIT_FLOOR_BPS || p.minSplitBps > p.defaultSplitBps || p.defaultSplitBps > 10_000) {
            revert InvalidParams();
        }
        if (p.minPaymentBps < 100 || p.minPaymentBps > 10_000) revert InvalidParams();
        if (p.dailySpendCapBps == 0 || p.dailySpendCapBps > 10_000) revert InvalidParams();
        if (p.distributeFeeBps > MAX_DISTRIBUTE_FEE_BPS) revert InvalidParams();
        if (p.paymentPeriod < 1 days || p.gracePeriod > p.paymentPeriod) revert InvalidParams();
        if (p.defaultDelay < MIN_DEFAULT_DELAY) revert InvalidParams();
        if (p.windowEpochs == 0 || p.windowEpochs > MAX_WINDOW_EPOCHS) revert InvalidParams();
        _params = p;
        emit ParamsSet(p);
    }

    function _setTiers(Tier[] memory t) internal {
        if (t.length == 0 || t.length > MAX_TIERS) revert InvalidParams();
        delete _tiers;
        for (uint256 i; i < t.length; ++i) {
            if (t[i].leverageBps == 0 || t[i].leverageBps > MAX_LEVERAGE_BPS) revert InvalidParams();
            if (i == 0 && (t[i].minCycles != 0 || t[i].minAge != 0)) revert InvalidParams();
            if (i > 0) {
                Tier memory prev = t[i - 1];
                if (t[i].leverageBps < prev.leverageBps || t[i].minCycles < prev.minCycles || t[i].minAge < prev.minAge)
                {
                    revert InvalidParams();
                }
            }
            _tiers.push(t[i]);
        }
        emit TiersSet(t);
    }
}
