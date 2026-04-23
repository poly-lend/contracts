// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PolyLend} from "../src/PolyLend.sol";
import {pfUSDC} from "../src/dev/USDC.sol";

/// @notice Deploy PolyLend against an Anvil fork of Polygon.
/// @dev Uses the pfUSDC, ConditionalTokens, and SafeProxyFactory that carry over from the fork.
///      Writes deployment metadata to ./deployments/testnet.json for the backend and webapp to consume.
///      Idempotent: if the recorded PolyLend address already has code, the script is a no-op.
contract DeployTestnet is Script {
    // Canonical Polygon mainnet addresses (present on the fork)
    address constant PFUSDC = 0xf6b4Ae31f5C74191E920291c68e9769c4a46D3E4;
    address constant CONDITIONAL_TOKENS = 0x4D97DCd97eC945f40cF65F87097ACe5EA0476045;
    address constant SAFE_PROXY_FACTORY = 0xaacFeEa03eb1561C4e67d661e40682Bd20E3541b;

    // Anvil default account #0 (from the deterministic test mnemonic)
    uint256 constant ANVIL_DEFAULT_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address constant ANVIL_DEFAULT_ADDR = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    string constant DEPLOYMENT_PATH = "./deployments/testnet.json";

    function run() external {
        // Only run against an Anvil fork, never real networks
        require(block.chainid == 31337, "DeployTestnet: expected chain-id 31337");

        // Idempotency: if a deployment exists and the contract still has code, skip
        if (vm.exists(DEPLOYMENT_PATH)) {
            string memory existing = vm.readFile(DEPLOYMENT_PATH);
            address recorded = vm.parseJsonAddress(existing, ".polylend");
            if (recorded != address(0) && recorded.code.length > 0) {
                console.log("PolyLend already deployed at:", recorded);
                console.log("Delete deployments/testnet.json to force a fresh deploy.");
                return;
            }
        }

        address feeRecipient = vm.envOr("FEE_RECIPIENT", ANVIL_DEFAULT_ADDR);
        address faucetSigner = vm.envOr("FAUCET_SIGNER", ANVIL_DEFAULT_ADDR);
        uint256 faucetAmount = vm.envOr("FAUCET_AMOUNT", uint256(10_000_000 * 1e6)); // 10M pfUSDC (6 decimals)
        uint256 deployerKey = vm.envOr("DEPLOYER_PRIVATE_KEY", ANVIL_DEFAULT_KEY);

        vm.startBroadcast(deployerKey);

        PolyLend polylend = new PolyLend(CONDITIONAL_TOKENS, PFUSDC, SAFE_PROXY_FACTORY, feeRecipient);
        pfUSDC(PFUSDC).mint(faucetSigner, faucetAmount);

        vm.stopBroadcast();

        console.log("PolyLend deployed at:", address(polylend));
        console.log("Minted pfUSDC to faucet:", faucetSigner, faucetAmount);

        _writeDeploymentJson(address(polylend), feeRecipient);
    }

    function _writeDeploymentJson(address polylend, address feeRecipient) internal {
        string memory key = "deployment";
        vm.serializeAddress(key, "polylend", polylend);
        vm.serializeAddress(key, "pfUSDC", PFUSDC);
        vm.serializeAddress(key, "conditionalTokens", CONDITIONAL_TOKENS);
        vm.serializeAddress(key, "safeProxyFactory", SAFE_PROXY_FACTORY);
        vm.serializeAddress(key, "feeRecipient", feeRecipient);
        vm.serializeUint(key, "chainId", block.chainid);
        string memory output = vm.serializeUint(key, "deployedAtBlock", block.number);

        vm.writeJson(output, DEPLOYMENT_PATH);
        console.log("Wrote deployment to", DEPLOYMENT_PATH);
    }
}
