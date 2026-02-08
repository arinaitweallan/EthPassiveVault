// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

contract AaveOracleMock {
    uint64 public scale = 1e8;
    uint256 price = 2000;

    function getAssetPrice(address asset) external view returns (uint256 _price) {
        if (asset == address(0)) {
            _price = price * scale;
        } else {
            _price = price * scale;
        }
    }

    function setPrice(uint256 price_) external {
        price = price_;
    }
}
