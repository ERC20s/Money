// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract Money is ERC20, Ownable, ReentrancyGuard, Pausable {
    uint256 public tokensPerEth; // expressed in token smallest units per 1 ETH

    // Withdraw timelock
    uint256 public withdrawAmount;
    uint256 public withdrawUnlockTime;

    // Rate change timelock
    uint256 public pendingTokensPerEth;
    uint256 public rateChangeUnlockTime;

    uint256 public constant TIMELOCK = 48 hours;

    event Purchase(address indexed buyer, uint256 ethAmount, uint256 tokenAmount);
    event WithdrawScheduled(uint256 amount, uint256 unlockTime);
    event WithdrawExecuted(uint256 amount);
    event WithdrawCancelled();
    event RateChangeScheduled(uint256 newRate, uint256 unlockTime);
    event RateChangeExecuted(uint256 newRate);

    constructor(uint256 tokensPerEth_, uint256 initialSupply) ERC20("Money", "MNY") {
        tokensPerEth = tokensPerEth_;
        if (initialSupply > 0) {
            _mint(msg.sender, initialSupply);
        }
    }

    // Buy tokens by sending ETH. Token amount = msg.value * tokensPerEth / 1 ether
    function buy() external payable nonReentrant whenNotPaused {
        require(msg.value > 0, "Must send ETH");
        uint256 tokenAmount = (msg.value * tokensPerEth) / 1 ether;
        require(tokenAmount > 0, "Amount too small for configured rate");
        _mint(msg.sender, tokenAmount);
        emit Purchase(msg.sender, msg.value, tokenAmount);
    }

    receive() external payable {
        buy();
    }

    // Owner schedules a withdraw; cannot execute until TIMELOCK has passed
    function scheduleWithdraw(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be > 0");
        require(address(this).balance >= amount, "Insufficient contract balance");
        withdrawAmount = amount;
        withdrawUnlockTime = block.timestamp + TIMELOCK;
        emit WithdrawScheduled(amount, withdrawUnlockTime);
    }

    function executeWithdraw() external onlyOwner nonReentrant {
        require(withdrawAmount > 0, "No withdraw scheduled");
        require(block.timestamp >= withdrawUnlockTime, "Withdraw timelock not expired");
        uint256 amount = withdrawAmount;
        withdrawAmount = 0;
        withdrawUnlockTime = 0;
        (bool ok, ) = payable(owner()).call{value: amount}("{}");
        require(ok, "ETH transfer failed");
        emit WithdrawExecuted(amount);
    }

    function cancelWithdraw() external onlyOwner {
        withdrawAmount = 0;
        withdrawUnlockTime = 0;
        emit WithdrawCancelled();
    }

    // Rate change scheduling
    function scheduleRateChange(uint256 newRate) external onlyOwner {
        require(newRate > 0, "Rate must be > 0");
        pendingTokensPerEth = newRate;
        rateChangeUnlockTime = block.timestamp + TIMELOCK;
        emit RateChangeScheduled(newRate, rateChangeUnlockTime);
    }

    function executeRateChange() external onlyOwner {
        require(pendingTokensPerEth > 0, "No rate change scheduled");
        require(block.timestamp >= rateChangeUnlockTime, "Rate change timelock not expired");
        tokensPerEth = pendingTokensPerEth;
        pendingTokensPerEth = 0;
        rateChangeUnlockTime = 0;
        emit RateChangeExecuted(tokensPerEth);
    }

    // Emergency pause controls
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // Allow owner to renounce timelocked actions by clearing pending values
    function clearPendingRateChange() external onlyOwner {
        pendingTokensPerEth = 0;
        rateChangeUnlockTime = 0;
    }
}
