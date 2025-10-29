// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVaultV2} from "../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {PermissionedProxy} from "./utils/PermissionedProxy.sol";
import {IAllocator} from "./interfaces/IAllocator.sol";
import {IMYTStrategy} from "./interfaces/IMYTStrategy.sol";

/**
 * @title AlchemistAllocator
 * @notice This contract is used to allocate and deallocate funds to and from MYT strategies
 * @notice The MYT is a Morpho V2 Vault, and each strategy is just a vault adapter which interfaces with a third party protocol
 */
contract AlchemistAllocator is PermissionedProxy, IAllocator {
    IVaultV2 immutable vault;

    constructor(address _vault, address _admin, address _operator) PermissionedProxy(_admin, _operator) {
        require(IVaultV2(_vault).asset() != address(0), "IV");
        vault = IVaultV2(_vault);

        // allocate(address adapter, bytes memory data, uint256 assets)
        permissionedCalls[0x5c9ce04d] = true;
        // deallocate(address adapter, bytes memory data, uint256 assets)
        permissionedCalls[0x4b219d16] = true;
    }

    // Overriden vault actions
    function allocate(address adapter, uint256 amount) external {
        require(msg.sender == admin || operators[msg.sender], "PD");
        bytes32 id = IMYTStrategy(adapter).adapterId();
        uint256 absoluteCap = vault.absoluteCap(id);
        uint256 relativeCap = vault.relativeCap(id);
        // FIXME get this from the StrategyClassificationProxy for the respective risk class
        uint256 daoTarget = type(uint256).max;
        uint256 adjusted = absoluteCap > relativeCap ? absoluteCap : relativeCap;
        if (msg.sender != admin) {
            // caller is operator
            adjusted = adjusted > daoTarget ? adjusted : daoTarget;
        }
        // pass the old allocation to the adapter
        bytes memory oldAllocation = abi.encode(vault.allocation(id));
        vault.allocate(adapter, oldAllocation, amount);
    }

    /// @notice When deallocating total amounts,
    /// consider using IMYTStrategy(address(strategy)).previewAdjustedWithdraw(amount)
    /// as the amount to be passed in for `amount`
    /// to estimate the correct amount that can be fully withdrawn,
    /// accounting for losses due to slippage, protocol fees, and rounding differences
    function deallocate(address adapter, uint256 amount) external {
        require(msg.sender == admin || operators[msg.sender], "PD");
        bytes32 id = IMYTStrategy(adapter).adapterId();
        uint256 absoluteCap = vault.absoluteCap(id);
        uint256 relativeCap = vault.relativeCap(id);
        // FIXME get this from the StrategyClassificationProxy for the respective risk class
        uint256 daoTarget = type(uint256).max;
        uint256 adjusted = absoluteCap < relativeCap ? absoluteCap : relativeCap;
        if (msg.sender != admin) {
            // caller is operator
            adjusted = adjusted < daoTarget ? adjusted : daoTarget;
        }
        // pass the old allocation to the adapter
        bytes memory oldAllocation = abi.encode(vault.allocation(id));
        vault.deallocate(adapter, oldAllocation, amount);
    }
}
