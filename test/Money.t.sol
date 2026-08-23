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
        // rate = 2 tokens per ETH
        uint256 rate = 2;
        uint256 sendWei = 1 ether / 1000; // 0.001 ETH
        vm.deal(alice, sendWei);

        // owner sets rate
        vm.prank(owner);
        money.setRate(rate);

        vm.prank(alice);
        money.buy{value: sendWei}();

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

        // queued recipient should be locked to the owner at queue time
        assertEq(money.queuedRecipient(), owner);

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

        // queued recipient should be cleared after execution
        assertEq(money.queuedRecipient(), address(0));
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
        money.buy{value: sendWei}();

        vm.prank(owner);
        vm.expectRevert();
        money.queueWithdrawal(1 ether);

        // unpause and ensure buy works
        vm.prank(owner);
        money.unpause();

        // owner sets rate
        vm.prank(owner);
        money.setRate(rate);

        vm.prank(alice);
        money.buy{value: sendWei}();
        assertEq(money.balanceOf(alice), (sendWei * rate * (10 ** money.decimals())) / 1 ether);
    }

    function testOnlyOwnerAccess() public {
        vm.expectRevert();
        money.pause();

        vm.expectRevert();
        money.unpause();

        vm.expectRevert();
        money.queueWithdrawal(1 ether);

        // executeWithdrawal is now publicly callable but should revert with "No queued withdrawal" when none is queued
        vm.expectRevert(bytes("No queued withdrawal"));
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
        assertEq(money.queuedRecipient(), address(0));

        // execute should revert with "No queued withdrawal" after cancellation
        vm.prank(owner);
        vm.expectRevert(bytes("No queued withdrawal"));
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

    function testRescueERC20RejectsZeroRecipient() public {
        // deploy a simple ERC20 and mint tokens to the Money contract
        SimpleERC20 token = new SimpleERC20("TKN", "TKN");
        token.mint(address(money), 1000);

        // owner attempts to rescue to zero address and should revert before any external transfer
        vm.prank(owner);
        vm.expectRevert(bytes("Recipient zero"));
        money.rescueERC20(IERC20(address(token)), address(0), 1000);

        // ensure tokens remain in the Money contract
        assertEq(token.balanceOf(address(money)), 1000);
    }

    function testRescueERC20CannotSweepMoney() public {
        // attempt to sweep the Money token should revert
        vm.prank(owner);
        vm.expectRevert(bytes("Cannot sweep Money token"));
        money.rescueERC20(IERC20(address(money)), owner, 1);
    }

    function testRescueNonStandardERC20Successful() public {
        // deploy a non-standard ERC20 (transfer without bool) and mint into Money
        NonStandardERC20 token = new NonStandardERC20();
        token.mint(address(money), 500);

        // owner rescues tokens
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Money.ERC20Rescued(address(token), owner, 500);
        vm.prank(owner);
        // note: Money.rescueERC20 accepts IERC20, but SafeERC20 operates on the interface; calling with this contract address works
        money.rescueERC20(IERC20(address(token)), owner, 500);

        // verify balances on the non-standard token
        // since NonStandardERC20 exposes balanceOf, we can check
        assertEq(token.balanceOf(owner), 500);
        assertEq(token.balanceOf(address(money)), 0);
    }

    function testRescueNonStandardERC20RejectsZeroRecipient() public {
        // deploy a non-standard ERC20 and mint into Money
        NonStandardERC20 token = new NonStandardERC20();
        token.mint(address(money), 500);

        // owner attempts to rescue to zero address and should revert before any external transfer
        vm.prank(owner);
        vm.expectRevert(bytes("Recipient zero"));
        money.rescueERC20(IERC20(address(token)), address(0), 500);

        // ensure tokens remain in the Money contract
        assertEq(token.balanceOf(address(money)), 500);
    }

    function testSetRateOnlyOwnerAndBuyRevertsWhenZero() public {
        uint256 rate = 3;
        // non-owner cannot set rate
        vm.prank(alice);
        vm.expectRevert();
        money.setRate(rate);

        // buy reverts when rate is zero
        uint256 sendWei = 1 ether / 1000;
        vm.deal(alice, sendWei);
        vm.prank(alice);
        vm.expectRevert(bytes("Rate must be > 0"));
        money.buy{value: sendWei}();

        // owner sets a valid rate and buy succeeds
        vm.prank(owner);
        money.setRate(rate);
        vm.prank(alice);
        money.buy{value: sendWei}();
        assertEq(money.balanceOf(alice), (sendWei * rate * (10 ** money.decimals())) / 1 ether);
    }

    // New test: setting rate above MAX_RATE should revert
    function testSetRateAboveMaxReverts() public {
        vm.prank(owner);
        vm.expectRevert(bytes("Rate out of range"));
        money.setRate(Money.MAX_RATE() + 1);
    }

    // Optional test: setting MAX_RATE succeeds and buy still works for a small msg.value
    function testSetRateAtMaxAndBuy() public {
        uint256 sendWei = 1 ether / 1000; // small amount so tokenAmount won't overflow
        vm.deal(alice, sendWei);

        vm.prank(owner);
        money.setRate(Money.MAX_RATE());

        vm.prank(alice);
        money.buy{value: sendWei}();

        uint256 expected = (sendWei * Money.MAX_RATE() * (10 ** money.decimals())) / 1 ether;
        assertEq(money.balanceOf(alice), expected);
    }

    // New test: buy reverts when msg.value exceeds the conservative MAX_RATE-based guard
    function testBuyRevertsOnExcessiveWei() public {
        // set rate to MAX_RATE to exercise the conservative guard
        vm.prank(owner);
        money.setRate(Money.MAX_RATE());

        uint256 maxMsgValue = type(uint256).max / Money.MAX_RATE() / (10 ** money.decimals());
        uint256 excessive = maxMsgValue + 1;

        // fund alice with the excessive amount
        vm.deal(alice, excessive);

        vm.prank(alice);
        vm.expectRevert(bytes("msg.value too large"));
        money.buy{value: excessive}();
    }

    // New test: cannot overwrite an existing queued withdrawal
    function testCannotOverwriteQueuedWithdrawal() public {
        uint256 amount = 1 ether;
        vm.prank(owner);
        money.queueWithdrawal(amount);

        // attempting to queue another withdrawal should revert with the explicit message
        vm.prank(owner);
        vm.expectRevert(bytes("Existing queued withdrawal"));
        money.queueWithdrawal(amount);
    }

    // New test: ensure executeWithdrawal preserves queued state when recipient reverts
    function testExecuteWithdrawalToRevertingRecipientPreservesQueuedState() public {
        // deploy a BadRecipient and have it deploy a Money instance so the contract is the owner
        BadRecipient bad = new BadRecipient();
        Money money2 = bad.deployMoney();

        uint256 amount = 1 ether;
        // queue the withdrawal from the BadRecipient's context (so queuedRecipient will be address(bad))
        bad.callQueueWithdrawalTo(money2, address(bad), amount);

        // capture queued state after queueing
        uint256 qAmount = money2.queuedAmount();
        uint256 qExecuteTime = money2.queuedExecuteTime();
        address qRecipient = money2.queuedRecipient();

        assertEq(qAmount, amount);
        assertEq(qRecipient, address(bad));

        // advance time past the timelock
        vm.warp(block.timestamp + 48 hours + 1);

        // executeWithdrawal should revert with the explicit "Transfer failed" and the on-chain queued state must be unchanged
        vm.expectRevert(bytes("Transfer failed"));
        money2.executeWithdrawal();

        // because the call reverted, storage must be unchanged (revert rolled back the attempted clear)
        assertEq(money2.queuedAmount(), qAmount);
        assertEq(money2.queuedExecuteTime(), qExecuteTime);
        assertEq(money2.queuedRecipient(), qRecipient);
    }

    // New tests: verify Deposit event is emitted when contract receives ETH via receive() and fallback()
    function testEmitDepositOnReceive() public {
        uint256 amt = 1 ether / 2; // 0.5 ETH
        address sender = address(0xC0FFEE);
        vm.deal(sender, amt);

        vm.prank(sender);
        vm.expectEmit(true, false, false, true);
        emit Money.Deposit(sender, amt);

        // send ETH with empty calldata to trigger receive()
        payable(address(money)).transfer(amt);

        // contract balance should increase by amt (setUp funded 5 ether initially)
        assertEq(address(money).balance, 5 ether + amt);
    }

    function testEmitDepositOnFallback() public {
        uint256 amt = 1 ether / 4; // 0.25 ETH
        address sender = address(0xD00D);
        vm.deal(sender, amt);

        vm.prank(sender);
        vm.expectEmit(true, false, false, true);
        emit Money.Deposit(sender, amt);

        // send ETH with non-empty calldata to trigger fallback()
        (bool ok, ) = address(money).call{value: amt}(hex"1234");
        require(ok, "call failed");

        assertEq(address(money).balance, 5 ether + amt);
    }

    // New tests for previewBuy
    function testPreviewBuyMatchesBuyStateNeutral() public {
        uint256 rate = 2;
        uint256 sendWei = 1 ether / 1000;

        // set rate
        vm.prank(owner);
        money.setRate(rate);

        // preview from test contract should not change any state
        (uint256 tokenAmount, bool wouldSucceed) = money.previewBuy(sendWei);
        uint256 expected = (sendWei * rate * (10 ** money.decimals())) / 1 ether;
        assertTrue(wouldSucceed);
        assertEq(tokenAmount, expected);
        // preview did not mint
        assertEq(money.totalSupply(), 0);

        // performing an actual buy mints the expected amount
        vm.deal(alice, sendWei);
        vm.prank(alice);
        money.buy{value: sendWei}();
        assertEq(money.balanceOf(alice), expected);
    }

    function testPreviewBuyReturnsFalseWhenRateZero() public {
        uint256 sendWei = 1 ether / 1000;
        (uint256 tokenAmount, bool wouldSucceed) = money.previewBuy(sendWei);
        assertFalse(wouldSucceed);
        assertEq(tokenAmount, 0);
    }

    function testPreviewBuyReturnsFalseOnExcessiveWei() public {
        vm.prank(owner);
        money.setRate(Money.MAX_RATE());

        uint256 maxMsgValue = type(uint256).max / Money.MAX_RATE() / (10 ** money.decimals());
        uint256 excessive = maxMsgValue + 1;

        (uint256 tokenAmount, bool wouldSucceed) = money.previewBuy(excessive);
        assertFalse(wouldSucceed);
        assertEq(tokenAmount, 0);
    }
}
