// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../contracts/Money.sol";

/// @notice Forge script that can deploy Money in a reproducible, testable way.
contract DeployScript is Script {
    /// @notice Deploy helper that can be called from tests (no broadcasts).
    /// @param initialRate initial buy rate to set (0 to skip)
    /// @param pendingOwner optional pending owner nomination (address(0) to skip)
    function deploy(uint256 initialRate, address pendingOwner) public returns (Money) {
        Money m = new Money();
        if (initialRate != 0) {
            m.setRate(initialRate);
        }
        if (pendingOwner != address(0)) {
            m.transferOwnership(pendingOwner);
        }
        return m;
    }

    /// @notice run() reads environment variables when present and broadcasts when a private key is supplied.
    /// Required envs when performing a real broadcast: MONEY_DEPLOYER_PRIVATE_KEY, MONEY_RPC_URL, MONEY_INITIAL_RATE
    /// Optional: MONEY_OWNER to nominate a pending owner (two-step handover).
    function run() public {
        bool hasKey = vm.envExists("MONEY_DEPLOYER_PRIVATE_KEY");
        bool hasRate = vm.envExists("MONEY_INITIAL_RATE");
        bool hasOwner = vm.envExists("MONEY_OWNER");

        uint256 initialRate = 0;
        address pendingOwner = address(0);

        if (hasRate) {
            initialRate = vm.envUint("MONEY_INITIAL_RATE");
        }
        if (hasOwner) {
            pendingOwner = vm.envAddress("MONEY_OWNER");
        }

        if (hasKey) {
            uint256 pk = vm.envUint("MONEY_DEPLOYER_PRIVATE_KEY");
            // broadcast the deployment transaction
            vm.startBroadcast(pk);
            Money m = new Money();
            if (initialRate != 0) {
                m.setRate(initialRate);
            }
            if (pendingOwner != address(0)) {
                m.transferOwnership(pendingOwner);
            }
            vm.stopBroadcast();
        } else {
            // Dry-run: do the same without broadcasting (useful for local verification)
            Money m = new Money();
            if (initialRate != 0) {
                m.setRate(initialRate);
            }
            if (pendingOwner != address(0)) {
                m.transferOwnership(pendingOwner);
            }
            // Note: no logging here so callers (forge script output) will show the created address
        }
    }
}
