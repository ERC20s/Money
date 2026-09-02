// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../scripts/Deploy.s.sol";
import "../contracts/Money.sol";

contract DeployTest is Test {
    DeployScript deployer;
    address owner = address(0xABCD);

    function setUp() public {
        deployer = new DeployScript();
    }

    function testDeploySetsRateAndPendingOwner() public {
        uint256 initialRate = 3;
        address pending = address(0xBEEF);

        Money m = deployer.deploy(initialRate, pending);

        // owner is the deployer (this contract) by default
        assertEq(m.owner(), address(this));
        // pending owner should be nominated
        assertEq(m.pendingOwner(), pending);
        // rate should be set
        assertEq(m.rate(), initialRate);

        // buying at that rate mints expected tokens
        uint256 sendWei = 1 ether / 1000;
        vm.deal(address(0xCAFE), sendWei);
        vm.prank(address(0xCAFE));
        m.buy{value: sendWei}();
        uint256 expected = (sendWei * initialRate * (10 ** m.decimals())) / 1 ether;
        assertEq(m.balanceOf(address(0xCAFE)), expected);
    }

    function testDeployWithZeroRateRevertsOnBuy() public {
        Money m = deployer.deploy(0, address(0));
        uint256 sendWei = 1 ether / 1000;
        vm.deal(address(0xC0FFEE), sendWei);
        vm.prank(address(0xC0FFEE));
        vm.expectRevert();
        m.buy{value: sendWei}();
    }
}
