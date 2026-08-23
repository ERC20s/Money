// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @notice Minimal Money ERC20 with payable buy(), 48h timelock on owner withdrawals, and pause.
contract Money is ERC20, Pausable, Ownable, ReentrancyGuard {
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

    event Bought(address indexed buyer, uint256 weiAmount, uint256 tokenAmount, uint256 rate);
    event WithdrawalQueued(uint256 amount, uint256 executeAfter);
    event WithdrawalExecuted(uint256 amount);
    event WithdrawalCancelled(uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event RateChanged(uint256 newRate);

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
    function buy() external payable whenNotPaused nonReentrant {
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

        _mint(msg.sender, tokenAmount);
        emit Bought(msg.sender, msg.value, tokenAmount, rate);
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
        emit WithdrawalQueued(amount, queuedExecuteTime);
    }

    /// @notice Execute a queued withdrawal after the 48h timelock. Callable by anyone once timelock has expired.
    function executeWithdrawal() external nonReentrant whenNotPaused {
        require(queuedAmount > 0, "No queued withdrawal");
        require(block.timestamp >= queuedExecuteTime, "Timelock not expired");

        uint256 amount = queuedAmount;
        address recipient = queuedRecipient;

        // clear state before external call
        queuedAmount = 0;
        queuedExecuteTime = 0;
        queuedRecipient = address(0);

        (bool ok, ) = payable(recipient).call{value: amount}("");
        require(ok, "Transfer failed");

        emit WithdrawalExecuted(amount);
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

    /// @notice Rescue third-party ERC20 tokens accidentally sent to this contract.
    /// Owner-only, non-reentrant, and explicitly disallows sweeping the Money token itself.
    function rescueERC20(IERC20 token, address to, uint256 amount) external onlyOwner nonReentrant {
        require(address(token) != address(this), "Cannot sweep Money token");
        require(amount > 0, "Amount > 0");

        // use SafeERC20 to support tokens that do not return a bool on transfer
        token.safeTransfer(to, amount);

        emit ERC20Rescued(address(token), to, amount);
    }

    // Allow contract to receive ETH (so tests or others can fund it directly if needed)
    receive() external payable {}
}
