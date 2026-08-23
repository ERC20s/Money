// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @notice Minimal Money ERC20 with payable buy(), 48h timelock on owner withdrawals, and pause.
contract Money is ERC20, Pausable, Ownable, ReentrancyGuard {
    uint256 public constant TIMELOCK = 48 hours;

    // queued withdrawal info
    uint256 public queuedAmount;
    uint256 public queuedExecuteTime;

    event Bought(address indexed buyer, uint256 weiAmount, uint256 tokenAmount, uint256 rate);
    event WithdrawalQueued(uint256 amount, uint256 executeAfter);
    event WithdrawalExecuted(uint256 amount);
    event WithdrawalCancelled(uint256 amount);

    constructor() ERC20("Money", "MNY") {
        // initial supply 0, owner is deployer
    }

    // Use 6 decimals to force explicit normalization between wei and token units
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Buy tokens by sending ETH. `rate` is token units per 1 ETH (in whole tokens).
    /// For example, rate==1 mints 1 token * (10**decimals) per 1 ETH.
    function buy(uint256 rate) external payable whenNotPaused nonReentrant {
        require(msg.value > 0, "Must send ETH to buy");
        require(rate > 0, "Rate must be > 0");

        // tokenAmount = msg.value (wei) * rate (tokens per ETH) * 10**decimals / 1 ether
        uint256 tokenDecimalsFactor = 10 ** uint256(decimals());
        uint256 tokenAmount = (msg.value * rate * tokenDecimalsFactor) / 1 ether;

        require(tokenAmount > 0, "Token amount zero after normalization");

        _mint(msg.sender, tokenAmount);
        emit Bought(msg.sender, msg.value, tokenAmount, rate);
    }

    /// @notice Owner queues a withdrawal of ETH from contract. Needs executeWithdrawal after 48h.
    function queueWithdrawal(uint256 amount) external onlyOwner whenNotPaused {
        require(amount > 0, "Amount must be >0");
        require(amount <= address(this).balance, "Not enough balance");

        queuedAmount = amount;
        queuedExecuteTime = block.timestamp + TIMELOCK;
        emit WithdrawalQueued(amount, queuedExecuteTime);
    }

    /// @notice Execute a queued withdrawal after the 48h timelock.
    function executeWithdrawal() external onlyOwner nonReentrant whenNotPaused {
        require(queuedAmount > 0, "No queued withdrawal");
        require(block.timestamp >= queuedExecuteTime, "Timelock not expired");

        uint256 amount = queuedAmount;
        queuedAmount = 0;
        queuedExecuteTime = 0;

        (bool ok, ) = payable(owner()).call{value: amount}("");
        require(ok, "Transfer failed");

        emit WithdrawalExecuted(amount);
    }

    /// @notice Cancel a queued withdrawal. Callable by owner even while paused to allow emergency retraction.
    function cancelQueuedWithdrawal() external onlyOwner {
        uint256 amount = queuedAmount;
        require(amount > 0, "No queued withdrawal");

        queuedAmount = 0;
        queuedExecuteTime = 0;

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

    // Allow contract to receive ETH (so tests or others can fund it directly if needed)
    receive() external payable {}
}
