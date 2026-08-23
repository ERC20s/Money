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

// Non-standard ERC20 that does not return bool on transfer
contract NonStandardERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 0);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    // override transfer to not return a value
    function transfer(address to, uint256 amount) public {
        _transfer(msg.sender, to, amount);
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
        // rate = 2 tokens per ETH
        uint256 rate = 2;
        uint256 sendWei = 1 ether / 1000; // 0.001 ETH
        vm.deal(alice, sendWei);

        vm.prank(alice);
        money.buy{value: sendWei}(rate);

        // token amount should be: wei * rate * 10**decimals / 1 ether
        uint256 expected = (sendWei * rate * (10 ** money.decimals())) / 1 ether;
        assertEq(money.balanceOf(alice), expected);
    }

    function testQueueAndExecuteWithdrawalTimelock() public {
        // ensure contract has balance
        uint256 contractBal = address(money).balance;
        assertGt(contractBal, 0);

        uint256 amount = 1 ether;
        vm.prank(owner);
        money.queueWithdrawal(amount);

        // cannot execute immediately
        vm.prank(owner);
        vm.expectRevert(bytes("Timelock not expired"));
        money.executeWithdrawal();

        // advance time by 48h
        vm.warp(block.timestamp + 48 hours + 1);

        uint256 ownerBefore = owner.balance;
        vm.prank(owner);
        money.executeWithdrawal();
        assertGt(owner.balance, ownerBefore);
    }

    function testPauseBlocksBuyAndWithdraw() public {
        uint256 sendWei = 1 ether / 1000;
        uint256 rate = 1;
        vm.deal(alice, sendWei);

        // pause
        vm.prank(owner);
        money.pause();

        vm.prank(alice);
        vm.expectRevert();
        money.buy{value: sendWei}(rate);

        vm.prank(owner);
        vm.expectRevert();
        money.queueWithdrawal(1 ether);

        // unpause and ensure buy works
        vm.prank(owner);
        money.unpause();

        vm.prank(alice);
        money.buy{value: sendWei}(rate);
        assertEq(money.balanceOf(alice), (sendWei * rate * (10 ** money.decimals())) / 1 ether);
    }

    function testOnlyOwnerAccess() public {
        vm.expectRevert();
        money.pause();

        vm.expectRevert();
        money.unpause();

        vm.expectRevert();
        money.queueWithdrawal(1 ether);

        vm.expectRevert();
        money.executeWithdrawal();
    }

    function testOwnerCanCancelQueuedWithdrawal() public {
        uint256 amount = 1 ether;
        vm.prank(owner);
        money.queueWithdrawal(amount);

        // cancel as owner
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit WithdrawalCancelled(amount);
        money.cancelQueuedWithdrawal();

        // queued state should be cleared
        assertEq(money.queuedAmount(), 0);
        assertEq(money.queuedExecuteTime(), 0);

        // execute should revert (generic) after cancellation
        vm.prank(owner);
        vm.expectRevert();
        money.executeWithdrawal();
    }

    function testRescueERC20Successful() public {
        // deploy a simple ERC20 and mint tokens to the Money contract
        SimpleERC20 token = new SimpleERC20("TKN", "TKN");
        token.mint(address(money), 1000);

        // owner rescues tokens to owner address
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Money.ERC20Rescued(address(token), owner, 1000);
        vm.prank(owner);
        money.rescueERC20(token, owner, 1000);

        assertEq(token.balanceOf(owner), 1000);
        assertEq(token.balanceOf(address(money)), 0);
    }

    function testRescueERC20CannotSweepMoney() public {
        // attempt to sweep the Money token should revert
        vm.prank(owner);
        vm.expectRevert(bytes("Cannot sweep Money token"));
        money.rescueERC20(IERC20(address(money)), owner, 1);
    }

    function testRescueNonStandardERC20Successful() public {
        NonStandardERC20 token = new NonStandardERC20("NST", "NST");
        token.mint(address(money), 500);

        // owner rescues tokens to owner address (non-standard token without bool return)
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Money.ERC20Rescued(address(token), owner, 500);
        vm.prank(owner);
        money.rescueERC20(IERC20(address(token)), owner, 500);

        assertEq(token.balanceOf(owner), 500);
        assertEq(token.balanceOf(address(money)), 0);
    }
}
