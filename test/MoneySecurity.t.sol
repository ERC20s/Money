// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../contracts/Money.sol";

/// @dev Recipient that tries to re-enter executeWithdrawal() while it is being paid. It records
/// the outcome of the inner call instead of reverting, so the test can assert the exact reason
/// the re-entry was refused and that the outer withdrawal still paid exactly once.
contract ReenteringRecipient {
    Money public money;
    bool public innerOk;
    bytes public innerRevertData;
    uint256 public timesPaid;

    constructor(Money m) {
        money = m;
    }

    receive() external payable {
        timesPaid += 1;
        (bool ok, bytes memory data) = address(money).call(abi.encodeWithSignature("executeWithdrawal()"));
        innerOk = ok;
        innerRevertData = data;
    }
}

contract MoneySecurityTest is Test {
    Money money;
    address owner = address(0xABCD);
    address alice = address(0xBEEF);

    // Mirrors of Money's events for vm.expectEmit (qualified `emit Money.X` needs solc >= 0.8.21).
    event Deposit(address indexed from, uint256 amount);
    event WithdrawalExecuted(uint256 amount, address indexed recipient);

    uint256 constant TOKEN_UNIT = 1e6; // 10 ** decimals()

    function setUp() public {
        vm.prank(owner);
        money = new Money();
    }

    // ---------------------------------------------------------------- pricing maths

    function _expectedTokens(uint256 weiAmount, uint256 rate) internal pure returns (uint256) {
        // independent oracle of the contract's normalisation: wei * (tokens per ETH) * 10**decimals / 1 ETH
        return (weiAmount * rate * TOKEN_UNIT) / 1 ether;
    }

    function testBuyRejectsZeroValue() public {
        vm.prank(owner);
        money.setRate(1);

        vm.prank(alice);
        vm.expectRevert(bytes("Must send ETH to buy"));
        money.buy{value: 0}();

        vm.prank(alice);
        vm.expectRevert(bytes("Must send ETH to buy"));
        money.buyTo{value: 0}(alice);

        assertEq(money.totalSupply(), 0);
    }

    function testBuyRejectsValueAboveOverflowBound() public {
        vm.prank(owner);
        money.setRate(1);

        uint256 maxMsgValue = type(uint256).max / money.MAX_RATE() / TOKEN_UNIT;
        vm.deal(alice, maxMsgValue + 1);

        vm.prank(alice);
        vm.expectRevert(bytes("msg.value too large"));
        money.buy{value: maxMsgValue + 1}();

        assertEq(money.balanceOf(alice), 0);
        assertEq(address(money).balance, 0);
    }

    function testBuyAtExactOverflowBoundSucceeds() public {
        uint256 maxRate = money.MAX_RATE();
        vm.prank(owner);
        money.setRate(maxRate);

        uint256 maxMsgValue = type(uint256).max / maxRate / TOKEN_UNIT;
        vm.deal(alice, maxMsgValue);

        vm.prank(alice);
        money.buy{value: maxMsgValue}();

        // the worst-case product rate * 10**decimals * msg.value fits in uint256 by construction
        assertEq(money.balanceOf(alice), _expectedTokens(maxMsgValue, maxRate));
    }

    function testBuyDustBelowOneTokenUnitReverts() public {
        // at rate 1, one token unit (1e-6 MNY) costs exactly 1e12 wei
        vm.prank(owner);
        money.setRate(1);

        vm.deal(alice, 1e12);

        vm.prank(alice);
        vm.expectRevert(bytes("Token amount zero after normalization"));
        money.buy{value: 1e12 - 1}();

        vm.prank(alice);
        money.buy{value: 1e12}();
        assertEq(money.balanceOf(alice), 1);
    }

    function testBuyRoundsDownAndKeepsTheDust() public {
        vm.prank(owner);
        money.setRate(1);

        // 1.5 token units' worth of wei mints 1 unit; the half unit of wei stays in the contract
        uint256 sendWei = 15e11;
        vm.deal(alice, sendWei);

        vm.prank(alice);
        money.buy{value: sendWei}();

        assertEq(money.balanceOf(alice), 1);
        assertEq(address(money).balance, sendWei);
    }

    /// Fuzz: for every rate in range and every affordable msg.value, buy() mints exactly the
    /// floor of wei * rate * 10**decimals / 1 ETH, the contract keeps every wei sent, and dust
    /// (anything below one token unit) reverts instead of minting zero.
    function testFuzz_BuyMintsFloorOfFormula(uint256 rate, uint256 weiAmount) public {
        rate = bound(rate, 1, money.MAX_RATE());
        weiAmount = bound(weiAmount, 1, 1_000_000 ether);

        vm.prank(owner);
        money.setRate(rate);
        vm.deal(alice, weiAmount);

        uint256 expected = _expectedTokens(weiAmount, rate);
        (uint256 previewed, bool ok) = money.previewBuy(weiAmount);

        if (expected == 0) {
            assertFalse(ok);
            assertEq(previewed, 0);
            vm.prank(alice);
            vm.expectRevert(bytes("Token amount zero after normalization"));
            money.buy{value: weiAmount}();
            assertEq(money.totalSupply(), 0);
            return;
        }

        assertTrue(ok);
        assertEq(previewed, expected);

        vm.prank(alice);
        money.buy{value: weiAmount}();

        assertEq(money.balanceOf(alice), expected);
        assertEq(money.totalSupply(), expected);
        assertEq(address(money).balance, weiAmount);

        // floor bounds: the buyer never receives more than they paid for, and is short by less
        // than one token unit
        uint256 paidFor = weiAmount * rate * TOKEN_UNIT;
        assertLe(expected * 1 ether, paidFor);
        assertGt((expected + 1) * 1 ether, paidFor);
    }

    /// Fuzz: previewWeiForTokens returns the smallest wei amount that mints at least the
    /// requested units: that amount buys >= tokenUnits, and one wei less buys fewer.
    function testFuzz_PreviewWeiForTokensIsMinimal(uint256 rate, uint256 tokenUnits) public {
        rate = bound(rate, 1, money.MAX_RATE());
        tokenUnits = bound(tokenUnits, 1, 1e18);

        vm.prank(owner);
        money.setRate(rate);

        (uint256 weiReq, bool ok) = money.previewWeiForTokens(tokenUnits);
        assertTrue(ok);
        assertGt(weiReq, 0);

        vm.deal(alice, weiReq);
        vm.prank(alice);
        money.buy{value: weiReq}(tokenUnits);
        assertGe(money.balanceOf(alice), tokenUnits);

        if (weiReq > 1) {
            (uint256 fewer, ) = money.previewBuy(weiReq - 1);
            assertLt(fewer, tokenUnits);
        }
    }

    /// Fuzz: buyTo credits the recipient, never the payer, with the same amount buy() would mint.
    function testFuzz_BuyToMintsSameAmountToRecipient(uint256 rate, uint256 weiAmount, address recipient) public {
        rate = bound(rate, 1, money.MAX_RATE());
        weiAmount = bound(weiAmount, 1e12, 1_000_000 ether); // >= one token unit at rate 1
        vm.assume(recipient != address(0) && recipient != alice);

        vm.prank(owner);
        money.setRate(rate);
        vm.deal(alice, weiAmount);

        vm.prank(alice);
        money.buyTo{value: weiAmount}(recipient);

        uint256 expected = _expectedTokens(weiAmount, rate);
        assertEq(money.balanceOf(recipient), expected);
        assertEq(money.balanceOf(alice), 0);
        assertEq(money.totalSupply(), expected);
    }

    // ---------------------------------------------------------------- withdrawals

    function testExecuteWithdrawalPaysRecipientAndClearsState() public {
        vm.deal(address(money), 5 ether);
        uint256 amount = 2 ether;

        vm.prank(owner);
        money.queueWithdrawal(amount);
        vm.warp(block.timestamp + money.TIMELOCK());

        uint256 ownerBefore = owner.balance;

        vm.expectEmit(true, false, false, true);
        emit WithdrawalExecuted(amount, owner);
        vm.prank(alice); // permissionless once the timelock has elapsed
        money.executeWithdrawal();

        assertEq(owner.balance, ownerBefore + amount);
        assertEq(address(money).balance, 3 ether);
        assertEq(money.queuedAmount(), 0);
        assertEq(money.queuedExecuteTime(), 0);
        assertEq(money.queuedRecipient(), address(0));
    }

    function testExecuteWithdrawalOneSecondEarlyReverts() public {
        vm.deal(address(money), 1 ether);
        vm.prank(owner);
        money.queueWithdrawal(1 ether);

        vm.warp(money.queuedExecuteTime() - 1);
        vm.expectRevert(bytes("Timelock not expired"));
        money.executeWithdrawal();
        assertEq(money.timeUntilQueuedWithdrawal(), 1);
    }

    function testExecuteWithdrawalReentryIsRefusedAndPaysOnce() public {
        vm.deal(address(money), 5 ether);
        ReenteringRecipient attacker = new ReenteringRecipient(money);
        uint256 amount = 1 ether;

        vm.prank(owner);
        money.queueWithdrawalTo(address(attacker), amount);
        vm.warp(block.timestamp + money.TIMELOCK());

        money.executeWithdrawal();

        // the inner executeWithdrawal() was refused by the reentrancy guard, not by anything else
        assertFalse(attacker.innerOk());
        assertEq(attacker.innerRevertData(), abi.encodeWithSignature("Error(string)", "ReentrancyGuard: reentrant call"));

        // exactly one payment of exactly `amount`
        assertEq(attacker.timesPaid(), 1);
        assertEq(address(attacker).balance, amount);
        assertEq(address(money).balance, 4 ether);
        assertEq(money.queuedAmount(), 0);
        assertEq(money.queuedRecipient(), address(0));
    }

    function testQueueWithdrawalRejectsMoreThanBalance() public {
        vm.deal(address(money), 1 ether);
        vm.prank(owner);
        vm.expectRevert(bytes("Not enough balance"));
        money.queueWithdrawal(1 ether + 1);
    }

    // ---------------------------------------------------------------- ownership

    function testRenounceOwnershipRevertsForEveryone() public {
        vm.prank(owner);
        vm.expectRevert(bytes("Ownership cannot be renounced"));
        money.renounceOwnership();

        vm.prank(alice);
        vm.expectRevert(bytes("Ownership cannot be renounced"));
        money.renounceOwnership();

        assertEq(money.owner(), owner);
    }

    function testAcceptOwnershipWithoutNominationReverts() public {
        vm.prank(alice);
        vm.expectRevert(bytes("Ownable2Step: caller is not the new owner"));
        money.acceptOwnership();
        assertEq(money.owner(), owner);
    }

    // ---------------------------------------------------------------- plain ETH

    /// A call with ETH and a selector no function matches lands in fallback(), which accepts
    /// the ETH and logs a Deposit, exactly like receive() does for an empty-calldata send.
    function testFallbackWithCalldataAcceptsEthAndEmitsDeposit() public {
        vm.deal(alice, 1 ether);

        vm.expectEmit(true, false, false, true);
        emit Deposit(alice, 1 ether);
        vm.prank(alice);
        (bool ok, ) = address(money).call{value: 1 ether}(hex"deadbeef");

        assertTrue(ok);
        assertEq(address(money).balance, 1 ether);
        assertEq(money.totalSupply(), 0); // a plain send mints nothing
    }
}
