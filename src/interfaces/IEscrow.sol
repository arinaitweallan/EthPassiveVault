// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IEscrow {
    error ZeroAddress();
    error NotAuthorized();
    error Failed();

    function transferShares(address to, uint256 amount) external;
}
