// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract PayableOwnerMock {
    bool public didReceive;
    receive() external payable {
        didReceive = true;
    }

    function forwardCall(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        require(ok, "call failed");
        return ret;
    }
}
