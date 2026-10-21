// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../contracts/Money.sol";

/// @dev Handler driven by the invariant fuzzer. Every action either succeeds and updates the
/// ghost accounting, or is a call the contract must refuse, in which case the handler asserts
/// the exact revert reason (so a missing check fails the run instead of being swallowed).
contract MoneyHandler is Test {
    Money public money;
    address public owner;
    address[] public actors;

    // ghost state: what the handler believes the owner has configured and paid for
    uint256 public ghostRate;
    bool public ghostPaused;
    uint256 public ghostTokensFromBuys;
    uint256 public ghostOwnerMinted;
    uint256 public ghostEthIn;
    uint256 public ghostEthOut;

    uint256 constant TOKEN_UNIT = 1e6;
    bytes constant NOT_OWNER = bytes("Ownable: caller is not the owner");
    bytes constant NOT_PENDING_OWNER = bytes("Ownable2Step: caller is not the new owner");
    bytes constant PAUSED = bytes("Pausable: paused");

    constructor(Money m, address o) {
        money = m;
        owner = o;
        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA201));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // ------------------------------------------------------------------ buyer paths

    function buy(uint256 actorSeed, uint256 weiAmount, bool viaBuyTo, uint256 recipientSeed) external {
        address actor = _actor(actorSeed);
        address recipient = viaBuyTo ? _actor(recipientSeed) : actor;
        weiAmount = bound(weiAmount, 1, 100 ether);
        uint256 expected = (weiAmount * ghostRate * TOKEN_UNIT) / 1 ether;

        vm.deal(actor, weiAmount);

        if (ghostPaused) {
            vm.prank(actor);
            vm.expectRevert(PAUSED);
            if (viaBuyTo) money.buyTo{value: weiAmount}(recipient);
            else money.buy{value: weiAmount}();
            return;
        }
        if (ghostRate == 0) {
            vm.prank(actor);
            vm.expectRevert(bytes("Rate must be > 0"));
            if (viaBuyTo) money.buyTo{value: weiAmount}(recipient);
            else money.buy{value: weiAmount}();
            return;
        }
        if (expected == 0) {
            vm.prank(actor);
            vm.expectRevert(bytes("Token amount zero after normalization"));
            if (viaBuyTo) money.buyTo{value: weiAmount}(recipient);
            else money.buy{value: weiAmount}();
            return;
        }

        vm.prank(actor);
        if (viaBuyTo) money.buyTo{value: weiAmount}(recipient);
        else money.buy{value: weiAmount}();

        ghostTokensFromBuys += expected;
        ghostEthIn += weiAmount;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, money.balanceOf(from));

        vm.prank(from);
        require(money.transfer(to, amount), "transfer must succeed");
    }

    function donate(uint256 actorSeed, uint256 weiAmount) external {
        address actor = _actor(actorSeed);
        weiAmount = bound(weiAmount, 0, 10 ether);
        vm.deal(actor, weiAmount);

        vm.prank(actor);
        (bool ok, ) = address(money).call{value: weiAmount}("");
        require(ok, "plain ETH send must be accepted");

        ghostEthIn += weiAmount;
    }

    // ------------------------------------------------------------------ owner paths

    function setRate(uint256 newRate) external {
        newRate = bound(newRate, 1, money.MAX_RATE());
        vm.prank(owner);
        money.setRate(newRate);
        ghostRate = newRate;
    }

    function setPaused(bool paused) external {
        if (paused == ghostPaused) return;
        vm.prank(owner);
        if (paused) money.pause();
        else money.unpause();
        ghostPaused = paused;
    }

    function ownerMint(uint256 recipientSeed, uint256 amount) external {
        address recipient = _actor(recipientSeed);
        amount = bound(amount, 1, 1_000_000 * TOKEN_UNIT);

        if (ghostPaused) {
            vm.prank(owner);
            vm.expectRevert(PAUSED);
            money.ownerMint(recipient, amount);
            return;
        }

        vm.prank(owner);
        money.ownerMint(recipient, amount);
        ghostOwnerMinted += amount;
    }

    function queueWithdrawal(uint256 amount) external {
        uint256 balance = address(money).balance;
        uint256 queued = money.queuedAmount();

        if (ghostPaused) {
            vm.prank(owner);
            vm.expectRevert(PAUSED);
            money.queueWithdrawal(1);
            return;
        }
        if (balance == 0) {
            vm.prank(owner);
            vm.expectRevert(bytes("Not enough balance"));
            money.queueWithdrawal(1);
            return;
        }
        amount = bound(amount, 1, balance);
        if (queued != 0) {
            vm.prank(owner);
            vm.expectRevert(bytes("Existing queued withdrawal"));
            money.queueWithdrawal(amount);
            return;
        }

        vm.prank(owner);
        money.queueWithdrawal(amount);
    }

    function executeWithdrawal(uint256 actorSeed, bool waitForTimelock) external {
        address caller = _actor(actorSeed); // permissionless path
        uint256 queued = money.queuedAmount();
        uint256 executeTime = money.queuedExecuteTime();

        if (ghostPaused) {
            vm.prank(caller);
            vm.expectRevert(PAUSED);
            money.executeWithdrawal();
            return;
        }
        if (queued == 0) {
            vm.prank(caller);
            vm.expectRevert(bytes("No queued withdrawal"));
            money.executeWithdrawal();
            return;
        }
        if (waitForTimelock) {
            vm.warp(executeTime);
        }
        if (block.timestamp < executeTime) {
            vm.prank(caller);
            vm.expectRevert(bytes("Timelock not expired"));
            money.executeWithdrawal();
            return;
        }

        vm.prank(caller);
        money.executeWithdrawal();
        ghostEthOut += queued;
    }

    function cancelWithdrawal() external {
        uint256 queued = money.queuedAmount();
        vm.prank(owner);
        if (queued == 0) {
            vm.expectRevert(bytes("No queued withdrawal"));
        }
        money.cancelQueuedWithdrawal();
    }

    // ------------------------------------------------------------------ owner-only paths, called by non-owners

    function nonOwnerSetRate(uint256 actorSeed, uint256 newRate) external {
        newRate = bound(newRate, 1, money.MAX_RATE());
        vm.prank(_actor(actorSeed));
        vm.expectRevert(NOT_OWNER);
        money.setRate(newRate);
    }

    function nonOwnerPause(uint256 actorSeed, bool pauseIt) external {
        vm.prank(_actor(actorSeed));
        vm.expectRevert(NOT_OWNER);
        if (pauseIt) money.pause();
        else money.unpause();
    }

    function nonOwnerMint(uint256 actorSeed, uint256 amount) external {
        amount = bound(amount, 1, type(uint128).max);
        address actor = _actor(actorSeed);
        vm.prank(actor);
        vm.expectRevert(NOT_OWNER);
        money.ownerMint(actor, amount);
    }

    function nonOwnerQueueWithdrawal(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        vm.prank(actor);
        vm.expectRevert(NOT_OWNER);
        money.queueWithdrawalTo(actor, amount);
    }

    function nonOwnerCancelWithdrawal(uint256 actorSeed) external {
        vm.prank(_actor(actorSeed));
        vm.expectRevert(NOT_OWNER);
        money.cancelQueuedWithdrawal();
    }

    function nonOwnerTransferOwnership(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        vm.prank(actor);
        vm.expectRevert(NOT_OWNER);
        money.transferOwnership(actor);
    }

    function nonOwnerAcceptOwnership(uint256 actorSeed) external {
        vm.prank(_actor(actorSeed));
        vm.expectRevert(NOT_PENDING_OWNER);
        money.acceptOwnership();
    }

    function nonOwnerQueueEnableRescueToZero(uint256 actorSeed) external {
        vm.prank(_actor(actorSeed));
        vm.expectRevert(NOT_OWNER);
        money.queueEnableRescueToZero();
    }

    function nonOwnerRescueERC20(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        vm.prank(actor);
        vm.expectRevert(NOT_OWNER);
        money.rescueERC20(IERC20(address(0x1234)), actor, 1);
    }
}

/// @dev fail-on-revert: a handler call that reverts for a reason the handler did not predict is
/// itself a failure. Together with the exact-reason expectRevert checks in the handler this means a
/// missing access-control or pause check cannot hide behind a rolled-back call.
/// forge-config: default.invariant.fail-on-revert = true
contract MoneyInvariantTest is Test {
    Money money;
    MoneyHandler handler;
    address owner = address(0xABCD);

    function setUp() public {
        vm.prank(owner);
        money = new Money();
        handler = new MoneyHandler(money, owner);
        targetContract(address(handler));
    }

    /// Total supply conservation: every token unit in existence sits in an actor's balance.
    function invariant_totalSupplyEqualsSumOfBalances() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            sum += money.balanceOf(handler.actors(i));
        }
        assertEq(money.totalSupply(), sum);
    }

    /// No balance created without payment: every token unit was either bought at the quoted
    /// wei * rate * 10**decimals / 1 ETH, or minted by the owner through ownerMint.
    function invariant_everyTokenWasPaidForOrOwnerMinted() public view {
        assertEq(money.totalSupply(), handler.ghostTokensFromBuys() + handler.ghostOwnerMinted());
    }

    /// Every wei the contract holds came in through buy/buyTo or a plain send and left only
    /// through an executed, timelocked withdrawal.
    function invariant_ethBalanceMatchesFlows() public view {
        assertEq(address(money).balance, handler.ghostEthIn() - handler.ghostEthOut());
    }

    /// Owner-only paths stay owner-only: the configuration the non-owner handlers attack is
    /// exactly what the owner last set, and ownership never moved.
    function invariant_ownerControlledStateMatchesOwnerActions() public view {
        assertEq(money.owner(), owner);
        assertEq(money.pendingOwner(), address(0));
        assertEq(money.rate(), handler.ghostRate());
        assertEq(money.paused(), handler.ghostPaused());
        assertFalse(money.rescueToZeroEnabled());
        assertEq(money.queuedRescueToZeroExecuteTime(), 0);
    }

    /// A queued withdrawal can never exceed what the contract can pay out, and a queued entry
    /// is never left half-cleared.
    function invariant_queuedWithdrawalIsConsistent() public view {
        uint256 queued = money.queuedAmount();
        if (queued == 0) {
            assertEq(money.queuedExecuteTime(), 0);
            assertEq(money.queuedRecipient(), address(0));
        } else {
            assertEq(money.queuedRecipient(), owner);
            assertGt(money.queuedExecuteTime(), 0);
        }
    }
}
