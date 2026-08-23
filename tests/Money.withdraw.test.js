const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Money withdraw flow", function () {
  it("schedules and executes withdraw to a payable contract owner", async function () {
    const [deployer, other] = await ethers.getSigners();

    const Money = await ethers.getContractFactory("Money");
    const money = await Money.deploy(1000);
    await money.deployed();

    // Buy 1 ETH worth of tokens
    await money.connect(other).buy({ value: ethers.utils.parseEther("1") });
    expect(await money.balanceOf(other.address)).to.equal(1000);

    // Schedule withdraw while deployer is owner
    await money.scheduleWithdraw(ethers.utils.parseEther("1"));

    // Transfer ownership to a payable contract
    const PayableOwnerMock = await ethers.getContractFactory("PayableOwnerMock");
    const payableOwner = await PayableOwnerMock.deploy();
    await payableOwner.deployed();

    await money.transferOwnership(payableOwner.address);

    // Increase time by 48 hours
    await ethers.provider.send("evm_increaseTime", [48 * 60 * 60]);
    await ethers.provider.send("evm_mine");

    // Now the new owner (the payable contract) executes the withdraw by calling executeWithdraw
    // We have to call executeWithdraw from the payable contract's context; use a forwarded call
    await payableOwner.forwardCall(money.address, money.interface.encodeFunctionData("executeWithdraw"));

    expect(await ethers.provider.getBalance(payableOwner.address)).to.equal(ethers.utils.parseEther("1"));
  });
});
