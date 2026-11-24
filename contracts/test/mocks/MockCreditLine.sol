// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITabbPool} from "../../src/interfaces/ITabbPool.sol";

/// @notice Minimal credit line used to exercise TabbPool in isolation.
contract MockCreditLine {
    ITabbPool public immutable pool;
    IERC20 public immutable asset;

    constructor(ITabbPool pool_, IERC20 asset_) {
        pool = pool_;
        asset = asset_;
        asset_.approve(address(pool_), type(uint256).max);
    }

    function draw(uint256 amount, address to) external returns (uint256) {
        return pool.draw(amount, to);
    }

    function repay(uint256 scaled) external returns (uint256) {
        return pool.repay(scaled);
    }

    function writeOff(uint256 scaled) external returns (uint256) {
        return pool.writeOff(scaled);
    }
}
