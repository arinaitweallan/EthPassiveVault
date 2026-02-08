// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock Token", "MTN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
