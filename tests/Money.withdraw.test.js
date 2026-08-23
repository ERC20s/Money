const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Money token withdraw and timelock tests", function() {
  it("buy mints tokens and owner can schedule and execute withdraw after timelock", async function() {
    const [owner, buyer] = await ethers.getSigners();
    const Money = await ethers.getContractFactory("Money");
    const tokensPerEth = 1000;
    const money = await Money.deploy(tokensPerEth, 0);
    await money.deployed();

    // buyer buys 1 ETH worth
    await money.connect(buyer).buy({ value: ethers.utils.parseEther("1") });
    const buyerBalance = await money.balanceOf(buyer.address);
    expect(buyerBalance).to.equal(ethers.BigNumber.from(tokensPerEth).mul(ethers.BigNumber.from(1)));

    // fund contract so owner can withdraw
    await owner.sendTransaction({ to: money.address, value: ethers.utils.parseEther("2") });

    // schedule withdraw
    await money.scheduleWithdraw(ethers.utils.parseEther("1"));
    // cannot execute immediately
    await expect(money.executeWithdraw()).to.be.revertedWith("timelock");

    // increase time beyond timelock
    await ethers.provider.send("evm_increaseTime", [48 * 3600 + 1]);
    await ethers.provider.send("evm_mine");

    // execute withdraw succeeds
    await expect(money.executeWithdraw()).to.not.be.reverted;
  });

  it("pause blocks buy", async function() {
    const [owner, buyer] = await ethers.getSigners();
    const Money = await ethers.getContractFactory("Money");
    const tokensPerEth = 1000;
    const money = await Money.deploy(tokensPerEth, 0);
    await money.deployed();

    await money.pause();
    await expect(money.connect(buyer).buy({ value: ethers.utils.parseEther("1") })).to.be.reverted;
    await money.unpause();
    await expect(money.connect(buyer).buy({ value: ethers.utils.parseEther("1") })).to.not.be.reverted;
  });

  it("contract-owner withdrawal succeeds (regression test for calldata bug)", async function() {
    const [owner, buyer, other] = await ethers.getSigners();
    // deploy a payable contract that will become owner
    const PayableOwner = await ethers.getContractFactory("PayableOwnerMock");
    const payableOwner = await PayableOwner.deploy();
    await payableOwner.deployed();

    const Money = await ethers.getContractFactory("Money");
    const tokensPerEth = 1000;
    const money = await Money.deploy(tokensPerEth, 0);
    await money.deployed();

    // transfer ownership to payableOwner
    await money.transferOwnership(payableOwner.address);

    // fund contract and schedule withdraw
    await other.sendTransaction({ to: money.address, value: ethers.utils.parseEther("1") });
    await money.connect(await ethers.getSigner(owner.address)).scheduleWithdraw(ethers.utils.parseEther("1"));

    // advance time
    await ethers.provider.send("evm_increaseTime", [48 * 3600 + 1]);
    await ethers.provider.send("evm_mine");

    // executeWithdraw called by new owner (payable contract) should succeed
    await expect(money.connect(await ethers.getSigner(payableOwner.address)).executeWithdraw()).to.not.be.reverted;

    // payableOwner should have received ETH
    expect(await ethers.provider.getBalance(payableOwner.address)).to.be.above(ethers.utils.parseEther("0"));
  });
});
