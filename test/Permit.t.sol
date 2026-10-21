// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../contracts/Money.sol";

contract PermitTest is Test {
    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    Money money;
    address owner = address(0xABCD);
    // alice's address is derived from the key that signs for her, so a permit signed with
    // alicePk is valid for alice and nothing else
    address alice;
    uint256 alicePk;

    function setUp() public {
        (alice, alicePk) = makeAddrAndKey("alice");

        vm.prank(owner);
        money = new Money();

        // give alice some tokens to test transferFrom after permit
        uint256 amount = 1000 * (10 ** money.decimals());
        vm.prank(owner);
        money.ownerMint(alice, amount);
    }

    function _digest(address holder, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, holder, spender, value, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", money.DOMAIN_SEPARATOR(), structHash));
    }

    // Construct an EIP-2612 permit and apply it, then check allowance, nonce and transferFrom
    function testPermitAllowsTransferFrom() public {
        uint256 nonce = money.nonces(alice);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 value = 500 * (10 ** money.decimals());

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, _digest(alice, address(this), value, nonce, deadline));

        // anyone may submit the permit; it reverts unless alicePk signed it
        money.permit(alice, address(this), value, deadline, v, r, s);

        assertEq(money.allowance(alice, address(this)), value);
        assertEq(money.nonces(alice), nonce + 1);

        // this contract is the spender, so it pulls alice's tokens with the allowance
        uint256 aliceBefore = money.balanceOf(alice);
        assertTrue(money.transferFrom(alice, address(this), value));

        assertEq(money.balanceOf(address(this)), value);
        assertEq(money.balanceOf(alice), aliceBefore - value);
        assertEq(money.allowance(alice, address(this)), 0);
    }

    // A permit for alice signed with any other key must revert and leave no allowance
    function testPermitRejectsInvalidSignature() public {
        uint256 nonce = money.nonces(alice);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 value = 1 * (10 ** money.decimals());

        (, uint256 otherPk) = makeAddrAndKey("mallory");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(otherPk, _digest(alice, address(this), value, nonce, deadline));

        vm.expectRevert(bytes("ERC20Permit: invalid signature"));
        money.permit(alice, address(this), value, deadline, v, r, s);

        assertEq(money.allowance(alice, address(this)), 0);
        assertEq(money.nonces(alice), nonce);
    }

    // A correctly signed permit is still rejected once its deadline has passed
    function testPermitRejectsExpiredDeadline() public {
        uint256 nonce = money.nonces(alice);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 value = 1 * (10 ** money.decimals());

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, _digest(alice, address(this), value, nonce, deadline));

        vm.warp(deadline + 1);
        vm.expectRevert(bytes("ERC20Permit: expired deadline"));
        money.permit(alice, address(this), value, deadline, v, r, s);
    }

    // A signature cannot be replayed: the nonce it was signed over is consumed by the first use
    function testPermitCannotBeReplayed() public {
        uint256 nonce = money.nonces(alice);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 value = 1 * (10 ** money.decimals());

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, _digest(alice, address(this), value, nonce, deadline));
        money.permit(alice, address(this), value, deadline, v, r, s);

        vm.expectRevert(bytes("ERC20Permit: invalid signature"));
        money.permit(alice, address(this), value, deadline, v, r, s);
    }
}
