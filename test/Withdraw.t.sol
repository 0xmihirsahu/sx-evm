// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import { SpaceTest } from "./utils/Space.t.sol";

contract WithdrawTest is SpaceTest {
    function testOwnerCanWithdrawFeeFloat() public {
        // The space is funded with 10 ether in setUp.
        address payable sink = payable(address(0xBEEF));
        uint256 balanceBefore = sink.balance;
        space.withdraw(sink, 1 ether);
        assertEq(sink.balance, balanceBefore + 1 ether);
    }

    function testNonOwnerCannotWithdraw() public {
        vm.prank(unauthorized);
        _expectOnlyOwnerRevert(unauthorized);
        space.withdraw(payable(unauthorized), 1 ether);
    }
}
