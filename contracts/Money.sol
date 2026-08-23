// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract Money is ERC20, Ownable, Pausable, ReentrancyGuard {
    uint256 public tokensPerEth;
    uint256 public constant TIMELOCK = 48 hours;

    // pending withdraw
    uint256 public pendingWithdrawAmount;
    uint256 public pendingWithdrawReady;

    // pending rate change
    uint256 public pendingRate;
    uint256 public pendingRateReady;

    event Bought(address indexed buyer, uint256 ethAmount, uint256 tokensMinted);
    event WithdrawScheduled(uint256 amount, uint256 readyAt);
    event WithdrawExecuted(address to, uint256 amount);
    event RateChangeScheduled(uint256 newRate, uint256 readyAt);
    event RateChangeExecuted(uint256 oldRate, uint256 newRate);

    constructor(uint256 tokensPerEth_, uint256 initialSupply) ERC20("Money", "MNY") {
        tokensPerEth = tokensPerEth_;
        if (initialSupply > 0) {
            _mint(msg.sender, initialSupply);
        }
    }

    receive() external payable {
        // allow receiving ETH
    }

    function buy() external payable whenNotPaused nonReentrant {
        require(msg.value > 0, "zero eth");
        uint256 amountToMint = msg.value * tokensPerEth;
        _mint(msg.sender, amountToMint);
        emit Bought(msg.sender, msg.value, amountToMint);
    }

    // Owner schedules a withdrawal; after TIMELOCK seconds it can be executed by owner
    function scheduleWithdraw(uint256 amount) external onlyOwner {
        require(amount > 0, "zero amount");
        require(address(this).balance >= amount, "insufficient balance");
        pendingWithdrawAmount = amount;
        pendingWithdrawReady = block.timestamp + TIMELOCK;
        emit WithdrawScheduled(amount, pendingWithdrawReady);
    }

    function clearPendingWithdraw() external onlyOwner {
        pendingWithdrawAmount = 0;
        pendingWithdrawReady = 0;
    }

    function executeWithdraw() external onlyOwner nonReentrant {
        require(pendingWithdrawAmount > 0, "no pending withdraw");
        require(block.timestamp >= pendingWithdrawReady, "timelock");
        uint256 amount = pendingWithdrawAmount;
        // clear first
        pendingWithdrawAmount = 0;
        pendingWithdrawReady = 0;
        // safe send with empty calldata
        (bool ok, ) = payable(owner()).call{value: amount}("");
        require(ok, "withdraw failed");
        emit WithdrawExecuted(owner(), amount);
    }

    // Rate change with timelock similar to withdraw
    function scheduleRateChange(uint256 newRate) external onlyOwner {
        require(newRate > 0, "zero rate");
        pendingRate = newRate;
        pendingRateReady = block.timestamp + TIMELOCK;
        emit RateChangeScheduled(newRate, pendingRateReady);
    }

    function clearPendingRateChange() external onlyOwner {
        pendingRate = 0;
        pendingRateReady = 0;
    }

    function executeRateChange() external onlyOwner {
        require(pendingRate > 0, "no pending rate");
        require(block.timestamp >= pendingRateReady, "timelock");
        uint256 old = tokensPerEth;
        tokensPerEth = pendingRate;
        pendingRate = 0;
        pendingRateReady = 0;
        emit RateChangeExecuted(old, tokensPerEth);
    }

    // pause/unpause
    function pause() external onlyOwner {
        _pause();
    }
    function unpause() external onlyOwner {
        _unpause();
    }
}
