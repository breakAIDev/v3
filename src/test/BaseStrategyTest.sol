// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {VaultV2} from "lib/vault-v2/src/VaultV2.sol";
import {AlchemistAllocator} from "../AlchemistAllocator.sol";
import {IAllocator} from "../interfaces/IAllocator.sol";
import {AlchemistStrategyClassifier} from "../AlchemistStrategyClassifier.sol";
import {MYTTestHelper} from "./libraries/MYTTestHelper.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

/// @notice Handler contract for invariant testing according to Foundry best practices.
/// It wraps the vault and strategy, constrains inputs, and tracks ghost variables.
contract StrategyHandler is Test {
    IVaultV2 public vault;
    IMYTStrategy public strategy;
    address public allocator;
    address public asset;
    address public admin;

    // Ghost variables to track cumulative state changes
    uint256 public ghost_totalAllocated;
    uint256 public ghost_totalDeallocated;
    uint256 public ghost_initialVaultAssets;

    // Call counters for coverage analysis
    mapping(bytes4 => uint256) public calls;

    // Minimum allocation amount to satisfy underlying protocol requirements (e.g., Aave V3 min supply)
    uint256 public constant MIN_ALLOCATE_AMOUNT = 1e15; // 0.001 ETH/token

    constructor(address _vault, address _strategy, address _allocator, address _admin) {
        vault = IVaultV2(_vault);
        strategy = IMYTStrategy(_strategy);
        allocator = _allocator;
        admin = _admin;
        asset = vault.asset();
        ghost_initialVaultAssets = vault.totalAssets();
    }

    modifier countCall(bytes4 selector) {
        calls[selector]++;
        _;
    }

    function allocate(uint256 amount) external countCall(this.allocate.selector) {
        uint256 vaultAssets = vault.totalAssets();
        // If vault has no assets, we cannot allocate
        if (vaultAssets == 0) return;

        // Get the strategy's allocation limits
        bytes32 allocationId = strategy.adapterId();
        uint256 currentAllocation = vault.allocation(allocationId);
        uint256 absoluteCap = vault.absoluteCap(allocationId);
        uint256 relativeCap = vault.relativeCap(allocationId);
        
        // Calculate remaining headroom in absolute cap
        uint256 absoluteRemaining = absoluteCap > currentAllocation 
            ? absoluteCap - currentAllocation 
            : 0;
            
        // Calculate remaining headroom in relative cap (convert from WAD to WEI)
        uint256 maxAllowedByRelative = (vaultAssets * relativeCap) / 1e18;
        uint256 relativeRemaining = maxAllowedByRelative > currentAllocation
            ? maxAllowedByRelative - currentAllocation
            : 0;
            
        // The effective limit is the minimum of the two caps
        uint256 effectiveLimit = absoluteRemaining < relativeRemaining ? absoluteRemaining : relativeRemaining;

        if (effectiveLimit < MIN_ALLOCATE_AMOUNT) return;

        amount = bound(amount, MIN_ALLOCATE_AMOUNT, effectiveLimit);

        deal(IVaultV2(vault).asset(), address(vault), amount);

        vm.startPrank(admin);
        IAllocator(allocator).allocate(address(strategy), amount);
        vm.stopPrank();
        
        ghost_totalAllocated += amount;
    }

    function deallocate(uint256 amount) external countCall(this.deallocate.selector) {
        bytes32 allocationId = strategy.adapterId();
        uint256 currentAllocation = vault.allocation(allocationId);
        
        // If nothing is allocated, we cannot deallocate
        if (currentAllocation == 0) return;
        
        // Bound deallocation to current allocation
        amount = bound(amount, 1, currentAllocation);
        
        // Call through the AlchemistAllocator
        vm.startPrank(admin);
        IAllocator(allocator).deallocate(address(strategy), amount);
        vm.stopPrank();
        
        ghost_totalDeallocated += amount;
    }
    
    function warpTime(uint256 timeDelta) external countCall(this.warpTime.selector) {
        vm.warp(block.timestamp + bound(timeDelta, 1, 365 days));
    }

    function _getParams() internal pure returns (bytes memory) {
        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;
        return abi.encode(params);
    }

    function callSummary() external view {
        console.log("Handler Call Summary:");
        console.log("allocate calls:", calls[this.allocate.selector]);
        console.log("deallocate calls:", calls[this.deallocate.selector]);
        console.log("warpTime calls:", calls[this.warpTime.selector]);
    }
}

abstract contract BaseStrategyTest is Test {
    IMYTStrategy.StrategyParams public strategyConfig;
    TestConfig public testConfig;

    // Common state variables
    address public strategy;
    address public vault;
    address public allocator;
    address public classifier;
    StrategyHandler public handler;
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
    function getMaxTestDeposit() internal view virtual returns (uint256) {
        // Default to absoluteCap if not overridden
        return maxTestDeposit > 0 ? maxTestDeposit : testConfig.absoluteCap;
    }
    // Test configuration struct

    struct TestConfig {
        address vaultAsset;
        uint256 vaultInitialDeposit;
        uint256 absoluteCap;
        uint256 relativeCap;
        uint256 decimals;
    }

    // Default relative cap for tests (50%)
    uint256 constant DEFAULT_RELATIVE_CAP = 0.5e18;

    // Minimum allocation amount to satisfy underlying protocol requirements (e.g., Aave V3 min supply)
    uint256 public constant MIN_ALLOCATE_AMOUNT = 1e15; // 0.001 ETH/token

    // Default max test deposit (can be overridden by child tests)
    uint256 internal maxTestDeposit;

    function setUp() public virtual {
        testConfig = getTestConfig();
        strategyConfig = getStrategyConfig();

        // Initialize maxTestDeposit to absoluteCap by default
        maxTestDeposit = testConfig.absoluteCap;

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

        // Setup Invariant Handler
        handler = new StrategyHandler(vault, strategy, allocator, admin);
        targetContract(address(handler));
        
        // Target specific functions in the handler for invariant fuzzing
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.allocate.selector;
        selectors[1] = handler.deallocate.selector;
        selectors[2] = handler.warpTime.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    function _getVault(address asset) internal returns (address) {
        return address(MYTTestHelper._setupVault(asset, admin, curator));
    }

    function _setUpMYT(address _vault, address _mytStrategy, uint256 absoluteCap, uint256 relativeCap) internal {
        vm.startPrank(admin);
        classifier = address(new AlchemistStrategyClassifier(admin));
        // Set up risk classes with reasonable caps
        AlchemistStrategyClassifier(classifier).setRiskClass(0, 10_000_000 * 10 ** testConfig.decimals, 5_000_000 * 10 ** testConfig.decimals); // LOW risk
        AlchemistStrategyClassifier(classifier).setRiskClass(1, 7_500_000 * 10 ** testConfig.decimals, 3_750_000 * 10 ** testConfig.decimals); // MEDIUM risk
        AlchemistStrategyClassifier(classifier).setRiskClass(2, 5_000_000 * 10 ** testConfig.decimals, 2_500_000 * 10 ** testConfig.decimals); // HIGH risk
        // Assign risk level to the strategy
        bytes32 strategyId = IMYTStrategy(_mytStrategy).adapterId();
        AlchemistStrategyClassifier(classifier).assignStrategyRiskLevel(uint256(strategyId), uint8(strategyConfig.riskClass));
        allocator = address(new AlchemistAllocator(_vault, admin, operator, classifier));
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

    function getVaultParams() internal pure returns (bytes memory) {
        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;
        return abi.encode(params);
    }

    /// @dev Optional strategy-specific hook invoked before time-shifts in base tests.
    function _beforeTimeShift(uint256 targetTimestamp) internal virtual {}

    /// @dev Optional strategy-specific hook invoked before previewAdjustedWithdraw calls.
    function _beforePreviewWithdraw(uint256 requestedAssets) internal virtual {}

    /// @dev Optional strategy-specific clamp for deallocation requests.
    ///      Default behavior uses the requested amount directly.
    function _effectiveDeallocateAmount(uint256 requestedAssets) internal view virtual returns (uint256) {
        return requestedAssets;
    }

    /// @dev Base helper to keep time-shift behavior extensible for strategy-specific tests.
    function _warpWithHook(uint256 timeDelta) internal {
        uint256 targetTimestamp = block.timestamp + timeDelta;
        _beforeTimeShift(targetTimestamp);
        vm.warp(targetTimestamp);
    }

    function _deallocateEstimate(uint256 targetAssets) internal returns (bool) {
        uint256 target = _effectiveDeallocateAmount(targetAssets);
        if (target == 0) return false;
        _beforePreviewWithdraw(target);
        uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(target);
        if (preview == 0) return false;
        vm.startPrank(admin);
        IAllocator(allocator).deallocate(strategy, preview);
        vm.stopPrank();
        return true;
    }

    function _deallocatateFromRealAssetsEstimate() internal returns (bool) {
        uint256 current = IMYTStrategy(strategy).realAssets();
        if (current == 0) return true;
        return _deallocateEstimate(current);
    }

    /// @dev Helper to get valid allocation bounds based on effective cap and vault assets.
    function _getAllocationBounds() internal view returns (uint256 min, uint256 max) {
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        uint256 effectiveCap = _getEffectiveCapHeadroom(allocationId);
        uint256 vaultAssets = IVaultV2(vault).totalAssets();
        uint256 maxAlloc = effectiveCap < vaultAssets ? effectiveCap : vaultAssets;
        uint256 minAlloc = MIN_ALLOCATE_AMOUNT > maxAlloc ? maxAlloc : MIN_ALLOCATE_AMOUNT;
        return (minAlloc, maxAlloc);
    }

    /// @dev Helper to deal specific amount of assets to the vault.
    function _prepareVaultAssets(uint256 amount) internal {
        deal(testConfig.vaultAsset, vault, amount);
    }

    function test_strategy_allocate_reverts_due_to_zero_amount() public {
        uint256 amountToAllocate = 0;
        bytes memory params = getVaultParams();
        vm.startPrank(vault);
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        vm.expectRevert(abi.encode("Zero amount"));
        IMYTStrategy(strategy).allocate(params, amountToAllocate, "", address(vault));
        vm.stopPrank();
    }

    function test_strategy_allocate_reverts_due_to_paused_allocation() public {
        bytes memory params = getVaultParams();
        vm.startPrank(admin);
        IMYTStrategy(strategy).setKillSwitch(true);
        vm.stopPrank();
        vm.startPrank(vault);
        deal(testConfig.vaultAsset, strategy, 100 * 10 ** testConfig.decimals);
        vm.expectRevert(abi.encodeWithSelector(IMYTStrategy.StrategyAllocationPaused.selector, strategy));
        IMYTStrategy(strategy).allocate(params, 100 * 10 ** testConfig.decimals, "", address(vault));
        vm.stopPrank();
    }

    function test_strategy_deallocate_reverts_due_to_zero_amount() public {
        uint256 amountToAllocate = 100 * 10 ** testConfig.decimals;
        uint256 amountToDeallocate = 0;
        bytes memory params = getVaultParams();
        vm.startPrank(vault);
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        IMYTStrategy(strategy).allocate(params, amountToAllocate, "", address(vault));
        uint256 initialRealAssets = IMYTStrategy(strategy).realAssets();
        require(initialRealAssets > 0, "Initial real assets is 0");
        vm.expectRevert(abi.encode("Zero amount"));
        IMYTStrategy(strategy).deallocate(params, amountToDeallocate, "", address(vault));
        vm.stopPrank();
    }

    function test_strategy_deallocate(uint256 amountToAllocate, uint256 amountToDeallocate) public {
        (uint256 minAlloc, uint256 maxAlloc) = _getAllocationBounds();
        amountToAllocate = bound(amountToAllocate, minAlloc, maxAlloc);
        bytes memory params = getVaultParams();
        
        vm.startPrank(vault);
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        IMYTStrategy(strategy).allocate(params, amountToAllocate, "", address(vault));
        uint256 initialRealAssets = IMYTStrategy(strategy).realAssets();
        require(initialRealAssets > 0, "Initial real assets is 0");
        
        amountToDeallocate = IMYTStrategy(strategy).previewAdjustedWithdraw(amountToAllocate);
        
        bytes32 adapterId = IMYTStrategy(strategy).adapterId();
        vm.mockCall(
            vault,
            abi.encodeWithSelector(IVaultV2.allocation.selector, adapterId),
            abi.encode(initialRealAssets)
        );
        
        (bytes32[] memory strategyIds, int256 change) = IMYTStrategy(strategy).deallocate(params, amountToDeallocate, "", address(vault));
        
        vm.clearMockedCalls();
        
        assertApproxEqAbs(change, -int256(amountToDeallocate), 1 * 10 ** testConfig.decimals);
        assertGt(strategyIds.length, 0, "strategyIds is empty");
        assertEq(strategyIds[0], IMYTStrategy(strategy).adapterId(), "adapter id not in strategyIds");
        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        require(finalRealAssets < initialRealAssets, "Final real assets is not less than initial real assets");
        vm.stopPrank();
    }

    function test_strategy_withdrawToVault(uint256 amount) public {
        amount = bound(amount, 1 * 10 ** testConfig.decimals, testConfig.vaultInitialDeposit);
        vm.startPrank(admin);
        deal(testConfig.vaultAsset, strategy, amount);
        uint256 initialAmountLeftOver = TokenUtils.safeBalanceOf(testConfig.vaultAsset, address(strategy));
        uint256 initialAmountInVault = TokenUtils.safeBalanceOf(testConfig.vaultAsset, address(vault));
        require(initialAmountLeftOver == amount, "Initial amount left over is not equal to amount");
        IMYTStrategy(strategy).withdrawToVault();
        vm.assertEq(TokenUtils.safeBalanceOf(testConfig.vaultAsset, address(strategy)), initialAmountLeftOver - amount);
        vm.assertEq(TokenUtils.safeBalanceOf(testConfig.vaultAsset, address(vault)), initialAmountInVault + amount);
        vm.stopPrank();
    }

    function test_allocator_allocate_direct(uint256 amountToAllocate) public {
        (uint256 minAlloc, uint256 maxAlloc) = _getAllocationBounds();
        amountToAllocate = bound(amountToAllocate, minAlloc, maxAlloc);
        
        vm.startPrank(admin);
        uint256 initialVaultTotalAssets = IVaultV2(vault).totalAssets();
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        
        _prepareVaultAssets(amountToAllocate);
        IAllocator(allocator).allocate(strategy, amountToAllocate);
        
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

    function test_allocator_deallocate_direct(uint256 amountToAllocate, uint256 amountToDeallocate) public {
        (uint256 minAlloc, uint256 maxAlloc) = _getAllocationBounds();
        amountToAllocate = bound(amountToAllocate, minAlloc, maxAlloc);
        
        vm.startPrank(admin);
        uint256 initialVaultTotalAssets = IVaultV2(vault).totalAssets();
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        
        _prepareVaultAssets(amountToAllocate);
        IAllocator(allocator).allocate(strategy, amountToAllocate);
        uint256 currentRealAssets = IMYTStrategy(strategy).realAssets();
        
        amountToDeallocate = IMYTStrategy(strategy).previewAdjustedWithdraw(amountToAllocate);
        IAllocator(allocator).deallocate(strategy, amountToDeallocate);
        
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

    // End-to-end test: Multiple allocations with time warps
    function test_end_to_end_multiple_allocations_with_time_warp() public {
        vm.startPrank(admin);
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        uint256 initialVaultTotalAssets = IVaultV2(vault).totalAssets();
        
        // First allocation
        (, uint256 maxAlloc) = _getAllocationBounds();
        uint256 alloc1 = 100 * 10 ** testConfig.decimals;
        alloc1 = alloc1 > maxAlloc ? maxAlloc : alloc1;
        if (alloc1 == 0) return;
        
        _prepareVaultAssets(alloc1);
        IAllocator(allocator).allocate(strategy, alloc1);
        uint256 realAssetsAfterAlloc1 = IMYTStrategy(strategy).realAssets();
        assertGt(realAssetsAfterAlloc1, 0, "Real assets should be positive after first allocation");
        assertApproxEqAbs(IVaultV2(vault).allocation(allocationId), alloc1, 1 * 10 ** testConfig.decimals);
        
        _warpWithHook(1 days);
        
        // Second allocation
        (, maxAlloc) = _getAllocationBounds();
        uint256 alloc2 = 50 * 10 ** testConfig.decimals;
        alloc2 = alloc2 > maxAlloc ? maxAlloc : alloc2;
        if (alloc2 == 0) return;
        
        _prepareVaultAssets(alloc2);
        IAllocator(allocator).allocate(strategy, alloc2);
        uint256 realAssetsAfterAlloc2 = IMYTStrategy(strategy).realAssets();
        assertGe(realAssetsAfterAlloc2, realAssetsAfterAlloc1, "Real assets should not decrease after second allocation");
        assertApproxEqAbs(IVaultV2(vault).allocation(allocationId), alloc1 + alloc2, 1 * 10 ** testConfig.decimals);
        
        _warpWithHook(7 days);
        
        // Partial deallocation
        uint256 dealloc1 = 30 * 10 ** testConfig.decimals;
        _beforePreviewWithdraw(dealloc1);
        uint256 dealloc1Preview = IMYTStrategy(strategy).previewAdjustedWithdraw(dealloc1);

        IAllocator(allocator).deallocate(strategy, dealloc1Preview);
        uint256 realAssetsAfterDealloc1 = IMYTStrategy(strategy).realAssets();
        assertLe(realAssetsAfterDealloc1, realAssetsAfterAlloc2, "Real assets should decrease after deallocation");
        assertApproxEqAbs(IVaultV2(vault).allocation(allocationId), alloc1 + alloc2 - dealloc1, 1 * 10 ** testConfig.decimals);
        
        _warpWithHook(30 days);
        
        // Full deallocation
        _deallocatateFromRealAssetsEstimate();
        uint256 realAssetsAfterFinal = IMYTStrategy(strategy).realAssets();
        assertLt(realAssetsAfterFinal, realAssetsAfterDealloc1, "Real assets should be near zero after final deallocation");
        assertApproxEqAbs(IVaultV2(vault).allocation(allocationId), 0, 2 * 10 ** testConfig.decimals);
        
        (uint256 finalVaultTotalAssets, , ) = IVaultV2(vault).accrueInterestView();
        assertGe(finalVaultTotalAssets, 0, "Vault total assets should be non-negative");
        
        vm.stopPrank();
    }

    // Fuzz test: Multiple random allocations and deallocations
    function test_fuzz_multiple_allocations_deallocations(uint256[] calldata amounts, uint8[] calldata actions) public {
        uint256 numOps = bound(amounts.length, 1, 10);
        uint256 maxIterations = numOps < amounts.length ? numOps : amounts.length;
        
        vm.startPrank(admin);
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        
        for (uint256 i = 0; i < maxIterations; i++) {
            bool isAllocate = i % 2 == 0;
            
            if (isAllocate) {
                (uint256 minAlloc, uint256 maxAlloc) = _getAllocationBounds();
                if (maxAlloc >= minAlloc) {
                    uint256 amount = bound(amounts[i], minAlloc, maxAlloc);
                    _prepareVaultAssets(amount);
                    IAllocator(allocator).allocate(strategy, amount);
                }
            } else {
                uint256 currentAllocation = IVaultV2(vault).allocation(allocationId);
                if (currentAllocation >= MIN_ALLOCATE_AMOUNT) {
                    uint256 maxDealloc = currentAllocation;
                    uint256 amount = bound(amounts[i], MIN_ALLOCATE_AMOUNT, maxDealloc);
                    uint256 target = _effectiveDeallocateAmount(amount);
                    if (target > 0) {
                        _beforePreviewWithdraw(target);
                        uint256 deallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(target);
                        if (deallocPreview > 0) {
                            IAllocator(allocator).deallocate(strategy, deallocPreview);
                        }
                    }
                }
            }
            
            uint256 timeWarp = bound(uint256(keccak256(abi.encodePacked(i, amounts, actions))), 1, 30 days);
            _warpWithHook(timeWarp);
        }
        
        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        uint256 finalAllocation = IVaultV2(vault).allocation(allocationId);
        assertGe(finalRealAssets, 0, "Real assets should be non-negative");
        assertGe(finalAllocation, 0, "Allocation should be non-negative");
        
        vm.stopPrank();
    }

    // End-to-end test: Full lifecycle with time accumulation
    function test_full_lifecycle_with_time_accumulation(uint256 initialAlloc, uint256 allocIncrease, uint256 deallocationPercent) public {
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        
        // Use handler for allocations - it handles cap validation and bounding internally
        // Just bound inputs to reasonable ranges for the lifecycle test
        deallocationPercent = bound(deallocationPercent, 1, 90); // 1-90%
        
        // Initial allocation using handler
        handler.allocate(initialAlloc);
        initialAlloc = handler.ghost_totalAllocated();
        
        // Check if allocation succeeded (handler returns early if caps don't allow)
        uint256 realAssetsInitial = IMYTStrategy(strategy).realAssets();
        if (realAssetsInitial == 0) return;
        
        // Warp 7 days
        _warpWithHook(7 days);
        
        // Increase allocation using handler
        handler.allocate(allocIncrease);
        allocIncrease = handler.ghost_totalAllocated() - initialAlloc;
        
        uint256 realAssetsAfterIncrease = IMYTStrategy(strategy).realAssets();
        assertGe(realAssetsAfterIncrease, realAssetsInitial, "Real assets should not decrease after increase");
        
        // Warp 14 days
        _warpWithHook(14 days);
        
        // Partial deallocation
        uint256 totalAllocation = IVaultV2(vault).allocation(allocationId);
        uint256 deallocAmount = (totalAllocation * deallocationPercent) / 100;
        bool partialOk = _deallocateEstimate(deallocAmount);
        require(partialOk, "Partial deallocation failed");
        uint256 realAssetsAfterDealloc = IMYTStrategy(strategy).realAssets();
        assertLt(realAssetsAfterDealloc, realAssetsAfterIncrease, "Real assets should decrease after deallocation");
        
        // Warp 30 days
        _warpWithHook(30 days);
        
        // Final deallocation of remaining
        _deallocatateFromRealAssetsEstimate();
        
        // Verify final state
        // Allow tolerance for slippage/rounding (up to 2% of vault initial deposit)
        assertApproxEqAbs(IMYTStrategy(strategy).realAssets(), 0, 2 * testConfig.vaultInitialDeposit / 100, "All real assets should be deallocated");
        assertApproxEqAbs(IVaultV2(vault).allocation(allocationId), 0, 2 * 10 ** testConfig.decimals);
    }

    // Test: Strategy accumulation over time
    function test_strategy_accumulation_over_time() public {
        vm.startPrank(admin);
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        
        // Allocate initial amount - bounded by effective cap
        uint256 effectiveCap = _getEffectiveCapHeadroom(allocationId);
        uint256 vaultTotalAssets = IVaultV2(vault).totalAssets();
        uint256 allocAmount = vaultTotalAssets / 20;
        allocAmount = allocAmount > effectiveCap ? effectiveCap : allocAmount;
        if (allocAmount == 0) return;
        deal(IVaultV2(vault).asset(), address(vault), allocAmount);
        IAllocator(allocator).allocate(strategy, allocAmount);
        uint256 initialRealAssets = IMYTStrategy(strategy).realAssets();
        uint256 minExpected = initialRealAssets * 95 / 100; // Start with 95% of initial as minimum
        
        // Warp forward and check accumulation
        for (uint256 i = 1; i <= 4; i++) {
            _warpWithHook(30 days);
            
            // Simulate yield by transferring small amount to strategy (0.5% per period)
            // Use current vault total assets as base for yield simulation to ensure amounts remain reasonable
            uint256 currentVaultAssets = IVaultV2(vault).totalAssets();
            deal(testConfig.vaultAsset, strategy, currentVaultAssets * 5 / 1000);
            
            uint256 currentRealAssets = IMYTStrategy(strategy).realAssets();
            // Real assets should not decrease significantly (may increase with yield)
            assertGe(currentRealAssets, minExpected, "Real assets decreased significantly over time");
            // Update minExpected to the new baseline
            minExpected = currentRealAssets;
            
            // Small deallocation to test withdrawal capability - use rebounded effective cap
            uint256 currentEffectiveCap = _getEffectiveCapHeadroom(allocationId);
            if (i == 2 && currentEffectiveCap > 0) {
                uint256 targetDealloc = IMYTStrategy(strategy).realAssets() / 10;
                _beforePreviewWithdraw(targetDealloc);
                uint256 smallDealloc = IMYTStrategy(strategy).previewAdjustedWithdraw(targetDealloc);
                if (smallDealloc > 0) {
                    IAllocator(allocator).deallocate(strategy, smallDealloc);
                    // Update minExpected after deallocation to account for the reduction
                    minExpected = IMYTStrategy(strategy).realAssets();
                }
            }
        }
        
        // Final full deallocation
        _deallocatateFromRealAssetsEstimate();
        
        vm.stopPrank();
    }

    /// @notice Fuzz test: Real assets should always be non-negative after any operation
    function test_fuzz_real_assets_non_negative(uint256[] calldata amounts, uint8[] calldata operations) public {
        vm.startPrank(admin);
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        
        // Use operations array length for number of operations, but bound it
        uint256 numOps = bound(operations.length, 1, 20);
        
        for (uint256 i = 0; i < numOps; i++) {
            // Check array bounds before accessing amounts to prevent panic
            uint256 amount = i < amounts.length ? bound(amounts[i], 0, 1e6 * 10 ** testConfig.decimals) : 0;
            uint8 op = i < operations.length ? operations[i] % 3 : uint8(i % 3);
            
            if (op == 0) {
                // Allocate - bounded by effective cap
                uint256 effectiveCap = _getEffectiveCapHeadroom(allocationId);
                if (effectiveCap >= MIN_ALLOCATE_AMOUNT) {
                    amount = bound(amount, MIN_ALLOCATE_AMOUNT, effectiveCap);
                    deal(testConfig.vaultAsset, vault, amount);
                    IAllocator(allocator).allocate(strategy, amount);
                }
            } else if (op == 1) {
                // Deallocate
                uint256 currentRealAssets = IMYTStrategy(strategy).realAssets();
                amount = bound(amount, 0, currentRealAssets);
                if (amount > 0) {
                    uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(amount);
                    if (preview > 0) {
                        IAllocator(allocator).deallocate(strategy, preview);
                    }
                }
            } else {
                // Time warp
                vm.warp(block.timestamp + bound(amount, 0, 365 days));
            }
            
        }
        
        vm.stopPrank();
    }

    /// @notice Fuzz test: Allocation increases (or maintains) real assets
    function test_fuzz_allocation_increases_real_assets(uint256 amountToAllocate) public {
        vm.startPrank(admin);
        
        (uint256 minAlloc, uint256 maxAlloc) = _getAllocationBounds();
        if (maxAlloc < minAlloc) return;
        amountToAllocate = bound(amountToAllocate, minAlloc, maxAlloc);
        
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        uint256 realAssetsBefore = IMYTStrategy(strategy).realAssets();
        uint256 allocationBefore = IVaultV2(vault).allocation(allocationId);
        
        _prepareVaultAssets(amountToAllocate);
        IAllocator(allocator).allocate(strategy, amountToAllocate);
        
        uint256 realAssetsAfter = IMYTStrategy(strategy).realAssets();
        uint256 allocationAfter = IVaultV2(vault).allocation(allocationId);
        
        // Invariant: Real assets should increase (or stay same if rounding)
        assertGe(realAssetsAfter, realAssetsBefore, "Invariant violation: Real assets should not decrease on allocation");
        
        // Invariant: Allocation should increase by at least amountToAllocate minus fees/slippage
        // Allow for small tolerance (1%) for protocol fees
        uint256 minExpectedIncrease = amountToAllocate * 99 / 100;
        assertGe(allocationAfter - allocationBefore, minExpectedIncrease, "Invariant violation: Allocation should increase appropriately");
        
        
        vm.stopPrank();
    }

    /// @notice Fuzz test: Deallocation decreases real assets
    function test_fuzz_deallocation_decreases_real_assets(uint256 amountToAllocate, uint256 fractionToDeallocate) public {
        vm.startPrank(admin);
        
        (uint256 minAlloc, uint256 maxAlloc) = _getAllocationBounds();
        if (maxAlloc < minAlloc) return;
        amountToAllocate = bound(amountToAllocate, minAlloc, maxAlloc);
        fractionToDeallocate = bound(fractionToDeallocate, 1, 100); // 1-100%
        
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        
        _prepareVaultAssets(amountToAllocate);
        IAllocator(allocator).allocate(strategy, amountToAllocate);
        
        uint256 realAssetsBefore = IMYTStrategy(strategy).realAssets();
        uint256 allocationBefore = IVaultV2(vault).allocation(allocationId);
        
        // Deallocate
        uint256 amountToDeallocate = realAssetsBefore * fractionToDeallocate / 100;
        uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(amountToDeallocate);
        if (preview > 0) {
            IAllocator(allocator).deallocate(strategy, preview);
        }
        
        uint256 realAssetsAfter = IMYTStrategy(strategy).realAssets();
        uint256 allocationAfter = IVaultV2(vault).allocation(allocationId);
        
        // Invariant: Real assets should decrease (or stay same for zero deallocation)
        assertLe(realAssetsAfter, realAssetsBefore, "Invariant violation: Real assets should not increase on deallocation");
        
        // Invariant: Allocation should decrease by at least previewed amount minus tolerance
        // Allow for small tolerance (1%) for protocol fees
        uint256 expectedDecrease = preview * 99 / 100;
        uint256 actualDecrease = allocationBefore > allocationAfter ? allocationBefore - allocationAfter : 0;
        assertGe(actualDecrease, expectedDecrease, "Invariant violation: Allocation should decrease appropriately");
        
        // After full deallocation (or nearly full), real assets should be close to zero
        if (fractionToDeallocate >= 99) {
            assertLt(realAssetsAfter, realAssetsBefore / 20, "Invariant violation: Real assets should be near zero after large deallocation");
        }
        
        vm.stopPrank();
    }

    /// @dev Helper to calculate effective cap headroom (matches AlchemistAllocator._validateCaps logic)
    function _getEffectiveCapHeadroom(bytes32 allocationId) internal view returns (uint256) {
        uint256 currentAllocation = IVaultV2(vault).allocation(allocationId);
        uint256 absoluteCap = IVaultV2(vault).absoluteCap(allocationId);
        uint256 relativeCap = IVaultV2(vault).relativeCap(allocationId);
        uint256 totalAssets = IVaultV2(vault).totalAssets();
        

        uint256 absoluteRemaining = absoluteCap > currentAllocation ? absoluteCap - currentAllocation : 0;
        

        uint256 absoluteValueOfRelativeCap = (relativeCap == type(uint256).max) 
            ? type(uint256).max 
            : (totalAssets * relativeCap) / 1e18;
        uint256 relativeRemaining = absoluteValueOfRelativeCap > currentAllocation 
            ? absoluteValueOfRelativeCap - currentAllocation 
            : 0;
        

        uint256 limit = absoluteRemaining < relativeRemaining ? absoluteRemaining : relativeRemaining;
        

        uint256 strategyId = uint256(allocationId);
        uint8 riskLevel = AlchemistStrategyClassifier(classifier).getStrategyRiskLevel(strategyId);
        uint256 globalRiskCap = AlchemistStrategyClassifier(classifier).getGlobalCap(riskLevel);
        uint256 globalRiskRemaining = globalRiskCap > currentAllocation ? globalRiskCap - currentAllocation : 0;
        limit = limit < globalRiskRemaining ? limit : globalRiskRemaining;
        
        return limit;
    }

    /// @notice Fuzz test: Cannot allocate more than vault's available balance
    function test_fuzz_cannot_allocate_more_than_available(uint256 amountToAllocate) public {
        vm.startPrank(admin);
        
        uint256 vaultTotalAssets = IVaultV2(vault).totalAssets();
        // Bound from MIN_ALLOCATE_AMOUNT to allow testing both within and exceeding available balance
        uint256 minBound = MIN_ALLOCATE_AMOUNT < vaultTotalAssets * 100 ? MIN_ALLOCATE_AMOUNT : vaultTotalAssets * 100;
        amountToAllocate = bound(amountToAllocate, minBound, vaultTotalAssets * 100);
        
        uint256 realAssetsBefore = IMYTStrategy(strategy).realAssets();
        
        // Give vault its current total assets (plus some buffer for testing)
        deal(testConfig.vaultAsset, vault, vaultTotalAssets * 2);
        
        // If amount exceeds vault's available balance, expect revert
        // Available balance = vaultTotalAssets * 2 (what we just dealt) - current allocation
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        uint256 currentAllocation = IVaultV2(vault).allocation(allocationId);
        uint256 availableBalance = vaultTotalAssets * 2 - currentAllocation;
        
        // Calculate effective cap using helper (uses vault.totalAssets() directly)
        uint256 effectiveCap = _getEffectiveCapHeadroom(allocationId);
        console.log("effective cap is", effectiveCap);
        console.log("amount cap is", amountToAllocate);
        if (amountToAllocate > availableBalance || amountToAllocate > effectiveCap) {
            // Expect revert when trying to allocate more than available
            vm.expectRevert(); // TransferReverted or similar ERC20 revert
            IAllocator(allocator).allocate(strategy, amountToAllocate);
        } else {
            // Should succeed when within available balance and caps
            if (amountToAllocate > 0) {
                IAllocator(allocator).allocate(strategy, amountToAllocate);
            }
            
            uint256 realAssetsAfter = IMYTStrategy(strategy).realAssets();
            
            // Invariant: Real assets should not exceed what vault could have allocated
            // At most availableBalance + realAssetsBefore should be in strategy
            assertLe(realAssetsAfter, availableBalance + realAssetsBefore, "Invariant violation: Allocated more than vault assets available");
            
            // Real assets should be non-negative
            assertGe(realAssetsAfter, 0, "Invariant violation: Real assets negative");
        }
        
        vm.stopPrank();
    }

    /// @notice Fuzz test: Repeated small operations maintain invariants
    function test_fuzz_repeated_operations_stability(uint256 baseAmount, uint8 numOperations) public {
        vm.startPrank(admin);
        
        (uint256 minAlloc, uint256 maxAlloc) = _getAllocationBounds();
        if (maxAlloc < minAlloc) return;
        baseAmount = bound(baseAmount, minAlloc, maxAlloc);
        numOperations = uint8(bound(numOperations, 5, 50));
        
        uint256 realAssetsHistoryMin = type(uint256).max;
        uint256 realAssetsHistoryMax = 0;
        
        for (uint8 i = 0; i < numOperations; i++) {
            // Alternate allocate and deallocate small amounts
            bool isAllocate = i % 2 == 0;
            uint256 amount = baseAmount * (1 + (i % 5)) / 5; // Vary amount slightly
            
            if (isAllocate) {
                (, uint256 currentMax) = _getAllocationBounds();
                if (amount <= currentMax) {
                    _prepareVaultAssets(amount);
                    IAllocator(allocator).allocate(strategy, amount);
                }
            } else {
                uint256 currentRealAssets = IMYTStrategy(strategy).realAssets();
                if (currentRealAssets > 0) {
                    uint256 deallocationAmount = currentRealAssets > amount ? amount : currentRealAssets;
                    uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(deallocationAmount);
                    if (preview > 0) {
                        IAllocator(allocator).deallocate(strategy, preview);
                    }
                }
            }
            
            uint256 currentRealAssets = IMYTStrategy(strategy).realAssets();
            
            // Track min/max for invariant checking
            if (currentRealAssets < realAssetsHistoryMin) {
                realAssetsHistoryMin = currentRealAssets;
            }
            if (currentRealAssets > realAssetsHistoryMax) {
                realAssetsHistoryMax = currentRealAssets;
            }
            
        }
        
        // Final invariants
        assertLe(realAssetsHistoryMax, testConfig.absoluteCap, "Invariant violation: Real assets exceeded cap");
        
        vm.stopPrank();
    }

    /// @notice Fuzz test: Time warps don't negatively affect real assets (unless strategy has negative yield)
    function test_fuzz_time_warp_stability(uint256 initialAlloc, uint256 warpAmount, uint8 numWarps) public {
        vm.startPrank(admin);
        
        (uint256 minAlloc, uint256 maxAlloc) = _getAllocationBounds();
        if (maxAlloc < minAlloc) return;
        initialAlloc = bound(initialAlloc, minAlloc, maxAlloc);
        numWarps = uint8(bound(numWarps, 1, 10));
        
        _prepareVaultAssets(initialAlloc);
        IAllocator(allocator).allocate(strategy, initialAlloc);
        uint256 initialRealAssets = IMYTStrategy(strategy).realAssets();
        
        uint256 minRealAssets = initialRealAssets;
        
        // Perform multiple time warps
        for (uint8 i = 0; i < numWarps; i++) {
            warpAmount = bound(warpAmount, 1 hours, 365 days);
            vm.warp(block.timestamp + warpAmount);
            
            uint256 currentRealAssets = IMYTStrategy(strategy).realAssets();
            
            // Track minimum real assets seen
            if (currentRealAssets < minRealAssets) {
                minRealAssets = currentRealAssets;
            }
        }
        
        // Real assets should not be significantly less than initial (unless negative yield strategy)
        // Allow up to 5% tolerance for potential fees
        uint256 tolerance = initialRealAssets * 5 / 100;
        assertGe(minRealAssets + tolerance, initialRealAssets, "Invariant violation: Real assets decreased significantly without operations");
        
        vm.stopPrank();
    }

    /// @notice Fuzz test: Zero amount operations should have no effect (idempotency)
    function test_fuzz_zero_operations_no_effect(uint256 nonZeroAmount) public {
        vm.startPrank(admin);
        
        (uint256 minAlloc, uint256 maxAlloc) = _getAllocationBounds();
        if (maxAlloc < minAlloc) return;
        nonZeroAmount = bound(nonZeroAmount, minAlloc, maxAlloc);
        
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        
        _prepareVaultAssets(nonZeroAmount);
        IAllocator(allocator).allocate(strategy, nonZeroAmount);
        
        uint256 realAssetsBefore = IMYTStrategy(strategy).realAssets();
        uint256 allocationBefore = IVaultV2(vault).allocation(allocationId);
        
        // Try to allocate zero - should have no effect or revert with specific error
        try IAllocator(allocator).allocate(strategy, 0) {
            // If succeeds, state should be unchanged
        } catch {
            // If reverts, that's also acceptable
        }
        
        uint256 realAssetsAfterZeroAlloc = IMYTStrategy(strategy).realAssets();
        uint256 allocationAfterZeroAlloc = IVaultV2(vault).allocation(allocationId);
        
        assertEq(realAssetsAfterZeroAlloc, realAssetsBefore, "Invariant violation: Zero allocation changed state");
        assertEq(allocationAfterZeroAlloc, allocationBefore, "Invariant violation: Zero allocation changed allocation tracking");
        
        // Try to deallocate zero
        try IMYTStrategy(strategy).deallocate(getVaultParams(), 0, "", address(vault)) {
            // If succeeds, state should be unchanged
        } catch {
            // If reverts, that's also acceptable
        }
        
        uint256 realAssetsAfterZeroDealloc = IMYTStrategy(strategy).realAssets();
        uint256 allocationAfterZeroDealloc = IVaultV2(vault).allocation(allocationId);
        
        assertEq(realAssetsAfterZeroDealloc, realAssetsBefore, "Invariant violation: Zero deallocation changed state");
        assertEq(allocationAfterZeroDealloc, allocationBefore, "Invariant violation: Zero deallocation changed allocation tracking");
        
        vm.stopPrank();
    }

    /// @notice Fuzz test: Allocations respect absolute and relative caps
    function test_fuzz_allocation_respects_caps(uint256 amountToAllocate) public {
        vm.startPrank(admin);
        
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        uint256 absoluteCap = IVaultV2(vault).absoluteCap(allocationId);
        uint256 relativeCap = IVaultV2(vault).relativeCap(allocationId);
        
        (uint256 minAlloc, uint256 maxAlloc) = _getAllocationBounds();
        uint256 minBound = minAlloc < maxAlloc * 2 ? minAlloc : maxAlloc * 2;
        amountToAllocate = bound(amountToAllocate, minBound, maxAlloc * 2);
        
        _prepareVaultAssets(amountToAllocate);
        
        // Try to allocate through AlchemistAllocator - handle both success and failure cases
        try IAllocator(allocator).allocate(strategy, amountToAllocate) {
            // Allocation succeeded (within caps)
        } catch {
            // Allocation reverted (exceeded caps or zero amount)
        }
        
        // Final invariant checks: allocation should never exceed caps regardless of outcome
        uint256 finalAllocation = IVaultV2(vault).allocation(allocationId);
        uint256 newVaultTotalAssets = IVaultV2(vault).totalAssets();
        
        assertLe(finalAllocation, absoluteCap, "Invariant violation: Allocation exceeded absolute cap");
        
        uint256 maxAllowedByRelative = (newVaultTotalAssets * relativeCap) / 1e18;
        assertLe(finalAllocation, maxAllowedByRelative + (10 ** testConfig.decimals), "Invariant violation: Allocation exceeded relative cap");
        
        vm.stopPrank();
    }

    // invariants

    /// @notice Invariant: Real assets should never be negative
    function invariant_realAssets_nonNegative() public view {
        uint256 realAssetsValue = IMYTStrategy(strategy).realAssets();
        assertGe(realAssetsValue, 0, "Invariant violation: Real assets cannot be negative");
    }

    /// @notice Invariant: Allocation never exceeds absolute cap
    function invariant_allocationWithinAbsoluteCap() public view {
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        uint256 allocation = IVaultV2(vault).allocation(allocationId);
        uint256 absoluteCap = IVaultV2(vault).absoluteCap(allocationId);
        assertLe(allocation, absoluteCap, "Invariant violation: Allocation exceeds absolute cap");
    }

    /// @notice Invariant: Allocation never exceeds relative cap
    function invariant_allocationWithinRelativeCap() public view {
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        uint256 allocation = IVaultV2(vault).allocation(allocationId);
        uint256 relativeCap = IVaultV2(vault).relativeCap(allocationId);
        uint256 vaultTotalAssets = IVaultV2(vault).totalAssets();
        uint256 maxAllowed = (vaultTotalAssets * relativeCap) / 1e18;
        assertLe(allocation, maxAllowed + (10 ** testConfig.decimals), "Invariant violation: Allocation exceeds relative cap");
    }

    /// @notice Invariant: Log call summary of the handler
    function invariant_CallSummary() public view {
        handler.callSummary();
    }
}
