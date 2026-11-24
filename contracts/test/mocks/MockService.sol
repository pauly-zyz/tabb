// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice A whitelisted on-chain service (e.g. compute credits) that pulls USDG from the caller.
contract MockService {
    IERC20 public immutable usdg;
    mapping(address => uint256) public credits;
    uint256 public pings;

    constructor(IERC20 usdg_) {
        usdg = usdg_;
    }

    function buyCredits(uint256 amount) external {
        usdg.transferFrom(msg.sender, address(this), amount);
        credits[msg.sender] += amount;
    }

    function ping() external payable returns (uint256) {
        return ++pings;
    }

    function boom() external pure {
        revert("boom");
    }
}
