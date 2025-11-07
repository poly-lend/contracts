// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface ISafeProxyFactory {
    function computeProxyAddress(address user) external view returns (address);
}