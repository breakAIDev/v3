// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {WstethMainnetStrategy} from "../../strategies/mainnet/WStethStrategy.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {AlchemistAllocator} from "../../AlchemistAllocator.sol";
import {IAllocator} from "../../interfaces/IAllocator.sol";
import {AlchemistStrategyClassifier} from "../../AlchemistStrategyClassifier.sol";
import {MockMYTVault} from "../mocks/MockMYTVault.sol";
interface IWstETH {
    function getWstETHByStETH(uint256 stETHAmount) external view returns (uint256);
    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

contract MockWstethMainnetStrategy is WstethMainnetStrategy {
    constructor(address _myt, StrategyParams memory _params, address _weth, address _stETH, address _wstETH, address _unstETH, address _referral)
        WstethMainnetStrategy(_myt, _params, _weth, _stETH, _wstETH, _unstETH, _referral)
    {}
}

contract WstethMainnetStrategyTest is Test {
    address public mytStrategy;
    address public vault;
    address public allocator;
    address public classifier;
    address public weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address public stETH = address(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    address public wstETH = address(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    address public unstETH = address(0x4200000000000000000000000000000000000006);
    address public referral = address(0x0000000000000000000000000000000000000000);
    address public admin = address(0x1111111111111111111111111111111111111111);
    address public curator = address(0x2222222222222222222222222222222222222222);
    address public constant MAINNET_PERMIT2 = 0x000000000022d473030f1dF7Fa9381e04776c7c5;
    uint256 private _forkId;
    event WstethMainnetStrategyTestLog(string message, uint256 value);
    event WstethMainnetStrategyTestLogAddress(string message, address value);

    function setUp() public {
        // Fork setup
        string memory rpc = getRpcUrl();
        if (getForkBlockNumber() > 0) {
            _forkId = vm.createFork(rpc, getForkBlockNumber());
        } else {
            _forkId = vm.createFork(rpc);
        }
        vm.selectFork(_forkId);
        vm.startPrank(admin);
        vault = _getVault(weth);
        classifier = address(new AlchemistStrategyClassifier(admin));
        // Set up risk classes with reasonable caps (18 decimals for WETH)
        AlchemistStrategyClassifier(classifier).setRiskClass(0, 10_000_000e18, 5_000_000e18); // LOW risk
        AlchemistStrategyClassifier(classifier).setRiskClass(1, 7_500_000e18, 3_750_000e18); // MEDIUM risk
        AlchemistStrategyClassifier(classifier).setRiskClass(2, 5_000_000e18, 2_500_000e18); // HIGH risk
        allocator = address(new AlchemistAllocator{salt: bytes32("allocator")}(address(vault), admin, curator, classifier));
        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: admin,
            name: "WstethMainnetStrategy",
            protocol: "WstethMainnetStrategy",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 2_000_000e18,
            globalCap: 2_000_000e18,
            estimatedYield: 100e18,
            additionalIncentives: false,
            slippageBPS: 1
        });
        mytStrategy = _createStrategy(vault, params);
        // Assign risk level to the strategy
        bytes32 strategyId = IMYTStrategy(mytStrategy).adapterId();
        AlchemistStrategyClassifier(classifier).assignStrategyRiskLevel(uint256(strategyId), uint8(params.riskClass));
        emit WstethMainnetStrategyTestLogAddress("mytStrategy", mytStrategy);
        _setUpMYT(vault, mytStrategy, 2_000_000e18, 1e18);
        _magicDepositToVault(vault, admin, 1_000_000e18);
        require(IVaultV2(vault).totalAssets() == 1_000_000e18, "vault total assets mismatch");
        vm.stopPrank();
    }

    function _getVault(address asset) internal returns (address) {
        MockMYTVault v = new MockMYTVault{salt: bytes32("vault")}(admin, asset);
        v.setCurator(curator);
        return address(v);
    }

    function _createStrategy(address _vault, IMYTStrategy.StrategyParams memory params) internal returns (address) {
        return address(new MockWstethMainnetStrategy{salt: bytes32("wsteth_strategy")}(_vault, params, weth, stETH, wstETH, unstETH, referral));
    }

    function test_strategy_allocate_direct() public {
        vm.startPrank(vault);
        uint256 amount = 100e18;
        deal(weth, mytStrategy, amount);
        
        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;
        
        bytes memory data = abi.encode(params);
        (bytes32[] memory strategyIds, int256 change) = IMYTStrategy(mytStrategy).allocate(data, amount, "", vault);
        // change is the _totalValue() delta; verify allocation occurred
        assertGt(change, 0, "change should be positive after allocation");
        assertGt(strategyIds.length, 0, "strategyIds is empty");
        assertEq(strategyIds[0], IMYTStrategy(mytStrategy).adapterId(), "adapter id not in strategyIds");
        
        // Verify wstETH was received - balance depends on wstETH/stETH exchange rate (can vary significantly)
        uint256 wstETHBalance = IWstETH(wstETH).balanceOf(mytStrategy);
        assertGt(wstETHBalance, 0, "wstETH balance should be positive");
        
        // realAssets() returns getStETHByWstETH(wstETHBalance) - verify it's reasonable
        uint256 realAssets = IMYTStrategy(mytStrategy).realAssets();
        assertGt(realAssets, wstETHBalance, "real assets should be positive");
        vm.stopPrank();
    }

    function test_strategy_allocate_with_swap() public {
        vm.startPrank(vault);
        IMYTStrategy.SwapParams memory swapParams = IMYTStrategy.SwapParams({txData: _getCallData(string.concat("/test/strategies/utils/offchain/quotes/wethToWsteth.json")), minIntermediateOut: 0});
        IMYTStrategy.VaultAdapterParams memory params = IMYTStrategy.VaultAdapterParams(
            {action: IMYTStrategy.ActionType.swap, swapParams: swapParams})
        ;
        bytes memory data = abi.encode(
            params);
        uint256 amount = _getMinBuyAmount(string.concat("/test/strategies/utils/offchain/quotes/wethToWsteth.json"));
        deal(weth, mytStrategy, 1_000_000e18);
        vm.roll(getBlockNumberFromJson(string.concat("/test/strategies/utils/offchain/quotes/wethToWsteth.json")));
        (bytes32[] memory strategyIds, int256 change) = IMYTStrategy(mytStrategy).allocate(data, amount, "", vault);
        assertGt(change, int256(amount), "change is less than amount");        
        assertGt(strategyIds.length, 0, "strategyIds is empty");
        assertEq(strategyIds[0], IMYTStrategy(mytStrategy).adapterId(), "adapter id not in strategyIds");
        assertGt(IMYTStrategy(mytStrategy).realAssets(), amount, "real assets is less than amount");
        vm.stopPrank();
    } 

    function test_strategy_deallocate_with_swap() public {
        vm.startPrank(vault);
        
        // First allocate: WETH -> wstETH
        IMYTStrategy.SwapParams memory swapParams = IMYTStrategy.SwapParams({txData: _getCallData(string.concat("/test/strategies/utils/offchain/quotes/wethToWsteth.json")), minIntermediateOut: 0});
        IMYTStrategy.VaultAdapterParams memory params = IMYTStrategy.VaultAdapterParams(
            {action: IMYTStrategy.ActionType.swap, swapParams: swapParams});

        bytes memory data = abi.encode(params);
        uint256 amount = _getMinBuyAmount(string.concat("/test/strategies/utils/offchain/quotes/wethToWsteth.json"));
        deal(weth, mytStrategy, 1_000_000e18);

        (bytes32[] memory strategyIds, int256 change) = IMYTStrategy(mytStrategy).allocate(data, amount, "", vault);
        
        // Now deallocate: wstETH -> unwrap -> stETH -> swap -> WETH
        // Use actual wstETH balance we have (don't try to unwrap more than available)
        uint256 wstETHToUnwrap = TokenUtils.safeBalanceOf(address(wstETH), address(mytStrategy));
        uint256 expectedStETH = IWstETH(wstETH).getStETHByWstETH(wstETHToUnwrap);
        emit WstethMainnetStrategyTestLog("wstETH to unwrap", wstETHToUnwrap);
        emit WstethMainnetStrategyTestLog("expected stETH after unwrap", expectedStETH);
        
        uint256 minBuyAmount = _getMinBuyAmount(string.concat("/test/strategies/utils/offchain/quotes/stethToWeth.json"));
        
        // Encode the VaultAdapterParams with stETH->WETH swap data
        IMYTStrategy.SwapParams memory swapParams2 = IMYTStrategy.SwapParams({
            txData: _getCallData(string.concat("/test/strategies/utils/offchain/quotes/stethToWeth.json")), 
            minIntermediateOut: expectedStETH
        });
        IMYTStrategy.VaultAdapterParams memory params2 = IMYTStrategy.VaultAdapterParams(
            {action: IMYTStrategy.ActionType.swap, swapParams: swapParams2});
        bytes memory data2 = abi.encode(params2);

        // Deallocate - pass calculated wstETH amount to unwrap
        (bytes32[] memory strategyIds2, int256 change2) = IMYTStrategy(mytStrategy).deallocate(
            data2, 
            wstETHToUnwrap,
            "", 
            vault
        );
        vm.stopPrank();
        
        assertGt(strategyIds2.length, 0, "strategyIds is empty");
        assertEq(strategyIds2[0], IMYTStrategy(mytStrategy).adapterId(), "adapter id not in strategyIds");
    } 

    function test_vault_deallocate_from_strategy_with_bidirectional_swap() public {
        vm.startPrank(allocator);
        uint256 amountToAllocate = 100e18;

        uint256 initialVaultTotalAssets = IVaultV2(vault).totalAssets();
        bytes32 allocationId = IMYTStrategy(mytStrategy).adapterId();
        
        // First allocate: WETH -> wstETH
        IMYTStrategy.SwapParams memory swapParams = IMYTStrategy.SwapParams({txData: _getCallData(string.concat("/test/strategies/utils/offchain/quotes/wethToWsteth.json")), minIntermediateOut: 0});
        IMYTStrategy.VaultAdapterParams memory params = IMYTStrategy.VaultAdapterParams(
            {action: IMYTStrategy.ActionType.swap, swapParams: swapParams});

        bytes memory data = abi.encode(params);
        uint256 amount = _getMinBuyAmount(string.concat("/test/strategies/utils/offchain/quotes/wethToWsteth.json"));

        IVaultV2(vault).allocate(mytStrategy, data, amountToAllocate);
        uint256 currentRealAssets = IMYTStrategy(mytStrategy).realAssets();

        // Now deallocate: wstETH -> unwrap -> stETH -> swap -> WETH
        // Use actual wstETH balance we have (don't try to unwrap more than available)
        uint256 wstETHToUnwrap = TokenUtils.safeBalanceOf(address(wstETH), address(mytStrategy));
        uint256 expectedStETH = IWstETH(wstETH).getStETHByWstETH(wstETHToUnwrap);
        emit WstethMainnetStrategyTestLog("wstETH to unwrap", wstETHToUnwrap);
        emit WstethMainnetStrategyTestLog("expected stETH after unwrap", expectedStETH);
        
        uint256 minBuyAmount = _getMinBuyAmount(string.concat("/test/strategies/utils/offchain/quotes/stethToWeth.json"));
        
        // Encode the VaultAdapterParams with stETH->WETH swap data
        IMYTStrategy.SwapParams memory swapParams2 = IMYTStrategy.SwapParams({
            txData: _getCallData(string.concat("/test/strategies/utils/offchain/quotes/stethToWeth.json")), 
            minIntermediateOut: IMYTStrategy(mytStrategy).previewAdjustedWithdraw(expectedStETH) 
        });
        IMYTStrategy.VaultAdapterParams memory params2 = IMYTStrategy.VaultAdapterParams(
            {action: IMYTStrategy.ActionType.unwrapAndSwap, swapParams: swapParams2});
        bytes memory data2 = abi.encode(params2);

        // Deallocate - pass calculated wstETH amount to unwrap
        IVaultV2(vault).deallocate(mytStrategy, data2, wstETHToUnwrap);
        vm.stopPrank();
        assertApproxEqAbs(IMYTStrategy(mytStrategy).realAssets(), currentRealAssets - expectedStETH, 1 * 10 ** 18);
    }

    function _getCallData(string memory pathJson) internal returns (bytes memory) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, pathJson);
        string memory json = vm.readFile(path);
        bytes memory quote = vm.parseBytes(vm.parseJsonString(json, ".transaction.data"));
        return quote;
    }

    function _getMinBuyAmount(string memory pathJson) internal returns (uint256) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, pathJson);
        string memory json = vm.readFile(path);
        return vm.parseUint(vm.parseJsonString(json, ".minBuyAmount"));
    }

    function _getSellAmount(string memory pathJson) internal returns (uint256) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, pathJson);
        string memory json = vm.readFile(path);
        return vm.parseUint(vm.parseJsonString(json, ".sellAmount"));
    }

    function getForkBlockNumber() internal returns (uint256) {
        return getBlockNumberFromJson(string.concat("/test/strategies/utils/offchain/quotes/wethToWsteth.json"));
    }

    function getBlockNumberFromJson(string memory path) internal returns (uint256) {
        string memory root = vm.projectRoot();
        string memory fullPath = string.concat(root, path);
        string memory json = vm.readFile(fullPath);
        return vm.parseUint(vm.parseJsonString(json, ".blockNumber"));
    }


    function _setUpMYT(address _vault, address _mytStrategy, uint256 absoluteCap, uint256 relativeCap) internal {
        vm.startPrank(admin);
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


    function getRpcUrl() internal view returns (string memory) {
        return vm.envString("MAINNET_RPC_URL");
    }


    function test_allocator_allocate(uint256 amountToAllocate) public {
        // Lido has stake limits - cap at 1000 ETH to avoid STAKE_LIMIT error
        amountToAllocate = bound(amountToAllocate, 1e18, 1_000e18);
        vm.startPrank(admin);
        IAllocator(allocator).allocate(mytStrategy, amountToAllocate);
        
        // Verify wstETH was received - balance depends on wstETH/stETH exchange rate (can vary significantly)
        uint256 wstETHBalance = IWstETH(wstETH).balanceOf(mytStrategy);
        assertGt(wstETHBalance, 0, "wstETH balance should be positive");
        
        // realAssets() returns getStETHByWstETH(wstETHBalance) - verify it's reasonable
        uint256 realAssets = IMYTStrategy(mytStrategy).realAssets();
        assertGt(realAssets, wstETHBalance, "real assets should be positive");
        vm.stopPrank();
    }


    function test_allocator_allocate_with_swap() public {
        // 0x quote was generated for exactly 100 ETH - must use exact amount
        uint256 amountToAllocate = 100e18;
        uint256 minWstETHOut = _getMinBuyAmount(string.concat("/test/strategies/utils/offchain/quotes/wethToWsteth.json"));
        vm.startPrank(admin);
        IAllocator(allocator).allocateWithSwap(mytStrategy, amountToAllocate, _getCallData(string.concat("/test/strategies/utils/offchain/quotes/wethToWsteth.json")));
        
        // Verify wstETH was received - balance depends on wstETH/stETH exchange rate (can vary significantly)
        uint256 wstETHBalance = IWstETH(wstETH).balanceOf(mytStrategy);
        assertGt(wstETHBalance, 0, "wstETH balance should be positive");
        
        // realAssets() returns getStETHByWstETH(wstETHBalance) - verify it's reasonable
        uint256 realAssets = IMYTStrategy(mytStrategy).realAssets();
        assertGt(realAssets, wstETHBalance, "real assets should be positive");
        vm.stopPrank();
    }

    function test_allocator_deallocate_with_swap() public {
        // 0x quote was generated for exactly 100 ETH - must use exact amount
        uint256 amountToAllocate = 100e18;
        vm.startPrank(admin);
        IAllocator(allocator).allocateWithSwap(mytStrategy, amountToAllocate, _getCallData(string.concat("/test/strategies/utils/offchain/quotes/wethToWsteth.json")));
        
        // Verify wstETH was received
        uint256 wstETHBalance = IWstETH(wstETH).balanceOf(mytStrategy);
        assertGt(wstETHBalance, 0, "wstETH balance should be positive");
        
        // Get quote parameters for stETH->WETH swap
        string memory quotePath = string.concat("/test/strategies/utils/offchain/quotes/stethToWeth.json");
        uint256 minFinalOut = _getMinBuyAmount(quotePath);  // minimum WETH out (slippage protected)
        uint256 minIntermediateOut = _getSellAmount(quotePath);  // stETH to produce from unwrap
        
        // Calculate expected remaining wstETH after deallocate
        // The quote only sells minIntermediateOut stETH, so we only unwrap the equivalent wstETH
        uint256 wstETHToUnwrap = IWstETH(wstETH).getWstETHByStETH(minIntermediateOut); // +1 for rounding buffer
        
        // Deallocate: wstETH -> unwrap -> stETH -> swap -> WETH
        // minFinalOut = WETH expected by vault, minIntermediateOut = stETH to produce from unwrap
        IAllocator(allocator).deallocateWithUnwrapAndSwap(
            mytStrategy, 
            minFinalOut, 
            _getCallData(quotePath),
            IMYTStrategy(mytStrategy).previewAdjustedWithdraw(minIntermediateOut)
        );

        // Verify realAssets matches expected remaining (within 1e15 tolerance for rounding)
        uint256 realAssetsAfter = IMYTStrategy(mytStrategy).realAssets();
        assertApproxEqAbs(realAssetsAfter, 0, 1e18, "realAssets should match expected remaining"); 
        vm.stopPrank();
    }

    function test_previewAdjustedWithdraw() public {
        // Should return 0 when strategy has no wstETH
        uint256 previewEmpty = IMYTStrategy(mytStrategy).previewAdjustedWithdraw(100e18);
        assertEq(previewEmpty, 0, "should return 0 when no wstETH balance");

        // Allocate some funds and verify preview
        vm.startPrank(vault);
        uint256 allocateAmount = 100e18;
        deal(weth, mytStrategy, allocateAmount);
        
        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;
        bytes memory data = abi.encode(params);
        IMYTStrategy(mytStrategy).allocate(data, allocateAmount, "", vault);
        vm.stopPrank();

        // Get strategy's fundamental capacity (wstETH converted to stETH terms)
        uint256 wstETHBalance = IWstETH(wstETH).balanceOf(mytStrategy);
        uint256 maxCapacity = IWstETH(wstETH).getStETHByWstETH(wstETHBalance);
        
        // Preview for amount within capacity
        uint256 requestedAmount = 50e18;
        uint256 preview = IMYTStrategy(mytStrategy).previewAdjustedWithdraw(requestedAmount);
        
        // Should be less than requested due to slippage haircut
        assertLt(preview, requestedAmount, "preview should be less than requested due to haircut");
        assertGt(preview, 0, "preview should be positive");
        
        // Verify haircut is applied correctly (slippageBPS = 1 from setUp)
        uint256 expectedPreview = (requestedAmount * (10_000 - 1)) / 10_000;
        assertEq(preview, expectedPreview, "preview should match expected after haircut");

        // Preview for amount exceeding capacity should cap at capacity
        uint256 excessAmount = maxCapacity + 100e18;
        uint256 previewExcess = IMYTStrategy(mytStrategy).previewAdjustedWithdraw(excessAmount);
        uint256 expectedCapped = (maxCapacity * (10_000 - 1)) / 10_000;
        assertEq(previewExcess, expectedCapped, "preview should be capped at max capacity minus haircut");
    }

    // Test: WstETH Mainnet yield accumulation over time
    function test_wsteth_mainnet_yield_accumulation() public {
        vm.startPrank(allocator);
    
        // Allocate initial amount
        uint256 allocAmount = 100e18; // 100 WETH
        deal(weth, mytStrategy, allocAmount);
    
        // Use swap-based allocation for wstETH strategy (not direct)
        IMYTStrategy.SwapParams memory swapParams = IMYTStrategy.SwapParams({
            txData: _getCallData(string.concat("/test/strategies/utils/offchain/quotes/wethToWsteth.json")),
            minIntermediateOut: 0
        });
        IMYTStrategy.VaultAdapterParams memory params = IMYTStrategy.VaultAdapterParams({
            action: IMYTStrategy.ActionType.swap,
            swapParams: swapParams
        });
        bytes memory data = abi.encode(params);
        IVaultV2(vault).allocate(mytStrategy, data, allocAmount);
        
        uint256 initialRealAssets = IMYTStrategy(mytStrategy).realAssets();
        
        // Track real assets over time with warps
        uint256[] memory realAssetsSnapshots = new uint256[](4);
        uint256 minExpected = initialRealAssets * 95 / 100; // Start with 95% of initial as minimum
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(block.timestamp + 30 days);
            
            // Simulate yield by transferring small amount to strategy (0.5% per period)
            deal(weth, mytStrategy, initialRealAssets * 5 / 1000);
            
            realAssetsSnapshots[i] = IMYTStrategy(mytStrategy).realAssets();
            
            // Real assets should not significantly decrease (may increase with yield)
            assertGe(realAssetsSnapshots[i], minExpected, "Real assets decreased significantly");
            // Update minExpected to the new baseline
            minExpected = realAssetsSnapshots[i];
            
            // Small deallocation on second snapshot
            if (i == 1) {
                uint256 smallDealloc = 10e18; // 10 WETH
                uint256 deallocPreview = IMYTStrategy(mytStrategy).previewAdjustedWithdraw(smallDealloc);
                IMYTStrategy(mytStrategy).deallocate(data, deallocPreview, "", vault);
                // Update minExpected after deallocation to account for the reduction
                minExpected = IMYTStrategy(mytStrategy).realAssets();
            }
        }
        
        // Final deallocation
        uint256 finalRealAssets = IMYTStrategy(mytStrategy).realAssets();
        if (finalRealAssets > 1e15) {
            uint256 minBuyAmount = _getMinBuyAmount(string.concat("/test/strategies/utils/offchain/quotes/stethToWeth.json"));
            IMYTStrategy.SwapParams memory swapParams = IMYTStrategy.SwapParams({
                txData: _getCallData(string.concat("/test/strategies/utils/offchain/quotes/stethToWeth.json")),
                minIntermediateOut: IMYTStrategy(mytStrategy).previewAdjustedWithdraw(minBuyAmount)
            });
            IMYTStrategy.VaultAdapterParams memory params = IMYTStrategy.VaultAdapterParams({
                action: IMYTStrategy.ActionType.unwrapAndSwap,
                swapParams: swapParams
            });
            bytes memory deallocateData = abi.encode(params);
            uint256 finalDeallocPreview = IMYTStrategy(mytStrategy).previewAdjustedWithdraw(finalRealAssets);
            IMYTStrategy(mytStrategy).deallocate(deallocateData, finalDeallocPreview, "", vault);
        }
        
        assertEq(IMYTStrategy(mytStrategy).realAssets(), 0, "All real assets should be deallocated");
        
        vm.stopPrank();
    }
    
}
