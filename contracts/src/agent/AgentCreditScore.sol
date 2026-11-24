// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {TabbAccessControl} from "../access/TabbAccessControl.sol";
import {IAgentCreditScore} from "../interfaces/IAgentCreditScore.sol";
import {IAgentRiskConfig} from "../interfaces/IAgentRiskConfig.sol";
import {IOwnerStakeVault} from "../interfaces/IOwnerStakeVault.sol";

/// @title AgentCreditScore
/// @notice Deterministic credit limits for agents from: owner stake, revenue that flowed through the agent's
///         RepaymentSplitter (rolling window of 7-day epochs), age in Tabb, and qualified repayment cycles.
///         ERC-8004 reputation feedback is intentionally NOT used in the MVP (sybil-prone).
contract AgentCreditScore is IAgentCreditScore, TabbAccessControl {
    uint256 public constant EPOCH = 7 days;
    uint256 public constant RING = 26;

    IAgentRiskConfig public immutable config;
    IOwnerStakeVault public immutable vault;
    address public manager;

    struct Record {
        uint64 firstSeenAt;
        uint64 lastDelinquentAt;
        uint32 qualifiedCycles;
        uint32 totalCycles;
        uint32 delinquencies;
        bool defaulted;
    }

    struct Bucket {
        uint64 epoch;
        uint192 amount;
    }

    mapping(uint256 => Record) public records;
    mapping(uint256 => Bucket[RING]) internal _buckets;

    event ManagerSet(address manager);
    event RevenueRecorded(uint256 indexed agentId, uint256 epoch, uint256 amount);
    event CycleCompleted(uint256 indexed agentId, bool qualified, uint32 qualifiedCycles);
    event Delinquency(uint256 indexed agentId);
    event Defaulted(uint256 indexed agentId);

    error NotManager();
    error ManagerAlreadySet();

    constructor(IAgentRiskConfig config_, IOwnerStakeVault vault_, address owner_)
        TabbAccessControl(owner_, address(0))
    {
        if (address(config_) == address(0) || address(vault_) == address(0)) revert ZeroAddress();
        config = config_;
        vault = vault_;
    }

    modifier onlyManager() {
        if (msg.sender != manager) revert NotManager();
        _;
    }

    function setManager(address manager_) external onlyOwner {
        if (manager != address(0)) revert ManagerAlreadySet();
        if (manager_ == address(0)) revert ZeroAddress();
        manager = manager_;
        emit ManagerSet(manager_);
    }

    // ------------------------------------------------------------------ hooks

    function onFirstSeen(uint256 agentId) external onlyManager {
        if (records[agentId].firstSeenAt == 0) records[agentId].firstSeenAt = uint64(block.timestamp);
    }

    function recordRevenue(uint256 agentId, uint256 amount) external onlyManager {
        if (amount == 0) return;
        uint256 epoch = block.timestamp / EPOCH;
        Bucket storage b = _buckets[agentId][epoch % RING];
        if (b.epoch != epoch) {
            b.epoch = uint64(epoch);
            b.amount = 0;
        }
        uint256 newAmt = uint256(b.amount) + amount;
        b.amount = newAmt > type(uint192).max ? type(uint192).max : uint192(newAmt);
        emit RevenueRecorded(agentId, epoch, amount);
    }

    function onCycleCompleted(uint256 agentId, bool qualified) external onlyManager {
        Record storage r = records[agentId];
        r.totalCycles += 1;
        if (qualified) r.qualifiedCycles += 1;
        emit CycleCompleted(agentId, qualified, r.qualifiedCycles);
    }

    function onDelinquent(uint256 agentId) external onlyManager {
        Record storage r = records[agentId];
        r.delinquencies += 1;
        r.lastDelinquentAt = uint64(block.timestamp);
        emit Delinquency(agentId);
    }

    function onDefault(uint256 agentId) external onlyManager {
        records[agentId].defaulted = true;
        emit Defaulted(agentId);
    }

    // ------------------------------------------------------------------ views

    function revenueInWindow(uint256 agentId) public view returns (uint256 total) {
        uint256 window = config.params().windowEpochs;
        uint256 current = block.timestamp / EPOCH;
        uint256 oldest = current + 1 > window ? current + 1 - window : 0;
        for (uint256 i; i < RING; ++i) {
            Bucket memory b = _buckets[agentId][i];
            if (b.amount != 0 && b.epoch >= oldest && b.epoch <= current) total += b.amount;
        }
    }

    function tierOf(uint256 agentId) public view returns (uint256) {
        Record memory r = records[agentId];
        if (r.firstSeenAt == 0) return 0;
        uint256 age = block.timestamp - r.firstSeenAt;
        uint256 n = config.tierCount();
        for (uint256 i = n; i > 1; --i) {
            IAgentRiskConfig.Tier memory t = config.tier(i - 1);
            bool clean = r.lastDelinquentAt == 0 || block.timestamp - r.lastDelinquentAt >= t.cleanWindow;
            if (r.qualifiedCycles >= t.minCycles && age >= t.minAge && clean) return i - 1;
        }
        return 0;
    }

    function breakdown(uint256 agentId, address owner_) public view returns (Breakdown memory b) {
        IAgentRiskConfig.Params memory p = config.params();
        Record memory r = records[agentId];
        b.stake = vault.stakeOf(agentId, owner_);
        b.tier = tierOf(agentId);
        b.leverageBps = config.tier(b.tier).leverageBps;
        b.revenue = revenueInWindow(agentId);
        b.revenueLimit = Math.mulDiv(b.revenue, p.revenueAdvanceBps, 10_000);
        b.capacity = Math.max(p.baseLimit, b.revenueLimit);
        b.stakeLimit = Math.mulDiv(b.stake, b.leverageBps, 10_000);
        if (!r.defaulted && b.stake >= p.minStake) {
            b.limit = Math.min(Math.min(b.capacity, b.stakeLimit), p.maxPerAgent);
        }
        b.score = _score(r, b, p);
    }

    function creditLimit(uint256 agentId, address owner_) external view returns (uint256) {
        return breakdown(agentId, owner_).limit;
    }

    function score(uint256 agentId, address owner_) external view returns (uint256) {
        return breakdown(agentId, owner_).score;
    }

    /// @dev Display-only score in [0, 1000]: tier 0/300/600 + age (<=150) + revenue (<=150) + cycles (<=100).
    function _score(Record memory r, Breakdown memory b, IAgentRiskConfig.Params memory p)
        internal
        view
        returns (uint256)
    {
        if (r.defaulted || r.firstSeenAt == 0) return 0;
        uint256 s = b.tier * 300;
        uint256 age = block.timestamp - r.firstSeenAt;
        s += Math.min(age, 180 days) * 150 / 180 days;
        uint256 revTarget = p.maxPerAgent * 4;
        s += Math.min(b.revenue, revTarget) * 150 / revTarget;
        s += Math.min(uint256(r.qualifiedCycles), 20) * 100 / 20;
        return Math.min(s, 1000);
    }
}
