// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract Money {
    string public name = "Money";
    string public symbol = "MNY";
    uint8 public decimals = 0; // token units are integer for simplicity in tests

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    address public owner;

    uint256 public tokensPerEth;

    // Withdrawal scheduling
    uint256 public scheduledAmount;
    uint256 public scheduledAvailableAt;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event WithdrawScheduled(uint256 amount, uint256 availableAt);
    event WithdrawExecuted(address indexed to, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    constructor(uint256 _tokensPerEth) {
        owner = msg.sender;
        tokensPerEth = _tokensPerEth;
    }

    receive() external payable {}

    // buy mints tokens in proportion to ETH sent
    function buy() external payable {
        require(msg.value > 0, "must send ETH");
        // normalize units so that sending exactly 1 ether mints tokensPerEth tokens
        uint256 amountToMint = tokensPerEth * msg.value / 1 ether;
        require(amountToMint > 0, "amountToMint is zero");
        _mint(msg.sender, amountToMint);
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    // Ownership
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "new owner is zero");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // Schedule a withdraw of ETH from the contract; it becomes executable after 48 hours
    function scheduleWithdraw(uint256 amount) external onlyOwner {
        require(amount > 0, "amount zero");
        scheduledAmount = amount;
        scheduledAvailableAt = block.timestamp + 48 hours;
        emit WithdrawScheduled(amount, scheduledAvailableAt);
    }

    // Execute the withdraw; sends the scheduled amount to the current owner
    function executeWithdraw() external onlyOwner {
        require(scheduledAmount > 0, "no scheduled withdraw");
        require(block.timestamp >= scheduledAvailableAt, "withdraw not available yet");
        uint256 amount = scheduledAmount;
        scheduledAmount = 0;
        scheduledAvailableAt = 0;
        address payable recipient = payable(owner);
        require(address(this).balance >= amount, "insufficient balance");
        (bool ok, ) = recipient.call{value: amount}("");
        require(ok, "withdraw transfer failed");
        emit WithdrawExecuted(recipient, amount);
    }
}
