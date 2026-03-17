// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {WstethMainnetStrategy} from "../../strategies/mainnet/WStethStrategy.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {AlchemistAllocator} from "../../AlchemistAllocator.sol";
import {IAllocator} from "../../interfaces/IAllocator.sol";
import {AlchemistStrategyClassifier} from "../../AlchemistStrategyClassifier.sol";
import {MockMYTVault} from "../mocks/MockMYTVault.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";
interface IWstETH {
    function getWstETHByStETH(uint256 stETHAmount) external view returns (uint256);
    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Simple allowanceHolder mock that simulates swap output by
/// transferring a fixed token amount to caller on any call.
contract MockSwapExecutor {
    IERC20 public immutable token;
    uint256 public amountToTransfer;

    constructor(address _token, uint256 _amountToTransfer) {
        token = IERC20(_token);
        amountToTransfer = _amountToTransfer;
    }

    fallback() external {
        token.transfer(msg.sender, amountToTransfer);
    }
}

contract MockWstethMainnetStrategy is WstethMainnetStrategy {
    constructor(
        address _myt,
        StrategyParams memory _params,
        address _weth,
        address _stETH,
        address _wstETH,
        address _stEthEthOracle
    )
        WstethMainnetStrategy(_myt, _params, _weth, _stETH, _wstETH, _stEthEthOracle)
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
    address public stEthEthOracle = address(0x86392dC19c0b719886221c78AB11eb8Cf5c52812);
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
        return address(
            new MockWstethMainnetStrategy{salt: bytes32("wsteth_strategy")}(
                _vault, params, weth, stETH, wstETH, stEthEthOracle
            )
        );
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
        
        uint256 amount = 100e18;
        deal(weth, mytStrategy, 1_000_000e18);
        
        IMYTStrategy.SwapParams memory swapParams = IMYTStrategy.SwapParams({
            txData: getWethToWstethCalldata(mytStrategy, amount), 
            minIntermediateOut: 0
        });
        IMYTStrategy.VaultAdapterParams memory params = IMYTStrategy.VaultAdapterParams({
            action: IMYTStrategy.ActionType.swap, 
            swapParams: swapParams
        });
        bytes memory data = abi.encode(params);
        
        (bytes32[] memory strategyIds, int256 change) = IMYTStrategy(mytStrategy).allocate(data, amount, "", vault);
        
        // Verify basic success
        assertGt(strategyIds.length, 0, "strategyIds is empty");
        assertEq(strategyIds[0], IMYTStrategy(mytStrategy).adapterId(), "adapter id not in strategyIds");
        
        // Verify change is positive and roughly matches input (accounting for slippage/fees)
        // Since we swap WETH -> wstETH (which is worth > 1 ETH), and _totalValue converts back to stETH terms,
        // the change should be close to the input amount (slightly less due to swap fees/slippage).
        assertGt(change, int256(amount) - 1e18, "change should be close to input amount"); 
        assertGt(IMYTStrategy(mytStrategy).realAssets(), 0, "real assets should be positive");
        vm.stopPrank();
    } 


    function test_strategy_deallocate_with_swap() public {
        vm.startPrank(vault);
        
        // First allocate: WETH -> wstETH
        uint256 amount = 100e18;
        deal(weth, mytStrategy, amount);
        
        IMYTStrategy.SwapParams memory swapParams = IMYTStrategy.SwapParams({
            txData: getWethToWstethCalldata(mytStrategy, amount), 
            minIntermediateOut: 0
        });
        IMYTStrategy.VaultAdapterParams memory params = IMYTStrategy.VaultAdapterParams({
            action: IMYTStrategy.ActionType.swap, 
            swapParams: swapParams
        });

        bytes memory data = abi.encode(params);

        (bytes32[] memory strategyIds, int256 change) = IMYTStrategy(mytStrategy).allocate(data, amount, "", vault);
        
        // Now deallocate: wstETH -> unwrap -> stETH -> swap -> WETH
        // Use actual wstETH balance we have (don't try to unwrap more than available)
        uint256 wstETHToUnwrap = TokenUtils.safeBalanceOf(address(wstETH), address(mytStrategy));
        uint256 expectedStETH = IWstETH(wstETH).getStETHByWstETH(wstETHToUnwrap);
        emit WstethMainnetStrategyTestLog("wstETH to unwrap", wstETHToUnwrap);
        emit WstethMainnetStrategyTestLog("expected stETH after unwrap", expectedStETH);
        
        // Encode the VaultAdapterParams with stETH->WETH swap data
        IMYTStrategy.SwapParams memory swapParams2 = IMYTStrategy.SwapParams({
            txData: getStethToWethCalldata(address(mytStrategy), expectedStETH), 
            minIntermediateOut: expectedStETH
        });
        IMYTStrategy.VaultAdapterParams memory params2 = IMYTStrategy.VaultAdapterParams({
            action: IMYTStrategy.ActionType.unwrapAndSwap, 
            swapParams: swapParams2
        });
        bytes memory data2 = abi.encode(params2);

        // Use previewAdjustedWithdraw to get a reasonable expected WETH output
        // This accounts for slippage and gives us a valid minimum for the dexSwap check
        // Apply additional 1% buffer for swap execution variability (DEX slippage, fees)
        uint256 expectedWethOut = IMYTStrategy(mytStrategy).previewAdjustedWithdraw(expectedStETH);
        expectedWethOut = (expectedWethOut * 9900) / 10000;
        
        // Deallocate - pass expected WETH output with slippage adjustment
        (bytes32[] memory strategyIds2, int256 change2) = IMYTStrategy(mytStrategy).deallocate(
            data2, 
            expectedWethOut,
            "", 
            vault
        );
        vm.stopPrank();
        
        assertGt(strategyIds2.length, 0, "strategyIds is empty");
        assertEq(strategyIds2[0], IMYTStrategy(mytStrategy).adapterId(), "adapter id not in strategyIds");
    }

    function test_strategy_deallocate_with_mocked_dex_swap() public {
        vm.startPrank(vault);
        uint256 allocateAmount = 100e18;
        deal(weth, mytStrategy, allocateAmount);

        IMYTStrategy.VaultAdapterParams memory allocParams;
        allocParams.action = IMYTStrategy.ActionType.direct;
        IMYTStrategy(mytStrategy).allocate(abi.encode(allocParams), allocateAmount, "", vault);
        vm.stopPrank();

        uint256 expectedOut = 5e18;
        MockSwapExecutor mockSwap = new MockSwapExecutor(weth, expectedOut);
        deal(weth, address(mockSwap), expectedOut);

        vm.prank(admin);
        MYTStrategy(mytStrategy).setAllowanceHolder(address(mockSwap));

        vm.startPrank(vault);
        
        // Calculate wstETH amount that corresponds to expectedOut (what mock returns)
        uint256 wstETHToDeallocate = IWstETH(wstETH).getWstETHByStETH(expectedOut);

        IMYTStrategy.SwapParams memory swapParams = IMYTStrategy.SwapParams({txData: hex"01", minIntermediateOut: expectedOut});
        IMYTStrategy.VaultAdapterParams memory deallocParams =
            IMYTStrategy.VaultAdapterParams({action: IMYTStrategy.ActionType.unwrapAndSwap, swapParams: swapParams});

        (bytes32[] memory strategyIds,) = IMYTStrategy(mytStrategy).deallocate(
            abi.encode(deallocParams), wstETHToDeallocate, "", vault
        );
        vm.stopPrank();

        assertGt(strategyIds.length, 0, "strategyIds is empty");
        assertEq(strategyIds[0], IMYTStrategy(mytStrategy).adapterId(), "adapter id not in strategyIds");
        // Vault allowance is set based on the wstETH amount being deallocated
        assertEq(IERC20(weth).allowance(mytStrategy, vault), wstETHToDeallocate, "vault allowance should equal wstETH deallocated");
        // Strategy receives the mocked WETH output from the swap
        assertEq(IERC20(weth).balanceOf(mytStrategy), expectedOut, "strategy should receive mocked WETH output");
    }

    function test_strategy_deallocate_with_mocked_dex_swap_reverts_when_under_min_out() public {
        vm.startPrank(vault);
        uint256 allocateAmount = 100e18;
        deal(weth, mytStrategy, allocateAmount);

        IMYTStrategy.VaultAdapterParams memory allocParams;
        allocParams.action = IMYTStrategy.ActionType.direct;
        IMYTStrategy(mytStrategy).allocate(abi.encode(allocParams), allocateAmount, "", vault);
        vm.stopPrank();

        uint256 requiredOut = 5e18;
        uint256 mockedOut = requiredOut - 1;
        MockSwapExecutor mockSwap = new MockSwapExecutor(weth, mockedOut);
        deal(weth, address(mockSwap), mockedOut);

        vm.prank(admin);
        MYTStrategy(mytStrategy).setAllowanceHolder(address(mockSwap));

        vm.startPrank(vault);
        uint256 wstETHBalance = IWstETH(wstETH).balanceOf(mytStrategy);
        uint256 expectedStETH = IWstETH(wstETH).getStETHByWstETH(wstETHBalance);

        IMYTStrategy.SwapParams memory swapParams = IMYTStrategy.SwapParams({txData: hex"01", minIntermediateOut: expectedStETH});
        IMYTStrategy.VaultAdapterParams memory deallocParams =
            IMYTStrategy.VaultAdapterParams({action: IMYTStrategy.ActionType.unwrapAndSwap, swapParams: swapParams});

        vm.expectRevert(abi.encodeWithSelector(IMYTStrategy.InvalidAmount.selector, requiredOut, mockedOut));
        IMYTStrategy(mytStrategy).deallocate(abi.encode(deallocParams), requiredOut, "", vault);
        vm.stopPrank();
    }

    function test_strategy_allocate_with_mocked_dex_swap() public {
        uint256 expectedWstethOut = 7e18;
        MockSwapExecutor mockSwap = new MockSwapExecutor(wstETH, expectedWstethOut);
        deal(wstETH, address(mockSwap), expectedWstethOut);

        vm.prank(admin);
        MYTStrategy(mytStrategy).setAllowanceHolder(address(mockSwap));

        vm.startPrank(vault);
        uint256 amountIn = 5e18;
        deal(weth, mytStrategy, amountIn);

        IMYTStrategy.SwapParams memory swapParams = IMYTStrategy.SwapParams({txData: hex"01", minIntermediateOut: 0});
        IMYTStrategy.VaultAdapterParams memory allocParams =
            IMYTStrategy.VaultAdapterParams({action: IMYTStrategy.ActionType.swap, swapParams: swapParams});

        (bytes32[] memory strategyIds, int256 change) = IMYTStrategy(mytStrategy).allocate(
            abi.encode(allocParams), amountIn, "", vault
        );
        vm.stopPrank();

        assertGt(strategyIds.length, 0, "strategyIds is empty");
        assertEq(strategyIds[0], IMYTStrategy(mytStrategy).adapterId(), "adapter id not in strategyIds");
        assertEq(IWstETH(wstETH).balanceOf(mytStrategy), expectedWstethOut, "strategy should receive mocked wstETH output");
        assertGt(change, 0, "allocation change should be positive");
    }

    function test_realAssets_includes_idle_weth_leftover() public {
        assertEq(IWstETH(wstETH).balanceOf(mytStrategy), 0, "strategy should start without wstETH");

        vm.startPrank(vault);
        uint256 allocateAmount = 10e18;
        deal(weth, mytStrategy, allocateAmount);

        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;
        IMYTStrategy(mytStrategy).allocate(abi.encode(params), allocateAmount, "", vault);
        vm.stopPrank();

        uint256 allocatedValue = IMYTStrategy(mytStrategy).realAssets();
        assertGt(allocatedValue, 0, "allocated value should be positive");

        uint256 leftover = 3e18;
        deal(weth, mytStrategy, leftover);

        uint256 totalRealAssets = IMYTStrategy(mytStrategy).realAssets();
        assertEq(totalRealAssets, allocatedValue + leftover, "realAssets should include allocation plus idle WETH leftover");
    }

    function test_vault_deallocate_from_strategy_with_bidirectional_swap() public {
        vm.startPrank(allocator);
        uint256 amountToAllocate = 100e18;

        uint256 initialVaultTotalAssets = IVaultV2(vault).totalAssets();
        bytes32 allocationId = IMYTStrategy(mytStrategy).adapterId();
        
        // First allocate: WETH -> wstETH
        IMYTStrategy.SwapParams memory swapParams = IMYTStrategy.SwapParams({
            txData: getWethToWstethCalldata(mytStrategy, amountToAllocate), 
            minIntermediateOut: 0
        });
        IMYTStrategy.VaultAdapterParams memory params = IMYTStrategy.VaultAdapterParams({
            action: IMYTStrategy.ActionType.swap, 
            swapParams: swapParams
        });

        bytes memory data = abi.encode(params);

        IVaultV2(vault).allocate(mytStrategy, data, amountToAllocate);
        uint256 currentRealAssets = IMYTStrategy(mytStrategy).realAssets();

        // Now deallocate: wstETH -> unwrap -> stETH -> swap -> WETH
        // Use actual wstETH balance we have (don't try to unwrap more than available)
        uint256 wstETHToUnwrap = TokenUtils.safeBalanceOf(address(wstETH), address(mytStrategy));
        uint256 expectedStETH = IWstETH(wstETH).getStETHByWstETH(wstETHToUnwrap);
        emit WstethMainnetStrategyTestLog("wstETH to unwrap", wstETHToUnwrap);
        emit WstethMainnetStrategyTestLog("expected stETH after unwrap", expectedStETH);
        
        uint256 adjustedWithdraw = IMYTStrategy(mytStrategy).previewAdjustedWithdraw(expectedStETH);
        
        // Encode the VaultAdapterParams with stETH->WETH swap data
        IMYTStrategy.SwapParams memory swapParams2 = IMYTStrategy.SwapParams({
            txData: getStethToWethCalldata(address(mytStrategy), adjustedWithdraw), 
            minIntermediateOut: adjustedWithdraw
        });
        IMYTStrategy.VaultAdapterParams memory params2 = IMYTStrategy.VaultAdapterParams({
            action: IMYTStrategy.ActionType.unwrapAndSwap, 
            swapParams: swapParams2
        });
        bytes memory data2 = abi.encode(params2);

        // Deallocate - pass calculated wstETH amount to unwrap
        IVaultV2(vault).deallocate(mytStrategy, data2, wstETHToUnwrap);
        vm.stopPrank();
        assertApproxEqAbs(IMYTStrategy(mytStrategy).realAssets(), currentRealAssets - expectedStETH, 1 * 10 ** 18);
    }

    /// @notice Get swap calldata from 0x API for WETH -> wstETH
    function getWethToWstethCalldata(address taker, uint256 sellAmount) internal returns (bytes memory) {
        return _get0xCalldata(weth, wstETH, taker, sellAmount);
    }

    /// @notice Get swap calldata from 0x API for stETH -> WETH
    function getStethToWethCalldata(address taker, uint256 sellAmount) internal returns (bytes memory) {
        return _get0xCalldata(stETH, weth, taker, sellAmount);
    }

    /// @notice Get 0x API key from environment variable
    function _get0xApiKey() internal view returns (string memory) {
        return vm.envString("ZEROX_API_KEY");
    }

    /// @notice Get expected buy amount from 0x API quote
    function get0xBuyAmount(address sellToken, address buyToken, address taker, uint256 sellAmount) internal returns (uint256) {
        string[] memory inputs = new string[](3);
        inputs[0] = "bash";
        inputs[1] = "-c";
        inputs[2] = string.concat(
            "sleep 2 && ", // to avoid rate limits of 0x
            "curl -s --location --request GET 'https://api.0x.org/swap/allowance-holder/quote?chainId=1&sellToken=",
            vm.toString(sellToken),
            "&buyToken=",
            vm.toString(buyToken),
            "&sellAmount=",
            vm.toString(sellAmount),
            "&taker=",
            vm.toString(taker),
            "' -H '0x-api-key: ",
            _get0xApiKey(),
            "' -H '0x-version: v2' | jq -r .buyAmount"
        );
        bytes memory b = vm.ffi(inputs);
        bytes memory padded = abi.encodePacked(new bytes(32 - b.length), b);
        uint256 value = abi.decode(padded, (uint256));
        return value;
    }

    /// @notice Generic helper to get swap calldata from 0x API
    function _get0xCalldata(address sellToken, address buyToken, address taker, uint256 sellAmount) internal returns (bytes memory) {
        string[] memory inputs = new string[](3);
        inputs[0] = "bash";
        inputs[1] = "-c";
        inputs[2] = string.concat(
            "sleep 2 && ",
            "curl -s --location --request GET 'https://api.0x.org/swap/allowance-holder/quote?chainId=1&sellToken=",
            vm.toString(sellToken),
            "&buyToken=",
            vm.toString(buyToken),
            "&sellAmount=",
            vm.toString(sellAmount),
            "&taker=",
            vm.toString(taker),
            "' -H '0x-api-key: ",
            _get0xApiKey(),
            "' -H '0x-version: v2' | jq -r .transaction.data"
        );
        return vm.ffi(inputs);
    }

    /// @notice Fork at latest block since we use live API quotes
    function getForkBlockNumber() internal pure returns (uint256) {
        return 0;
    }

    function _mockFreshStEthEthOracle() internal {
        (uint80 roundId, int256 answer, uint256 startedAt,, uint80 answeredInRound) =
            AggregatorV3Interface(stEthEthOracle).latestRoundData();
        vm.mockCall(
            stEthEthOracle,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(roundId, answer, startedAt, block.timestamp, answeredInRound)
        );
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
        uint256 amountToAllocate = 100e18;
        vm.startPrank(admin);
        IAllocator(allocator).allocateWithSwap(
            mytStrategy, 
            amountToAllocate, 
            getWethToWstethCalldata(mytStrategy, amountToAllocate)
        );
        
        // Verify wstETH was received - balance depends on wstETH/stETH exchange rate (can vary significantly)
        uint256 wstETHBalance = IWstETH(wstETH).balanceOf(mytStrategy);
        assertGt(wstETHBalance, 0, "wstETH balance should be positive");
        
        // realAssets() returns getStETHByWstETH(wstETHBalance) - verify it's reasonable
        uint256 realAssets = IMYTStrategy(mytStrategy).realAssets();
        assertGt(realAssets, wstETHBalance, "real assets should be positive");
        vm.stopPrank();
    }

    function test_allocator_deallocate_with_swap() public {
        uint256 amountToAllocate = 100e18;
        vm.startPrank(admin);
        IAllocator(allocator).allocateWithSwap(
            mytStrategy, 
            amountToAllocate, 
            getWethToWstethCalldata(mytStrategy, amountToAllocate)
        );
        
        // Verify wstETH was received
        uint256 wstETHBalance = IWstETH(wstETH).balanceOf(mytStrategy);
        assertGt(wstETHBalance, 0, "wstETH balance should be positive");
        
        // Calculate stETH amount from wstETH balance for the swap
        uint256 stETHAmount = IWstETH(wstETH).getStETHByWstETH(wstETHBalance);
        uint256 minFinalOut = get0xBuyAmount(stETH, weth, address(mytStrategy), stETHAmount);
        
        // Deallocate: wstETH -> unwrap -> stETH -> swap -> WETH
        IAllocator(allocator).deallocateWithUnwrapAndSwap(
            mytStrategy, 
            minFinalOut, 
            getStethToWethCalldata(address(mytStrategy), stETHAmount),
            IMYTStrategy(mytStrategy).previewAdjustedWithdraw(stETHAmount)
        );

        // Verify realAssets matches expected remaining (within 1e18 tolerance for rounding)
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

        // Get strategy's fundamental capacity in WETH terms (oracle-adjusted).
        uint256 maxCapacity = IMYTStrategy(mytStrategy).realAssets();
        
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

    function test_realAssets_reverts_when_oracle_is_stale() public {
        vm.startPrank(vault);
        uint256 allocateAmount = 10e18;
        deal(weth, mytStrategy, allocateAmount);

        IMYTStrategy.VaultAdapterParams memory params;
        params.action = IMYTStrategy.ActionType.direct;
        IMYTStrategy(mytStrategy).allocate(abi.encode(params), allocateAmount, "", vault);
        vm.stopPrank();

        (uint80 roundId, int256 answer, uint256 startedAt,, uint80 answeredInRound) =
            AggregatorV3Interface(stEthEthOracle).latestRoundData();
        vm.mockCall(
            stEthEthOracle,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(roundId, answer, startedAt, block.timestamp - 8 days, answeredInRound)
        );

        vm.expectRevert(bytes("Stale oracle answer"));
        IMYTStrategy(mytStrategy).realAssets();
    }

    // Test: WstETH Mainnet yield accumulation over time
    function test_wsteth_mainnet_yield_accumulation() public {
        // Set up mocked swap executor for deallocations (avoids 0x signature deadline issues with vm.warp)
        // Mock returns 100 WETH per call, fund it enough for multiple deallocations
        uint256 mockWethOutput = 100e18;
        uint256 mockWethFunding = 200e18; // Enough for 2 deallocation calls
        MockSwapExecutor mockSwap = new MockSwapExecutor(weth, mockWethOutput);
        deal(weth, address(mockSwap), mockWethFunding);
        vm.prank(admin);
        MYTStrategy(mytStrategy).setAllowanceHolder(address(mockSwap));
        
        vm.startPrank(allocator);
    
        // Allocate initial amount
        uint256 allocAmount = 100e18; // 100 WETH
        deal(weth, mytStrategy, allocAmount);
    
        // Use direct allocation (WETH -> wstETH wrap)
        IMYTStrategy.VaultAdapterParams memory params = IMYTStrategy.VaultAdapterParams({
            action: IMYTStrategy.ActionType.direct,
            swapParams: IMYTStrategy.SwapParams({txData: "", minIntermediateOut: 0})
        });
        bytes memory data = abi.encode(params);
        IVaultV2(vault).allocate(mytStrategy, data, allocAmount);
        _mockFreshStEthEthOracle();
        uint256 initialRealAssets = IMYTStrategy(mytStrategy).realAssets();
        
        // Track real assets over time with warps
        uint256[] memory realAssetsSnapshots = new uint256[](4);
        uint256 minExpected = initialRealAssets * 95 / 100; // Start with 95% of initial as minimum
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(block.timestamp + 30 days);
            _mockFreshStEthEthOracle();
            
            // wstETH naturally accrues yield through staking rewards (reflected in exchange rate)
            // No need to simulate yield artificially - just track that assets don't decrease significantly
            
            realAssetsSnapshots[i] = IMYTStrategy(mytStrategy).realAssets();
            
            // Real assets should not significantly decrease (may increase with yield)
            assertGe(realAssetsSnapshots[i], minExpected, "Real assets decreased significantly");
            // Update minExpected to the new baseline
            minExpected = realAssetsSnapshots[i];
            
            // Small deallocation on second snapshot using mocked swap
            if (i == 1) {
                uint256 smallDealloc = 10e18; // 10 WETH
                
                // Use mocked swap (no 0x deadline issues)
                IMYTStrategy.SwapParams memory deallocSwapParams = IMYTStrategy.SwapParams({
                    txData: hex"01", // Mock calldata
                    minIntermediateOut: smallDealloc
                });
                IMYTStrategy.VaultAdapterParams memory deallocParams = IMYTStrategy.VaultAdapterParams({
                    action: IMYTStrategy.ActionType.unwrapAndSwap,
                    swapParams: deallocSwapParams
                });
                bytes memory deallocateData = abi.encode(deallocParams);
                
                uint256 deallocPreview = IMYTStrategy(mytStrategy).previewAdjustedWithdraw(smallDealloc);
                // Call deallocate through the vault (allocator is whitelisted)
                IVaultV2(vault).deallocate(mytStrategy, deallocateData, deallocPreview);
                // Update minExpected after deallocation to account for the reduction
                _mockFreshStEthEthOracle();
                minExpected = IMYTStrategy(mytStrategy).realAssets();
            }
        }
        
        // Final deallocation using mocked swap
        _mockFreshStEthEthOracle();
        uint256 finalRealAssets = IMYTStrategy(mytStrategy).realAssets();
        if (finalRealAssets > 1e15) {
            uint256 stETHAmount = IWstETH(wstETH).getStETHByWstETH(IWstETH(wstETH).balanceOf(mytStrategy));
            uint256 adjustedWithdraw = IMYTStrategy(mytStrategy).previewAdjustedWithdraw(stETHAmount);
            
            // Use mocked swap (no 0x deadline issues)
            IMYTStrategy.SwapParams memory deallocSwapParams = IMYTStrategy.SwapParams({
                txData: hex"01", // Mock calldata
                minIntermediateOut: adjustedWithdraw
            });
            IMYTStrategy.VaultAdapterParams memory deallocParams = IMYTStrategy.VaultAdapterParams({
                action: IMYTStrategy.ActionType.unwrapAndSwap,
                swapParams: deallocSwapParams
            });
            bytes memory deallocateData = abi.encode(deallocParams);
            uint256 finalDeallocPreview = IMYTStrategy(mytStrategy).previewAdjustedWithdraw(finalRealAssets);
            // Call deallocate through the vault (allocator is whitelisted)
            IVaultV2(vault).deallocate(mytStrategy, deallocateData, finalDeallocPreview);
        }
        
        assertEq(IMYTStrategy(mytStrategy).realAssets(), 0, "All real assets should be deallocated");
        
        vm.stopPrank();
    }
    
}
