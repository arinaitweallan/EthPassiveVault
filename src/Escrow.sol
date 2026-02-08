// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IEscrow} from "src/interfaces/IEscrow.sol";

contract Escrow is IEscrow {
    IERC20 public token;
    address public vault;

    constructor(address _vault, address _token) {
        require(_vault != address(0) || _token != address(0), ZeroAddress());
        vault = _vault;
        token = IERC20(_token);
    }

    /// @dev transfer shares to new owner
    function transferShares(address to, uint256 amount) external {
        require(msg.sender == vault, NotAuthorized());
        bool ok = token.transfer(to, amount);
        require(ok, Failed());
    }
}
