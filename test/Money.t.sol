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
        uint256 sendWei = 1 ether / 1000;
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

        vm.prank(owner);
        vm.expectRevert(bytes("Timelock not expired"));
        money.executeWithdrawal();

        vm.warp(block.timestamp + 48 hours + 1);

        uint256 ownerBefore = owner.balance;
        vm.prank(owner);
        money.executeWithdrawal();
        assertGt(owner.balance, ownerBefore);

        assertEq(money.queuedRecipient(), address(0));
    }

    function testPauseBlocksBuyAndWithdraw() public {
        uint256 sendWei = 1 ether / 1000;
        uint256 rate = 1;
        vm.deal(alice, sendWei);

        vm.prank(owner);
        money.pause();

        vm.prank(alice);
        vm.expectRevert();
        money.buy{value: sendWei}();

        vm.prank(owner);
        vm.expectRevert();
        money.queueWithdrawal(1 ether);

        vm.prank(owner);
        money.unpause();

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

        vm.expectRevert(bytes("No queued withdrawal"));
        money.executeWithdrawal();
    }

    function testOwnerCanCancelQueuedWithdrawal() public {
        uint256 amount = 1 ether;
        vm.prank(owner);
        money.queueWithdrawal(amount);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit WithdrawalCancelled(amount);
        vm.prank(owner);
        money.cancelQueuedWithdrawal();

        assertEq(money.queuedAmount(), 0);
        assertEq(money.queuedExecuteTime(), 0);
        assertEq(money.queuedRecipient(), address(0));

        vm.prank(owner);
        vm.expectRevert(bytes("No queued withdrawal"));
        money.executeWithdrawal();
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

    function testRescueERC20RejectsZeroRecipient() public {
        SimpleERC20 token = new SimpleERC20("TKN2", "TKN2");
        token.mint(address(money), 500);

        vm.prank(owner);
        vm.expectRevert(bytes("Recipient zero"));
        money.rescueERC20(token, address(0), 500);

        // ensure tokens remain in the contract
        assertEq(token.balanceOf(address(money)), 500);
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

    function testSetRateOnlyOwnerAndBuyRevertsWhenZero() public {
        uint256 rate = 3;
        vm.prank(alice);
        vm.expectRevert();
        money.setRate(rate);

        uint256 sendWei = 1 ether / 1000;
        vm.deal(alice, sendWei);
        vm.prank(alice);
        vm.expectRevert(bytes("Rate must be > 0"));
        money.buy{value: sendWei}();

        vm.prank(owner);
        money.setRate(rate);
        vm.prank(alice);
        money.buy{value: sendWei}();
        assertEq(money.balanceOf(alice), (sendWei * rate * (10 ** money.decimals())) / 1 ether);
    }

    function testSetRateAboveMaxReverts() public {
        vm.prank(owner);
        vm.expectRevert(bytes("Rate out of range"));
        money.setRate(Money.MAX_RATE() + 1);
    }

    function testSetRateAtMaxAndBuy() public {
        uint256 sendWei = 1 ether / 1000;
        vm.deal(alice, sendWei);

        vm.prank(owner);
        money.setRate(Money.MAX_RATE());

        vm.prank(alice);
        money.buy{value: sendWei}();

        uint256 expected = (sendWei * Money.MAX_RATE() * (10 ** money.decimals())) / 1 ether;
        assertEq(money.balanceOf(alice), expected);
    }

    function testBuyRevertsOnExcessiveWei() public {
        vm.prank(owner);
        money.setRate(Money.MAX_RATE());

        uint256 maxMsgValue = type(uint256).max / Money.MAX_RATE() / (10 ** money.decimals());
        uint256 excessive = maxMsgValue + 1;

        vm.deal(alice, excessive);

        vm.prank(alice);
        vm.expectRevert(bytes("msg.value too large"));
        money.buy{value: excessive}();
    }

    function testCannotOverwriteQueuedWithdrawal() public {
        uint256 amount = 1 ether;
        vm.prank(owner);
        money.queueWithdrawal(amount);

        vm.prank(owner);
        vm.expectRevert(bytes("Existing queued withdrawal"));
        money.queueWithdrawal(amount);
    }
}
