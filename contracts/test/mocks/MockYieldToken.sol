// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IClipYieldToken} from "../../src/interfaces/IClipYieldToken.sol";
import {MockUSDG} from "./MockUSDG.sol";

/// @notice Stock-dividend YT stand-in: 18-dec ERC-20, USDG dividends tracked per holder with an accumulator.
contract MockYieldToken is ERC20, IClipYieldToken {
    MockUSDG public immutable usdg;
    uint256 public immutable maturity;
    uint256 public accPerToken; // 1e18-scaled USDG per YT
    mapping(address => uint256) public debtOf;
    mapping(address => uint256) public owed;

    constructor(MockUSDG usdg_, uint256 maturity_) ERC20("Mock Clipt Dividend YT", "ytDIV") {
        usdg = usdg_;
        maturity = maturity_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Pays `amount` USDG of dividends pro-rata to current holders.
    function distributeDividend(uint256 amount) external {
        require(totalSupply() > 0, "no supply");
        usdg.mint(address(this), amount);
        accPerToken += amount * 1e18 / totalSupply();
    }

    function claimable(address holder) public view returns (uint256) {
        return owed[holder] + balanceOf(holder) * accPerToken / 1e18 - debtOf[holder];
    }

    function claim() external returns (uint256 amount) {
        amount = claimable(msg.sender);
        owed[msg.sender] = 0;
        debtOf[msg.sender] = balanceOf(msg.sender) * accPerToken / 1e18;
        if (amount > 0) usdg.transfer(msg.sender, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) {
            owed[from] = claimable(from);
        }
        if (to != address(0)) {
            owed[to] = claimable(to);
        }
        super._update(from, to, value);
        if (from != address(0)) debtOf[from] = balanceOf(from) * accPerToken / 1e18;
        if (to != address(0)) debtOf[to] = balanceOf(to) * accPerToken / 1e18;
    }
}
