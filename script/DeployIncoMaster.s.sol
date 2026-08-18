// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import { Script } from "forge-std/Script.sol";
import { Space } from "../src/Space.sol";

/// @notice One-off deploy of a fresh master Space implementation. Use when the
///         on-chain event surface changes (e.g. adding `DecisionFlagsRevealed`)
///         and existing clones can't be upgraded. The existing ProxyFactory
///         (`deployProxy(impl, initData, salt)`) takes the implementation per
///         call so it does NOT need redeploying — just point it at the new
///         master from the UI / sx-monorepo config.
contract DeployIncoMaster is Script {
    function run() external returns (address master) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        master = address(new Space());
        vm.stopBroadcast();
    }
}
