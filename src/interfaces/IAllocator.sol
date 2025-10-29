// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IAllocator {
    // Events
    // event Allocate(address indexed vault, uint256 indexed amount, address adapter);
    // event Deallocate(address indexed vault, uint256 indexed amount, address adapter);

    // Functions
    function allocate(address adapter, uint256 amount) external;
    function deallocate(address adapter, uint256 amount) external;
}
