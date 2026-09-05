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

contract RejectingRecipient {
    fallback() external payable { revert("Recipient rejects"); }
    receive() external payable { revert("Recipient rejects"); }
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

    function testQueueAndExecuteWithdrawalTimelock() public {
        uint256 contractBal = address(money).balance;
        assertGt(contractBal, 0);

        uint256 amount = 1 ether;
        vm.prank(owner);
        money.queueWithdrawal(amount);

        assertEq(money.queuedRecipient(), owner);

        // after queuing, timeUntilQueuedWithdrawal should be > 0
        uint256 remaining = money.timeUntilQueuedWithdrawal();
        assertGt(remaining, 0);

        vm.prank(owner);
        vm.expectRevert(bytes("Timelock not expired"));
        money.executeWithdrawal();

        vm.warp(block.timestamp + 48 hours + 1);

        // after timelock has passed, timeUntilQueuedWithdrawal should be 0
        assertEq(money.timeUntilQueuedWithdrawal(), 0);

        vm.prank(owner);
        money.executeWithdrawal();

        assertEq(money.queuedRecipient(), address(0));
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

    // New: rescue to zero is forbidden by default
    function testRescueERC20RejectsZeroRecipient() public {
        SimpleERC20 token = new SimpleERC20("TKN", "TKN");
        token.mint(address(money), 1000);

        vm.prank(owner);
        vm.expectRevert();
        money.rescueERC20(token, address(0), 1000);
    }

    // New: only owner can queue the enable; non-owner attempt should revert and not set queued time
    function testQueueEnableRescueOnlyOwnerAndStateUnchangedOnRevert() public {
        vm.prank(alice);
        vm.expectRevert();
        money.queueEnableRescueToZero();

        assertEq(money.queuedRescueToZeroExecuteTime(), 0);
    }

    // New: owner can queue enable, after timelock executeEnableRescueToZero allows rescue to address(0)
    function testEnableRescueToZeroAllowsBurnAfterTimelock() public {
        NonStandardERC20 token = new NonStandardERC20();
        token.mint(address(money), 500);

        // queue the opt-in as owner
        vm.prank(owner);
        money.queueEnableRescueToZero();

        uint256 queued = money.queuedRescueToZeroExecuteTime();
        assertGt(queued, 0);

        // advance past timelock
        vm.warp(block.timestamp + 48 hours + 1);

        // execute the opt-in (anyone may call execute)
        money.executeEnableRescueToZero();

        // now the owner may rescue to address(0)
        vm.prank(owner);
        money.rescueERC20(IERC20(address(token)), address(0), 500);

        // balances on the non-standard token should reflect the transfer to address(0)
        assertEq(token.balanceOf(address(money)), 0);
        assertEq(token.balanceOf(address(0)), 500);
    }

    // New: owner may cancel a queued enable before it executes
    function testCancelQueuedEnableRescueToZero() public {
        // queue the opt-in
        vm.prank(owner);
        money.queueEnableRescueToZero();

        uint256 queued = money.queuedRescueToZeroExecuteTime();
        assertGt(queued, 0);

        // queued time should be non-zero and timeUntilQueuedRescueToZero should be > 0
        uint256 remaining = money.timeUntilQueuedRescueToZero();
        assertGt(remaining, 0);

        // cancel it as the owner
        vm.prank(owner);
        money.cancelQueuedEnableRescueToZero();

        // queued time should be reset
        assertEq(money.queuedRescueToZeroExecuteTime(), 0);
        assertEq(money.timeUntilQueuedRescueToZero(), 0);

        // executing now should revert with the expected error
        vm.expectRevert(bytes("No queued enable"));
        money.executeEnableRescueToZero();
    }

    function testSetRateOnlyOwnerAndBuyRevertsWhenZero() public {
        uint256 rate = 3;
        uint256 sendWei = 1 ether / 1000;

        // non-owner cannot set rate
        vm.prank(alice);
        vm.expectRevert();
        money.setRate(rate);

        // buy reverts while rate == 0
        vm.deal(alice, sendWei);
        vm.prank(alice);
        vm.expectRevert(bytes("Rate must be > 0"));
        money.buy{value: sendWei}();

        // owner sets rate and buy succeeds
        vm.prank(owner);
        money.setRate(rate);

        vm.prank(alice);
        money.buy{value: sendWei}();
        uint256 expected = (sendWei * rate * (10 ** money.decimals())) / 1 ether;
        assertEq(money.balanceOf(alice), expected);
    }

    // New tests for previewWeiForTokens added per proposal #129
    function testPreviewWeiForTokensGuaranteesBuy() public {
        uint256 rate = 2;
        vm.prank(owner);
        money.setRate(rate);

        // request 3 tokens (in token units)
        uint256 tokenUnits = 3 * (10 ** money.decimals());

        (uint256 weiReq, bool ok) = money.previewWeiForTokens(tokenUnits);
        assertTrue(ok, "preview should succeed");
        assertGt(weiReq, 0);

        // fund the buyer and execute a buy with minTokenAmount = tokenUnits
        vm.deal(alice, weiReq);
        vm.prank(alice);
        money.buy{value: weiReq}(tokenUnits);

        assertGe(money.balanceOf(alice), tokenUnits);
    }

    function testPreviewWeiForTokensRejectsOverflowAndZeroRate() public {
        // while rate == 0 preview should fail
        (uint256 w0, bool ok0) = money.previewWeiForTokens(1);
        assertFalse(ok0);
        assertEq(w0, 0);

        // set a rate and request an enormous tokenUnits that would overflow numerator
        vm.prank(owner);
        money.setRate(1);

        uint256 huge = type(uint256).max / 1 ether + 1;
        (uint256 w1, bool ok1) = money.previewWeiForTokens(huge);
        assertFalse(ok1);
        assertEq(w1, 0);
    }

    function testPreviewBuyAndPreviewWeiRoundTrip() public {
        uint256 rate = 5;
        vm.prank(owner);
        money.setRate(rate);

        uint256 weiAmount = 1 ether / 1000; // 0.001 ETH
        (uint256 tokenAmount, bool ok) = money.previewBuy(weiAmount);
        assertTrue(ok);
        assertGt(tokenAmount, 0);

        (uint256 weiReq, bool ok2) = money.previewWeiForTokens(tokenAmount);
        assertTrue(ok2);

        // The required wei to get tokenAmount should not exceed the original wei used to compute it
        assertLe(weiReq, weiAmount);

        // And previewBuy on the computed wei should return at least tokenAmount (ceil/floor interplay)
        (uint256 tokenAmount2, bool ok3) = money.previewBuy(weiReq);
        assertTrue(ok3);
        assertGe(tokenAmount2, tokenAmount);
    }

    // New test per proposal #135: ensure failing recipient leaves queue intact
    function testExecuteWithdrawalRecipientRevertsLeavesQueueIntact() public {
        uint256 amount = 1 ether;
        // deploy a recipient that rejects ETH
        RejectingRecipient rr = new RejectingRecipient();
        address recipient = address(rr);

        // record contract balance before queuing
        uint256 contractBalBefore = address(money).balance;
        assertGe(contractBalBefore, amount);

        // owner queues a withdrawal to the rejecting recipient
        vm.prank(owner);
        money.queueWithdrawalTo(recipient, amount);

        uint256 queuedAmountBefore = money.queuedAmount();
        uint256 queuedExecuteTimeBefore = money.queuedExecuteTime();
        address queuedRecipientBefore = money.queuedRecipient();

        // advance to after the timelock
        vm.warp(queuedExecuteTimeBefore + 1);

        // executing the withdrawal should revert with Transfer failed
        vm.expectRevert(bytes("Transfer failed"));
        money.executeWithdrawal();

        // queued state must remain unchanged
        assertEq(money.queuedAmount(), queuedAmountBefore);
        assertEq(money.queuedExecuteTime(), queuedExecuteTimeBefore);
        assertEq(money.queuedRecipient(), queuedRecipientBefore);

        // contract balance should be unchanged
        assertEq(address(money).balance, contractBalBefore);

        // owner can cancel the queued withdrawal afterwards
        vm.prank(owner);
        money.cancelQueuedWithdrawal();

        // queued state is cleared
        assertEq(money.queuedAmount(), 0);
        assertEq(money.queuedExecuteTime(), 0);
        assertEq(money.queuedRecipient(), address(0));

        // contract balance still unchanged
        assertEq(address(money).balance, contractBalBefore);
    }

    // Tests added per approved proposal #137: assert pause blocks user paths but owner cancels remain callable
    function testPauseBlocksBuyAndQueueWithdrawal() public {
        uint256 rate = 1;
        uint256 sendWei = 1 ether / 1000; // 0.001 ETH

        // owner sets a non-zero rate
        vm.prank(owner);
        money.setRate(rate);

        // fund alice
        vm.deal(alice, sendWei);

        // owner pauses the contract
        vm.prank(owner);
        money.pause();

        // while paused, buy should revert for a buyer
        vm.prank(alice);
        vm.expectRevert();
        money.buy{value: sendWei}();

        // while paused, owner queueWithdrawal and queueWithdrawalTo should revert
        vm.prank(owner);
        vm.expectRevert();
        money.queueWithdrawal(1 ether);

        vm.prank(owner);
        vm.expectRevert();
        money.queueWithdrawalTo(alice, 1 ether);

        // owner unpauses
        vm.prank(owner);
        money.unpause();

        // now buy succeeds
        vm.prank(alice);
        money.buy{value: sendWei}();
        uint256 expected = (sendWei * rate * (10 ** money.decimals())) / 1 ether;
        assertEq(money.balanceOf(alice), expected);

        // and owner can queue a withdrawal
        vm.prank(owner);
        money.queueWithdrawal(1 ether);
        assertEq(money.queuedAmount(), 1 ether);

        // cleanup
        vm.prank(owner);
        money.cancelQueuedWithdrawal();
    }

    function testOwnerCanCancelQueuedWithdrawalWhilePaused() public {
        // owner queues a withdrawal
        vm.prank(owner);
        money.queueWithdrawal(1 ether);
        assertEq(money.queuedAmount(), 1 ether);

        // owner pauses the contract
        vm.prank(owner);
        money.pause();

        // owner must still be able to cancel the queued withdrawal while paused
        vm.prank(owner);
        money.cancelQueuedWithdrawal();
        assertEq(money.queuedAmount(), 0);
        assertEq(money.queuedExecuteTime(), 0);
        assertEq(money.queuedRecipient(), address(0));
    }

    function testOwnerCanCancelQueuedEnableRescueWhilePaused() public {
        // queue the rescue-to-zero opt-in as owner
        vm.prank(owner);
        money.queueEnableRescueToZero();
        assertGt(money.queuedRescueToZeroExecuteTime(), 0);

        // owner pauses the contract
        vm.prank(owner);
        money.pause();

        // owner should still be able to cancel the queued enable while paused
        vm.prank(owner);
        money.cancelQueuedEnableRescueToZero();
        assertEq(money.queuedRescueToZeroExecuteTime(), 0);
    }
}
