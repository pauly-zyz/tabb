// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {MockUSDG} from "./MockUSDG.sol";

/// @notice USDG ERC-4626 vault whose share price can be pushed up (yield) or down (loss) in tests.
contract MockERC4626Vault is ERC4626 {
    constructor(IERC20 usdg_) ERC20("Mock USDG Vault", "mvUSDG") ERC4626(usdg_) {}

    function injectYield(uint256 amount) external {
        MockUSDG(asset()).mint(address(this), amount);
    }

    function lose(uint256 amount) external {
        MockUSDG(asset()).burn(address(this), amount);
    }
}
