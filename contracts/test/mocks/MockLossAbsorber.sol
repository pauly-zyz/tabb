// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILossAbsorber} from "../../src/interfaces/ILossAbsorber.sol";

contract MockLossAbsorber is ILossAbsorber {
    IERC20 public immutable asset;
    address public immutable pool;
    bool public shouldRevert;

    constructor(IERC20 asset_, address pool_) {
        asset = asset_;
        pool = pool_;
    }

    function setRevert(bool v) external {
        shouldRevert = v;
    }

    function absorbLoss(uint256 loss) external returns (uint256) {
        require(!shouldRevert, "absorber down");
        uint256 bal = asset.balanceOf(address(this));
        uint256 amt = loss < bal ? loss : bal;
        asset.transfer(pool, amt);
        return amt;
    }
}
