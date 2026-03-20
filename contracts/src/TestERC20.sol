// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC20 with an open mint — for deposit/withdrawal tests.
contract TestERC20 is ERC20 {
    constructor() ERC20("TestERC20", "T20") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
