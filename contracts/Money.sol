// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @notice Minimal Money ERC20 with payable buy(), 48h timelock on owner withdrawals, and pause.
/// @dev Ownership is TWO-STEP (Ownable2Step): transferOwnership() only nominates a pending owner
/// and the nominee must call acceptOwnership() to take control, so a mistyped or unreachable
/// address can never take ownership of the contract's ETH. Ownership is also non-renounceable.
contract Money is ERC20, Pausable, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant TIMELOCK = 48 hours;

    // queued withdrawal info
    uint256 public queuedAmount;
    uint256 public queuedExecuteTime;
    address public queuedRecipient;

    // owner-set buy rate (token units per 1 ETH, in whole tokens)
    // cap rate to prevent arithmetic overflow in buy()
    uint256 public constant MAX_RATE = 1e12;
    uint256 public rate;

    // rescue-to-zero opt-in
    bool public rescueToZeroEnabled;
    uint256 public queuedRescueToZeroExecuteTime;

    event Bought(address indexed buyer, uint256 weiAmount, uint256 tokenAmount, uint256 rate);
    // include recipient in queued and executed withdrawal events for improved off-chain indexing
    event WithdrawalQueued(uint256 amount, uint256 executeAfter, address indexed recipient);
    event WithdrawalExecuted(uint256 amount, address indexed recipient);
    event WithdrawalCancelled(uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event RateChanged(uint256 newRate);
    // Emit when contract receives ETH directly (receive/fallback)
    event Deposit(address indexed from, uint256 amount);

    // events for rescue-to-zero timelock
    event RescueToZeroQueued(uint256 executeAfter);
    event RescueToZeroExecuted(uint256 executeAt);
    event RescueToZeroCancelled(uint256 previousExecuteAfter);

    constructor() ERC20("Money", "MNY") {
        // initial supply 0, owner is deployer
    }

    // Use 6 decimals to force explicit normalization between wei and token units
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Set the buy rate (tokens per 1 ETH). Only owner can call.
    function setRate(uint256 newRate) external onlyOwner {
        require(newRate > 0 && newRate <= MAX_RATE, "Rate out of range");
        rate = newRate;
        emit RateChanged(newRate);
    }

    /// @notice Buy tokens by sending ETH. Uses owner-set `rate` (token units per 1 ETH).
    /// For example, rate==1 mints 1 token * (10**decimals) per 1 ETH.
    /// @dev Unprotected against a rate change mined before this call: kept for backwards
    /// compatibility. Prefer buy(uint256 minTokenAmount) with a quote from previewBuy().
    function buy() external payable whenNotPaused nonReentrant {
        _buy(0);
    }

    /// @notice Buy tokens by sending ETH, reverting unless at least `minTokenAmount` token
    /// units are minted. Protects a buyer from an owner rate change mined between the quote
    /// (see previewBuy) and this transaction.
    /// @param minTokenAmount Minimum acceptable token units out (same units as balanceOf).
    function buy(uint256 minTokenAmount) external payable whenNotPaused nonReentrant {
        _buy(minTokenAmount);
    }

    /// @dev Shared buy body. Both external entry points carry whenNotPaused and nonReentrant,
    /// so the guard is entered exactly once per call.
    function _buy(uint256 minTokenAmount) private {
        require(msg.value > 0, "Must send ETH to buy");
        require(rate > 0, "Rate must be > 0");

        // tokenAmount = msg.value (wei) * rate (tokens per ETH) * 10**decimals / 1 ether
        uint256 tokenDecimalsFactor = 10 ** uint256(decimals());

        // conservative guard against multiplication overflow when computing tokenAmount
        // use MAX_RATE (constant) so division cannot divide-by-zero and bound is auditable
        uint256 maxMsgValue = type(uint256).max / MAX_RATE / tokenDecimalsFactor;
        require(msg.value <= maxMsgValue, "msg.value too large");

        uint256 tokenAmount = (msg.value * rate * tokenDecimalsFactor) / 1 ether;

        require(tokenAmount > 0, "Token amount zero after normalization");
        // slippage guard: a rate cut between quote and execution can never shortchange the buyer
        require(tokenAmount >= minTokenAmount, "Insufficient tokens out");

        _mint(msg.sender, tokenAmount);
        emit Bought(msg.sender, msg.value, tokenAmount, rate);
    }

    /// @notice Preview a buy without affecting state. Returns (tokenAmount, wouldSucceed).
    /// Implementation mirrors buy() but checks the conservative maxMsgValue bound before any
    /// multiplication so the view never overflows or reverts for extreme inputs.
    function previewBuy(uint256 weiAmount) external view returns (uint256 tokenAmount, bool wouldSucceed) {
        // mirror buy()'s normalization
        if (rate == 0) return (0, false);
        if (weiAmount == 0) return (0, false);

        uint256 tokenDecimalsFactor = 10 ** uint256(decimals());
        uint256 maxMsgValue = type(uint256).max / MAX_RATE / tokenDecimalsFactor;

        if (weiAmount > maxMsgValue) {
            return (0, false);
        }

        // safe to perform multiplication now
        uint256 computed = (weiAmount * rate * tokenDecimalsFactor) / 1 ether;
        if (computed == 0) return (0, false);
        return (computed, true);
    }

    /// @notice Preview the minimal wei required to mint at least `tokenUnits` tokens.
    /// Returns (weiRequired, wouldSucceed). Mirrors previewBuy's normalization and the
    /// same conservative bounds: (0, false) is returned when the request cannot be
    /// represented safely or when rate==0 or tokenUnits==0.
    function previewWeiForTokens(uint256 tokenUnits) external view returns (uint256 weiRequired, bool wouldSucceed) {
        if (rate == 0) return (0, false);
        if (tokenUnits == 0) return (0, false);

        uint256 tokenDecimalsFactor = 10 ** uint256(decimals());
        uint256 maxMsgValue = type(uint256).max / MAX_RATE / tokenDecimalsFactor;

        // denom = rate * tokenDecimalsFactor; fits because rate <= MAX_RATE and tokenDecimalsFactor is small
        uint256 denom = rate * tokenDecimalsFactor;
        // prevent overflow in numerator (tokenUnits * 1 ether)
        if (tokenUnits > type(uint256).max / 1 ether) {
            return (0, false);
        }

        uint256 numerator = tokenUnits * 1 ether;
        // ceil division to ensure returned wei mints at least tokenUnits
        uint256 weiReq = (numerator + denom - 1) / denom;
        if (weiReq == 0) return (0, false);
        if (weiReq > maxMsgValue) return (0, false);
        return (weiReq, true);
    }

    /// @notice Owner queues a withdrawal of ETH from contract. Needs executeWithdrawal after 48h.
    function queueWithdrawal(uint256 amount) external onlyOwner whenNotPaused {
        require(amount > 0, "Amount must be >0");
        require(amount <= address(this).balance, "Not enough balance");
        // Prevent silently overwriting an existing queued withdrawal.
        require(queuedAmount == 0, "Existing queued withdrawal");

        queuedAmount = amount;
        queuedExecuteTime = block.timestamp + TIMELOCK;
        queuedRecipient = owner();
        emit WithdrawalQueued(amount, queuedExecuteTime, queuedRecipient);
    }

    /// @notice Owner queues a withdrawal of ETH to an arbitrary recipient. Needs executeWithdrawal after 48h.
    function queueWithdrawalTo(address recipient, uint256 amount) external onlyOwner whenNotPaused {
        require(recipient != address(0), "Recipient zero");
        require(amount > 0, "Amount must be >0");
        require(amount <= address(this).balance, "Not enough balance");
        // Prevent silently overwriting an existing queued withdrawal.
        require(queuedAmount == 0, "Existing queued withdrawal");

        queuedAmount = amount;
        queuedExecuteTime = block.timestamp + TIMELOCK;
        queuedRecipient = recipient;
        emit WithdrawalQueued(amount, queuedExecuteTime, queuedRecipient);
    }

    /// @notice Execute a queued withdrawal after the 48h timelock. Callable by anyone once timelock has expired.
    function executeWithdrawal() external nonReentrant whenNotPaused {
        require(queuedAmount > 0, "No queued withdrawal");
        require(block.timestamp >= queuedExecuteTime, "Timelock not expired");

        uint256 amount = queuedAmount;
        address recipient = queuedRecipient;

        // Perform the external call first (nonReentrant guards against reentrancy).
        // Only clear the queued state once the transfer has actually succeeded, so a
        // reverting/failing recipient leaves the queued withdrawal intact for the owner
        // to inspect, retry, or cancel.
        (bool ok, ) = payable(recipient).call{value: amount}("");
        require(ok, "Transfer failed");

        queuedAmount = 0;
        queuedExecuteTime = 0;
        queuedRecipient = address(0);

        emit WithdrawalExecuted(amount, recipient);
    }

    /// @notice Cancel a queued withdrawal. Callable by owner even while paused to allow emergency retraction.
    function cancelQueuedWithdrawal() external onlyOwner {
        uint256 amount = queuedAmount;
        require(amount > 0, "No queued withdrawal");

        queuedAmount = 0;
        queuedExecuteTime = 0;
        queuedRecipient = address(0);

        emit WithdrawalCancelled(amount);
    }

    /// @notice Pause buys and withdrawal operations.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Ownership can never be renounced.
    /// @dev Every withdrawal path (queueWithdrawal, queueWithdrawalTo, cancelQueuedWithdrawal),
    /// setRate, pause/unpause and rescueERC20 are onlyOwner, so an owner of address(0) would
    /// strand every wei held by this contract for ever. The inherited Ownable.renounceOwnership
    /// is therefore disabled; use transferOwnership() + acceptOwnership() to hand control over.
    /// @dev Deliberately left non-view so the call is a plain CALL (and so the signature keeps
    /// matching the inherited one); it reverts for every caller, owner included.
    function renounceOwnership() public override {
        revert("Ownership cannot be renounced");
    }

    /// @notice Queue enabling rescue-to-zero (allow rescueERC20 to send to address(0)).
    /// Owner-only, 48h timelock. Uses the same pattern as ETH withdrawals.
    function queueEnableRescueToZero() external onlyOwner whenNotPaused {
        require(queuedRescueToZeroExecuteTime == 0, "Existing queued enable");
        queuedRescueToZeroExecuteTime = block.timestamp + TIMELOCK;
        emit RescueToZeroQueued(queuedRescueToZeroExecuteTime);
    }

    /// @notice Cancel a queued enable for rescue-to-zero. Callable by the owner to retract a queued opt-in.
    /// Mirrors cancelQueuedWithdrawal behaviour: owner may cancel even while paused.
    function cancelQueuedEnableRescueToZero() external onlyOwner {
        uint256 prev = queuedRescueToZeroExecuteTime;
        require(prev != 0, "No queued enable");

        queuedRescueToZeroExecuteTime = 0;

        emit RescueToZeroCancelled(prev);
    }

    /// @notice Execute the queued enable for rescue-to-zero. Callable by anyone after the timelock.
    function executeEnableRescueToZero() external nonReentrant whenNotPaused {
        require(queuedRescueToZeroExecuteTime != 0, "No queued enable");
        require(block.timestamp >= queuedRescueToZeroExecuteTime, "Timelock not expired");

        // enable permanent one-way switch
        rescueToZeroEnabled = true;

        uint256 executeAt = queuedRescueToZeroExecuteTime;
        queuedRescueToZeroExecuteTime = 0;

        emit RescueToZeroExecuted(executeAt);
    }

    /// @notice Rescue an ERC20 from the contract to `to`. Only owner may call.
    /// By default rescuing to address(0) is forbidden unless rescueToZeroEnabled has been set true
    /// via the 48h timelocked enable. Uses SafeERC20 so non-standard ERC20s (no return) are supported.
    function rescueERC20(IERC20 token, address to, uint256 amount) external onlyOwner whenNotPaused nonReentrant {
        require(address(token) != address(this), "Cannot sweep Money token");
        require(amount > 0, "Amount must be >0");
        if (to == address(0)) {
            require(rescueToZeroEnabled, "Rescue to zero disabled");
        }

        // perform transfer using SafeERC20 which supports non-standard tokens
        token.safeTransfer(to, amount);

        emit ERC20Rescued(address(token), to, amount);
    }

    /// @notice Fallbacks to receive ETH and emit a Deposit event so off-chain tooling sees direct sends.
    receive() external payable {
        emit Deposit(msg.sender, msg.value);
    }

    fallback() external payable {
        emit Deposit(msg.sender, msg.value);
    }
}
