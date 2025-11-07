interface ISafeProxyFactory {
    function computeProxyAddress(address user) external view returns (address);
}