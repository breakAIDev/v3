// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

contract PermissionedProxy {
    address admin;
    mapping (address => bool) operators;
    mapping (bytes4 => bool) permissionedCalls;

    constructor(address _admin, address _operator) {
        require(_admin != address(0), "zero");
        require(_operator != address(0), "zero");
        admin = _admin;
        operators[_operator] = true;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "PD");
        _;
    }

    modifier onlyOperator() {
        require(operators[msg.sender], "PD");
        _;
    }

    event AdminUpdated(address indexed admin);
    event OperatorUpdated(address indexed operator);
    event AddedPermissionedCall(bytes4 indexed sig);

    function setAdmin(address _admin) external onlyAdmin {
        require(_admin != address(0), "zero");
        admin = _admin;
        emit AdminUpdated(_admin);
    }

    function setOperator(address _operator, bool value) external onlyAdmin {
        require(_operator != address(0), "zero");
        operators[_operator] = value;
        emit OperatorUpdated(_operator);
    }

    function setPermissionedCall(bytes4 sig, bool value) external onlyAdmin {
        permissionedCalls[sig] = value;
        emit AddedPermissionedCall(sig);
    }

    function proxy(address vault, bytes memory data) external payable onlyAdmin {
        bytes4 selector;
        require(data.length >= 4, "SEL");
        assembly {
          selector := mload(add(data, 32))
        }
        require(!permissionedCalls[selector], "PD");

        (bool success, ) = vault.call{value: msg.value}(data);
        require(success, "failed");
    }
}
