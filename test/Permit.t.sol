// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../contracts/Money.sol";

contract PermitTest is Test {
    using ECDSA for bytes32;

    Money money;
    address owner = address(0xABCD);
    address alice = address(0xBEEF);

    function setUp() public {
        vm.prank(owner);
        money = new Money();

        // give alice some tokens to test transferFrom after permit
        vm.prank(owner);
        money.ownerMint(alice, 1000 * (10 ** money.decimals()));
    }

    // Construct an EIP-2612 permit and apply it, then check allowance and transferFrom
    function testPermitAllowsTransferFrom() public {
        uint256 nonce = money.nonces(alice);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 value = 500 * (10 ** money.decimals());

        // Build the digest per EIP-712
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            alice,
            address(this),
            value,
            nonce,
            deadline
        ));

        bytes32 domainSeparator = money.DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Sign the digest with alice's private key; in Foundry tests we can derive a key for an address
        uint256 pk = uint256(keccak256(abi.encodePacked(alice)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        // call permit as any caller
        money.permit(alice, address(this), value, deadline, v, r, s);

        // allowance should be set and transferFrom should succeed
        assertEq(money.allowance(alice, address(this)), value);

        // perform transferFrom from alice to this contract
        vm.prank(alice);
        money.transferFrom(alice, address(this), value);

        assertEq(money.balanceOf(address(this)), value);
    }

    // Invalid signature should revert
    function testPermitRejectsInvalidSignature() public {
        uint256 nonce = money.nonces(alice);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 value = 1 * (10 ** money.decimals());

        bytes32 structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            alice,
            address(this),
            value,
            nonce,
            deadline
        ));

        bytes32 domainSeparator = money.DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // sign with a different key
        uint256 pk = uint256(keccak256(abi.encodePacked(address(0xDEAD))));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        vm.expectRevert();
        money.permit(alice, address(this), value, deadline, v, r, s);
    }
}
