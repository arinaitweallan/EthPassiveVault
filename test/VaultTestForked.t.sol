// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {VaultTest} from "test/VaultTest.t.sol";
import {EthPassiveVault} from "src/EthPassiveVault.sol";
import {MockToken} from "test/mocks/MockToken.sol";

contract VaultTestForked is VaultTest {
    address constant AAVE_ORACLE = 0x54586bE62E3c3580375aE3723C145253060Ca0C2;

    function setUp() external override {
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(rpcUrl);

        token = new MockToken();

        vm.prank(_owner);
        vault = new EthPassiveVault(AAVE_ORACLE);
    }
}
