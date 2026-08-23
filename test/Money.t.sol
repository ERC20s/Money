// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../contracts/Money.sol";

contract SimpleERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 0);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// NonStandardERC20 simulates tokens that implement transfer without a return value.
contract NonStandardERC20 {
    string public name = "NST";
    string public symbol = "NST";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    // transfer that does NOT return a bool
    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "Insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
    }
}

// BadRecipient is a helper contract that rejects incoming ETH to simulate a reverting recipient.
contract BadRecipient {
    // revert on any ETH transfer
    receive() external payable {
        revert("bad recipient");
    }
    fallback() external payable {
        revert("bad recipient");
    }

    // deploy a Money contract so that this contract becomes the owner
    function deployMoney() public returns (Money) {
        return new Money();
    }

    // call queueWithdrawal on the Money contract from this contract's context
    function callQueueWithdrawal(Money money, uint256 amount) public {
        money.queueWithdrawal(amount);
    }

    // call queueWithdrawalTo on the Money contract from this contract's context
    function callQueueWithdrawalTo(Money money, address recipient, uint256 amount) public {
        money.queueWithdrawalTo(recipient, amount);
    }
}

contract MoneyTest is Test {
    Money money;
    address owner = address(0xABCD);
    address alice = address(0xBEEF);

    function setUp() public {
        vm.prank(owner);
        money = new Money();
        // fund contract so owner can withdraw later
        vm.deal(address(this), 10 ether);
        payable(address(money)).transfer(5 ether);
    }

    function testBuyNormalizesUnits() public {
        uint256 rate = 2;
        uint256 sendWei = 1 ether / 1000; // 0.001 ETH
        vm.deal(alice, sendWei);

        vm.prank(owner);
        money.setRate(rate);

        vm.prank(alice);
        money.buy{value: sendWei}();

        uint256 expected = (sendWei * rate * (10 ** money.decimals())) / 1 ether;
        assertEq(money.balanceOf(alice), expected);
    }

    function testRescueERC20Successful() public {
        SimpleERC20 token = new SimpleERC20("TKN", "TKN");
        token.mint(address(money), 1000);

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Money.ERC20Rescued(address(token), owner, 1000);
        vm.prank(owner);
        money.rescueERC20(token, owner, 1000);

        assertEq(token.balanceOf(owner), 1000);
        assertEq(token.balanceOf(address(money)), 0);
    }

    function testRescueERC20CannotSweepMoney() public {
        vm.prank(owner);
        vm.expectRevert(bytes("Cannot sweep Money token"));
        money.rescueERC20(IERC20(address(money)), owner, 1);
    }

    function testRescueNonStandardERC20Successful() public {
        NonStandardERC20 token = new NonStandardERC20();
        token.mint(address(money), 500);

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Money.ERC20Rescued(address(token), owner, 500);
        vm.prank(owner);
        money.rescueERC20(IERC20(address(token)), owner, 500);

        assertEq(token.balanceOf(owner), 500);
        assertEq(token.balanceOf(address(money)), 0);
    }

    function testRescueERC20RejectsZeroRecipient() public {
        SimpleERC20 token = new SimpleERC20("TKN", "TKN");
        token.mint(address(money), 1000);

        vm.prank(owner);
        vm.expectRevert(bytes("Recipient zero"));
        money.rescueERC20(token, address(0), 1000);

        // ensure tokens still remain in the Money contract
        assertEq(token.balanceOf(address(money)), 1000);
    }

    function testExecuteWithdrawalToRevertingRecipientPreservesQueuedState() public {
        BadRecipient bad = new BadRecipient();
        Money money2 = bad.deployMoney();

        // fund money2 so it can attempt the transfer
        payable(address(money2)).transfer(1 ether);

        // have the BadRecipient contract queue a withdrawal (it is the owner)
        bad.callQueueWithdrawal(money2, 1 ether);

        // cannot execute until timelock expires
        vm.warp(block.timestamp + 48 hours + 1);

        // executing should revert with "Transfer failed" because recipient reverts on receive
        vm.expectRevert(bytes("Transfer failed"));
        money2.executeWithdrawal();

        // after the failed execution, the queued state should remain intact
        assertEq(money2.queuedAmount(), 1 ether);
        assertEq(money2.queuedRecipient(), address(bad));
    }
}
