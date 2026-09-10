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

    // New: contractStatus view returns a bundle of public read values matching internal state
    function testContractStatusReflectsStateTransitions() public {
        // initial state: rate == 0, rescueToZeroEnabled == false, queued amounts zero
        (
            uint256 r0,
            uint8 d0,
            uint256 bal0,
            bool rescue0,
            uint256 qAmount0,
            uint256 qExec0,
            address qRecipient0,
            uint256 qRescueExec0,
            uint256 maxSafe0
        ) = money.contractStatus();

        assertEq(r0, 0);
        assertEq(d0, money.decimals());
        assertEq(bal0, address(money).balance);
        assertFalse(rescue0);
        assertEq(qAmount0, 0);
        assertEq(qExec0, 0);
        assertEq(qRecipient0, address(0));
        assertEq(qRescueExec0, 0);
        assertGt(maxSafe0, 0);

        // set rate
        vm.prank(owner);
        money.setRate(5);

        // queue withdrawal
        vm.prank(owner);
        money.queueWithdrawal(1 ether);

        // queue rescue enable
        vm.prank(owner);
        money.queueEnableRescueToZero();

        // check status after changes
        (
            uint256 r1,
            uint8 d1,
            uint256 bal1,
            bool rescue1,
            uint256 qAmount1,
            uint256 qExec1,
            address qRecipient1,
            uint256 qRescueExec1,
            uint256 maxSafe1
        ) = money.contractStatus();

        assertEq(r1, 5);
        assertEq(d1, money.decimals());
        assertEq(bal1, address(money).balance);
        assertFalse(rescue1); // not yet executed
        assertEq(qAmount1, 1 ether);
        assertEq(qRecipient1, owner);
        assertGt(qExec1, 0);
        assertGt(qRescueExec1, 0);
        assertGt(maxSafe1, 0);

        // advance past timelocks and ensure execute flips rescue flag and executeWithdrawal succeeds
        vm.warp(block.timestamp + 48 hours + 1);

        // execute enable rescue
        money.executeEnableRescueToZero();
        // execute withdrawal
        vm.prank(owner);
        money.executeWithdrawal();

        (
            uint256 r2,
            uint8 d2,
            uint256 bal2,
            bool rescue2,
            uint256 qAmount2,
            uint256 qExec2,
            address qRecipient2,
            uint256 qRescueExec2,
            uint256 maxSafe2
        ) = money.contractStatus();

        assertEq(r2, 5);
        assertEq(d2, money.decimals());
        assertEq(bal2, address(money).balance);
        assertTrue(rescue2);
        assertEq(qAmount2, 0);
        assertEq(qExec2, 0);
        assertEq(qRecipient2, address(0));
        assertEq(qRescueExec2, 0);
        assertGt(maxSafe2, 0);
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

    // New test per approved proposal #143: ensure previewBuy rejects inputs that would overflow
    function testPreviewBuyRejectsOverflow() public {
        // set a non-zero rate so previewBuy proceeds past the rate==0 check
        vm.prank(owner);
        money.setRate(1);

        // compute the conservative max msg.value the contract uses to avoid overflow
        uint256 tokenDecimalsFactor = 10 ** uint256(money.decimals());
        uint256 maxMsgValue = type(uint256).max / money.MAX_RATE() / tokenDecimalsFactor;

        // ask for one more than the safe bound and expect previewBuy to report failure
        uint256 probe = maxMsgValue + 1;
        (uint256 tokenAmount, bool ok) = money.previewBuy(probe);
        assertFalse(ok, "previewBuy should reject overflow inputs");
        assertEq(tokenAmount, 0, "tokenAmount must be zero on failure");
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

    // Tests for approved proposal #147: ownerMint behaviour
    function testOwnerMintOnlyOwnerAndEffects() public {
        uint256 amount = 100 * (10 ** money.decimals());

        // non-owner cannot call ownerMint
        vm.prank(alice);
        vm.expectRevert();
        money.ownerMint(alice, amount);

        // zero recipient rejected
        vm.prank(owner);
        vm.expectRevert(bytes("Recipient zero"));
        money.ownerMint(address(0), amount);

        // zero amount rejected
        vm.prank(owner);
        vm.expectRevert(bytes("Amount must be >0"));
        money.ownerMint(alice, 0);

        // owner may mint to alice
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Money.Minted(alice, amount);
        vm.prank(owner);
        money.ownerMint(alice, amount);

        assertEq(money.balanceOf(alice), amount);
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

    // Tests for two-step ownership handover and access control per proposal #141
    function testOwnershipNominationDoesNotTransferRights() public {
        address nominee = address(0xC0FFEE);

        // owner nominates nominee
        vm.prank(owner);
        money.transferOwnership(nominee);

        // pending owner should be recorded
        assertEq(money.pendingOwner(), nominee);

        // nominee must NOT be able to call owner-only functions yet
        vm.prank(nominee);
        vm.expectRevert();
        money.setRate(1);

        vm.prank(nominee);
        vm.expectRevert();
        money.queueWithdrawal(1 ether);

        vm.prank(nominee);
        vm.expectRevert();
        money.pause();

        // current owner retains owner powers
        vm.prank(owner);
        money.setRate(2);

        vm.prank(owner);
        money.pause();

        vm.prank(owner);
        money.unpause();
    }

    function testAcceptOwnershipTransfersRights() public {
        address nominee = address(0xC0FFEE);

        // nominate
        vm.prank(owner);
        money.transferOwnership(nominee);

        // nominee accepts
        vm.prank(nominee);
        money.acceptOwnership();

        // nominee is now owner and may call owner-only functions
        vm.prank(nominee);
        money.setRate(3);

        vm.prank(nominee);
        money.pause();

        // previous owner has lost owner privileges
        vm.prank(owner);
        vm.expectRevert();
        money.setRate(4);

        // cleanup: new owner unpauses
        vm.prank(nominee);
        money.unpause();
    }

    function testTransferOwnershipZeroCancelsPending() public {
        address nominee = address(0xDEADBE);

        vm.prank(owner);
        money.transferOwnership(nominee);
        assertEq(money.pendingOwner(), nominee);

        // cancel nomination
        vm.prank(owner);
        money.transferOwnership(address(0));
        assertEq(money.pendingOwner(), address(0));

        // nominee cannot accept anymore
        vm.prank(nominee);
        vm.expectRevert();
        money.acceptOwnership();
    }

    function testSecondTransferReplacesPending() public {
        address nominee1 = address(0xAAAA);
        address nominee2 = address(0xBBBB);

        vm.prank(owner);
        money.transferOwnership(nominee1);
        assertEq(money.pendingOwner(), nominee1);

        // new nomination replaces the earlier one
        vm.prank(owner);
        money.transferOwnership(nominee2);
        assertEq(money.pendingOwner(), nominee2);

        // old nominee cannot accept
        vm.prank(nominee1);
        vm.expectRevert();
        money.acceptOwnership();

        // new nominee can accept and becomes owner
        vm.prank(nominee2);
        money.acceptOwnership();

        vm.prank(nominee2);
        money.setRate(5);
    }

    // New test per approved proposal #145: ensure buy(minTokenAmount) reverts when owner reduces rate between preview and buy
    function testBuyRevertsWhenRateDropsBetweenPreviewAndBuy() public {
        uint256 highRate = 10;
        uint256 lowRate = 1;
        uint256 weiAmount = 1 ether / 1000; // 0.001 ETH

        // fund alice so the buy can be attempted
        vm.deal(alice, weiAmount);

        // owner sets a high rate and alice computes a quote
        vm.prank(owner);
        money.setRate(highRate);

        (uint256 tokenAmount, bool ok) = money.previewBuy(weiAmount);
        assertTrue(ok, "previewBuy should succeed");
        assertGt(tokenAmount, 0, "preview must return a non-zero token amount");

        // owner lowers the rate before alice submits the buy
        vm.prank(owner);
        money.setRate(lowRate);

        // alice attempts to buy insisting on at least the quoted amount and must be protected
        vm.prank(alice);
        vm.expectRevert(bytes("Insufficient tokens out"));
        money.buy{value: weiAmount}(tokenAmount);
    }

    // New tests for approved proposal #149: buyTo behaviour
    function testBuyToCreditsRecipient() public {
        uint256 rate = 7;
        uint256 weiAmount = 1 ether / 1000; // 0.001 ETH

        // fund alice (payer)
        vm.deal(alice, weiAmount);

        // set rate as owner
        vm.prank(owner);
        money.setRate(rate);

        address recipient = address(0xB0B);

        // alice buys for recipient
        vm.prank(alice);
        money.buyTo{value: weiAmount}(recipient);

        uint256 expected = (weiAmount * rate * (10 ** money.decimals())) / 1 ether;
        assertEq(money.balanceOf(recipient), expected);
        // buyer should not receive tokens
        assertEq(money.balanceOf(alice), 0);
    }

    function testBuyToRevertsWhenRateDropsBetweenPreviewAndBuy() public {
        uint256 highRate = 10;
        uint256 lowRate = 1;
        uint256 weiAmount = 1 ether / 1000; // 0.001 ETH

        // fund alice so the buy can be attempted
        vm.deal(alice, weiAmount);

        // owner sets a high rate and alice computes a quote
        vm.prank(owner);
        money.setRate(highRate);

        (uint256 tokenAmount, bool ok) = money.previewBuy(weiAmount);
        assertTrue(ok, "previewBuy should succeed");
        assertGt(tokenAmount, 0, "preview must return a non-zero token amount");

        // owner lowers the rate before alice submits the buy
        vm.prank(owner);
        money.setRate(lowRate);

        // alice attempts to buy insisting on at least the quoted amount and must be protected
        address recipient = address(0xD0D);
        vm.prank(alice);
        vm.expectRevert(bytes("Insufficient tokens out"));
        money.buyTo{value: weiAmount}(recipient, tokenAmount);
    }
}
