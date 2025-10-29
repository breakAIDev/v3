// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IVaultV2} from "../../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {VaultV2} from "../../../lib/vault-v2/src/VaultV2.sol";
import {MockAlchemistAllocator} from "../mocks/MockAlchemistAllocator.sol";
import {MYTTestHelper} from "./MYTTestHelper.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";

abstract contract BaseStrategyTest is Test {
    IMYTStrategy.StrategyParams public strategyConfig;
    TestConfig public testConfig;

    // Common state variables
    address public strategy;
    address public vault;
    address public allocator;
    uint256 private _forkId;

    // Common addresses - can be overridden by child contracts
    address public admin = address(1);
    address public curator = address(2);
    address public operator = address(3);
    address public vaultDepositor = address(4);

    // Abstract functions that must be implemented by child contracts
    function getTestConfig() internal virtual returns (TestConfig memory);
    function getStrategyConfig() internal virtual returns (IMYTStrategy.StrategyParams memory);
    function createStrategy(address vault, IMYTStrategy.StrategyParams memory params) internal virtual returns (address);
    function getForkBlockNumber() internal virtual returns (uint256);
    function getRpcUrl() internal virtual returns (string memory);
    // Test configuration struct

    struct TestConfig {
        address vaultAsset;
        uint256 vaultInitialDeposit;
        uint256 absoluteCap;
        uint256 relativeCap;
        uint256 decimals;
    }

    function setUp() public virtual {
        testConfig = getTestConfig();
        strategyConfig = getStrategyConfig();

        // Fork setup
        string memory rpc = getRpcUrl();
        if (getForkBlockNumber() > 0) {
            _forkId = vm.createFork(rpc, getForkBlockNumber());
        } else {
            _forkId = vm.createFork(rpc);
        }
        vm.selectFork(_forkId);

        // Core setup
        vm.startPrank(admin);
        vault = _getVault(testConfig.vaultAsset);
        strategy = createStrategy(vault, strategyConfig);
        vm.stopPrank();

        _setUpMYT(vault, strategy, testConfig.absoluteCap, testConfig.relativeCap);
        _magicDepositToVault(vault, vaultDepositor, testConfig.vaultInitialDeposit);
        require(IVaultV2(vault).totalAssets() == testConfig.vaultInitialDeposit, "vault total assets mismatch");
        vm.makePersistent(strategy);
    }

    function _getVault(address asset) internal returns (address) {
        return address(MYTTestHelper._setupVault(asset, admin, curator));
    }

    function _setUpMYT(address _vault, address _mytStrategy, uint256 absoluteCap, uint256 relativeCap) internal {
        vm.startPrank(admin);
        allocator = address(new MockAlchemistAllocator(_vault, admin, operator));
        vm.stopPrank();

        vm.startPrank(curator);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.setIsAllocator, (allocator, true)));
        IVaultV2(_vault).setIsAllocator(allocator, true);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.addAdapter, _mytStrategy));
        IVaultV2(_vault).addAdapter(_mytStrategy);

        bytes memory idData = IMYTStrategy(_mytStrategy).getIdData();
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, absoluteCap)));
        IVaultV2(_vault).increaseAbsoluteCap(idData, absoluteCap);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, relativeCap)));
        IVaultV2(_vault).increaseRelativeCap(idData, relativeCap);

        // Validation
        require(IVaultV2(_vault).adaptersLength() == 1, "adaptersLength must be 1");
        require(IVaultV2(_vault).isAllocator(allocator), "allocator is not set");
        require(IVaultV2(_vault).isAdapter(_mytStrategy), "strategy is not set");
        bytes32 strategyId = IMYTStrategy(_mytStrategy).adapterId();
        require(IVaultV2(_vault).absoluteCap(strategyId) == absoluteCap, "absoluteCap is not set");
        require(IVaultV2(_vault).relativeCap(strategyId) == relativeCap, "relativeCap is not set");
        vm.stopPrank();
    }

    function _magicDepositToVault(address _vault, address depositor, uint256 amount) internal returns (uint256) {
        deal(address(IVaultV2(_vault).asset()), depositor, amount);
        vm.startPrank(depositor);
        TokenUtils.safeApprove(address(IVaultV2(_vault).asset()), _vault, amount);
        uint256 shares = IVaultV2(_vault).deposit(amount, depositor);
        vm.stopPrank();
        return shares;
    }

    function _vaultSubmitAndFastForward(bytes memory data) internal {
        IVaultV2(vault).submit(data);
        bytes4 selector = bytes4(data);
        vm.warp(block.timestamp + IVaultV2(vault).timelock(selector));
    }

    function test_strategy_allocate_reverts_due_to_zero_amount() public {
        uint256 amountToAllocate = 0;
        vm.startPrank(vault);
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        bytes memory prevAllocationAmount = abi.encode(0);
        vm.expectRevert(abi.encode("Zero amount"));
        IMYTStrategy(strategy).allocate(prevAllocationAmount, amountToAllocate, "", address(vault));
        vm.stopPrank();
    }

    function test_strategy_deallocate_reverts_due_to_zero_amount() public {
        uint256 amountToAllocate = 100 * 10 ** testConfig.decimals;
        uint256 amountToDeallocate = 0;
        vm.startPrank(vault);
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        bytes memory prevAllocationAmount = abi.encode(0);
        IMYTStrategy(strategy).allocate(prevAllocationAmount, amountToAllocate, "", address(vault));
        uint256 initialRealAssets = IMYTStrategy(strategy).realAssets();
        require(initialRealAssets > 0, "Initial real assets is 0");
        bytes memory prevAllocationAmount2 = abi.encode(amountToAllocate);
        vm.expectRevert(abi.encode("Zero amount"));
        IMYTStrategy(strategy).deallocate(prevAllocationAmount2, amountToDeallocate, "", address(vault));
        vm.stopPrank();
    }

    function test_strategy_deallocate(uint256 amountToAllocate, uint256 amountToDeallocate) public {
        amountToAllocate = bound(amountToAllocate, 1 * 10 ** testConfig.decimals, testConfig.vaultInitialDeposit);
        amountToDeallocate = IMYTStrategy(strategy).previewAdjustedWithdraw(amountToAllocate);
        vm.startPrank(vault);
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        bytes memory prevAllocationAmount = abi.encode(0);
        IMYTStrategy(strategy).allocate(prevAllocationAmount, amountToAllocate, "", address(vault));
        uint256 initialRealAssets = IMYTStrategy(strategy).realAssets();
        require(initialRealAssets > 0, "Initial real assets is 0");
        bytes memory prevAllocationAmount2 = abi.encode(amountToAllocate);
        (bytes32[] memory strategyIds, int256 change) = IMYTStrategy(strategy).deallocate(prevAllocationAmount2, amountToDeallocate, "", address(vault));
        assertApproxEqAbs(change, -int256(amountToDeallocate), 1 * 10 ** testConfig.decimals);
        assertGt(strategyIds.length, 0, "strategyIds is empty");
        assertEq(strategyIds[0], IMYTStrategy(strategy).adapterId(), "adapter id not in strategyIds");
        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        require(finalRealAssets < initialRealAssets, "Final real assets is not less than initial real assets");
        vm.stopPrank();
    }

    function test_vault_allocate_to_strategy(uint256 amountToAllocate) public {
        amountToAllocate = bound(amountToAllocate, 1 * 10 ** testConfig.decimals, testConfig.vaultInitialDeposit);
        vm.startPrank(allocator);
        uint256 initialVaultTotalAssets = IVaultV2(vault).totalAssets();
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        bytes memory prevAllocationAmount = abi.encode(0);
        IVaultV2(vault).allocate(strategy, prevAllocationAmount, amountToAllocate);
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = IVaultV2(vault).accrueInterestView();

        assertApproxEqAbs(IMYTStrategy(strategy).realAssets(), amountToAllocate, 1 * 10 ** testConfig.decimals);
        assertApproxEqAbs(newTotalAssets, initialVaultTotalAssets, 1 * 10 ** testConfig.decimals);
        assertEq(performanceFeeShares, 0);
        assertEq(managementFeeShares, 0);
        assertApproxEqAbs(IVaultV2(vault).totalAssets(), initialVaultTotalAssets, 1 * 10 ** testConfig.decimals);
        assertApproxEqAbs(IVaultV2(vault).firstTotalAssets(), initialVaultTotalAssets, 1 * 10 ** testConfig.decimals);
        assertApproxEqAbs(IVaultV2(vault).allocation(allocationId), amountToAllocate, 1 * 10 ** testConfig.decimals);
        vm.stopPrank();
    }

    function test_vault_deallocate_from_strategy(uint256 amountToAllocate, uint256 amountToDeallocate) public {
        amountToAllocate = bound(amountToAllocate, 1 * 10 ** testConfig.decimals, testConfig.vaultInitialDeposit);
        amountToDeallocate = IMYTStrategy(strategy).previewAdjustedWithdraw(amountToAllocate);
        vm.startPrank(allocator);
        uint256 initialVaultTotalAssets = IVaultV2(vault).totalAssets();
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        bytes memory prevAllocationAmount = abi.encode(0);
        IVaultV2(vault).allocate(strategy, prevAllocationAmount, amountToAllocate);
        uint256 currentAllocationAmount = IVaultV2(vault).allocation(allocationId);
        uint256 currentRealAssets = IMYTStrategy(strategy).realAssets();
        prevAllocationAmount = abi.encode(currentAllocationAmount);
        IVaultV2(vault).deallocate(strategy, prevAllocationAmount, amountToDeallocate);
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = IVaultV2(vault).accrueInterestView();

        assertApproxEqAbs(IMYTStrategy(strategy).realAssets(), currentRealAssets - amountToDeallocate, 1 * 10 ** testConfig.decimals);
        assertApproxEqAbs(newTotalAssets, initialVaultTotalAssets, 1 * 10 ** testConfig.decimals);
        assertEq(performanceFeeShares, 0);
        assertEq(managementFeeShares, 0);
        assertApproxEqAbs(IVaultV2(vault).totalAssets(), initialVaultTotalAssets, 1 * 10 ** testConfig.decimals);
        assertApproxEqAbs(IVaultV2(vault).firstTotalAssets(), initialVaultTotalAssets, 1 * 10 ** testConfig.decimals);
        assertApproxEqAbs(IVaultV2(vault).allocation(allocationId), amountToAllocate - amountToDeallocate, 1 * 10 ** testConfig.decimals);
        vm.stopPrank();
    }
}
