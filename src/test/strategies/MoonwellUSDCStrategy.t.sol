// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseStrategyTest.sol";
import {MoonwellUSDCStrategy} from "../../strategies/optimism/MoonwellUSDCStrategy.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";

/// @notice Replaces the Moonwell Comptroller via vm.etch so that
///         claimReward actually transfers WELL tokens to the caller.
contract MockComptroller {
    IERC20 public immutable rewardToken;
    uint256 public immutable rewardAmount;

    constructor(address _rewardToken, uint256 _rewardAmount) {
        rewardToken = IERC20(_rewardToken);
        rewardAmount = _rewardAmount;
    }

    function claimReward() external {
        rewardToken.transfer(msg.sender, rewardAmount);
    }
}

/// @notice When used as allowanceHolder, transfers a fixed amount of token to msg.sender on any call (simulates swap output).
contract MockSwapExecutor {
    IERC20 public immutable token;
    uint256 public amountToTransfer;

    constructor(address _token, uint256 _amountToTransfer) {
        token = IERC20(_token);
        amountToTransfer = _amountToTransfer;
    }

    receive() external payable {}

    fallback() external {
        token.transfer(msg.sender, amountToTransfer);
    }
}

contract MockMoonwellUSDCStrategy is MoonwellUSDCStrategy {
    constructor(address _myt, StrategyParams memory _params, address _mUSDC, address _usdc)
        MoonwellUSDCStrategy(_myt, _params, _mUSDC, _usdc)
    {}
}

contract MoonwellUSDCStrategyTest is BaseStrategyTest {
    address public constant MOONWELL_USDC_MTOKEN = 0x8E08617b0d66359D73Aa11E11017834C29155525;
    address public constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address public constant WELL = 0xA88594D404727625A9437C3f886C7643872296AE;
    address public constant COMPTROLLER = 0xCa889f40aae37FFf165BccF69aeF1E82b5C511B9;

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "MoonwellUSDC",
            protocol: "MoonwellUSDC",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 10_000e6,
            globalCap: 1e18,
            estimatedYield: 100e6,
            additionalIncentives: false,
            slippageBPS: 1
        });
    }

    function getTestConfig() internal pure override returns (TestConfig memory) {
        return TestConfig({vaultAsset: USDC, vaultInitialDeposit: 1000e6, absoluteCap: 10_000e6, relativeCap: 1e18, decimals: 6});
    }

    function createStrategy(address vault, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new MockMoonwellUSDCStrategy(vault, params, MOONWELL_USDC_MTOKEN, USDC));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 141_751_698;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envString("OPTIMISM_RPC_URL");
    }

    function _effectiveDeallocateAmount(uint256 requestedAssets) internal view override returns (uint256) {
        uint256 idleAssets = IERC20(USDC).balanceOf(strategy);
        uint256 realAssets = IMYTStrategy(strategy).realAssets();
        if (realAssets <= idleAssets) return 0;

        uint256 investedAssets = realAssets - idleAssets;
        uint256 maxTarget = investedAssets / 20; // 5%
        if (maxTarget == 0) {
            maxTarget = investedAssets;
        }

        return requestedAssets < maxTarget ? requestedAssets : maxTarget;
    }

    function test_strategy_allocate_emits_incremental_amounts() public {
        bytes memory params = getVaultParams();
        uint256 alloc1 = 50e6;
        uint256 alloc2 = 60e6;
        bytes32 adapterId = IMYTStrategy(strategy).adapterId();

        vm.startPrank(vault);

        deal(testConfig.vaultAsset, strategy, alloc1);
        IMYTStrategy(strategy).allocate(params, alloc1, "", address(vault));
        uint256 firstRealAssets = IMYTStrategy(strategy).realAssets();

        vm.mockCall(vault, abi.encodeWithSelector(IVaultV2.allocation.selector, adapterId), abi.encode(firstRealAssets));

        deal(testConfig.vaultAsset, strategy, alloc2);
        (, int256 change) = IMYTStrategy(strategy).allocate(params, alloc2, "", address(vault));
        vm.clearMockedCalls();
        vm.stopPrank();

        assertGt(change, 0, "second allocate change should be positive");
        assertApproxEqAbs(uint256(change), alloc2, alloc2 / 100);
    }

    // Test that full deallocation completes without reverting
    function test_strategy_full_deallocate(uint256 amountToAllocate) public {
        amountToAllocate = bound(amountToAllocate, 1 * 10 ** testConfig.decimals, testConfig.vaultInitialDeposit);
        bytes memory params = getVaultParams();
        vm.startPrank(vault);
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        IMYTStrategy(strategy).allocate(params, amountToAllocate, "", address(vault));
        uint256 initialRealAssets = IMYTStrategy(strategy).realAssets();
        require(initialRealAssets > 0, "Initial real assets is 0");
        uint256 amountToDeallocate = IMYTStrategy(strategy).previewAdjustedWithdraw(_effectiveDeallocateAmount(initialRealAssets));
        require(amountToDeallocate > 0, "Previewed deallocation amount is 0");
        IMYTStrategy(strategy).deallocate(params, amountToDeallocate, "", address(vault));
        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        require(finalRealAssets <= initialRealAssets, "Final real assets is not less than initial real assets");
        vm.stopPrank();
    }

    // End-to-end test: Full lifecycle with time accumulation for MoonwellUSDC
    function test_moonwell_usdc_full_lifecycle_with_time() public {
        vm.startPrank(allocator);
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        
        // Initial allocation
        uint256 alloc1 = 500e6; // 500 USDC
        IVaultV2(vault).allocate(strategy, getVaultParams(), alloc1);
        uint256 realAssets1 = IMYTStrategy(strategy).realAssets();
        assertGt(realAssets1, 0, "Real assets should be positive after allocation");
        assertApproxEqAbs(IVaultV2(vault).allocation(allocationId), alloc1, 1e5);
        
        // Warp forward 7 days
        vm.warp(block.timestamp + 7 days);
        
        // Additional allocation
        uint256 alloc2 = 300e6; // 300 USDC
        IVaultV2(vault).allocate(strategy, getVaultParams(), alloc2);
        uint256 realAssets2 = IMYTStrategy(strategy).realAssets();
        assertGe(realAssets2, realAssets1, "Real assets should not decrease");
        
        // Warp forward 14 days
        vm.warp(block.timestamp + 14 days);
        
        // Partial deallocation (withdraw 200 USDC)
        uint256 deallocAmount1 = _effectiveDeallocateAmount(realAssets2);
        uint256 deallocPreview1 = IMYTStrategy(strategy).previewAdjustedWithdraw(deallocAmount1);
        IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocPreview1);
        uint256 realAssets3 = IMYTStrategy(strategy).realAssets();
        assertLe(realAssets3, realAssets2, "Real assets should not increase after deallocation");
        
        // Warp forward 30 days
        vm.warp(block.timestamp + 30 days);
        
        // Check vault USDC balance
        uint256 vaultUSDCBalance = IERC20(USDC).balanceOf(vault);
        assertGt(vaultUSDCBalance, 0, "Vault should have USDC");
        
        // Full deallocation of remaining
        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        if (finalRealAssets > 1e6) {
            uint256 finalDeallocPreview =
                IMYTStrategy(strategy).previewAdjustedWithdraw(_effectiveDeallocateAmount(finalRealAssets));
            IVaultV2(vault).deallocate(strategy, getVaultParams(), finalDeallocPreview);
        }
        
        uint256 finalVaultUSDCBalance = IERC20(USDC).balanceOf(vault);
        assertGe(finalVaultUSDCBalance, vaultUSDCBalance, "Vault USDC should not decrease after deallocation");
        
        vm.stopPrank();
    }

    // Fuzz test: Multiple random allocations and deallocations with time warps
    function test_fuzz_moonwell_usdc_operations(uint256[] calldata amounts, uint256[] calldata timeDelays) public {
        // Use bound for array length instead of assume
        uint256 numOps = bound(amounts.length, 1, 8);
        // Ensure we don't access beyond array bounds
        uint256 maxIterations = numOps < amounts.length ? numOps : amounts.length;
        
        vm.startPrank(allocator);
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        
        for (uint256 i = 0; i < maxIterations; i++) {
            // Alternate between allocation and deallocation
            bool isAllocate = i % 2 == 0;
            uint256 amount = bound(amounts[i], 10e6, 200e6); // 10-200 USDC
            
            if (isAllocate) {
                IVaultV2(vault).allocate(strategy, getVaultParams(), amount);
            } else {
                uint256 currentAllocation = IVaultV2(vault).allocation(allocationId);
                if (currentAllocation > 0) {
                    uint256 maxDealloc = currentAllocation < 10e6 ? currentAllocation : 10e6;
                    uint256 deallocAmount = bound(amount, 0, maxDealloc);
                    if (deallocAmount > 0) {
                        uint256 deallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(deallocAmount);
                        if (deallocPreview > 0) {
                            IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocPreview);
                        }
                    }
                }
            }
            
            // Warp forward (with bounds check for timeDelays array)
            uint256 timeDelay = i < timeDelays.length ? bound(timeDelays[i], 1 hours, 30 days) : 1 hours;
            vm.warp(block.timestamp + timeDelay);
        }
        
        // Final sanity checks
        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        uint256 finalAllocation = IVaultV2(vault).allocation(allocationId);
        uint256 vaultUSDCBalance = IERC20(USDC).balanceOf(vault);
        
        assertGe(finalRealAssets, 0, "Real assets should be non-negative");
        assertGe(finalAllocation, 0, "Allocation should be non-negative");
        assertGt(vaultUSDCBalance, 0, "Vault should have USDC");
        
        vm.stopPrank();
    }

    // Test: Moonwell USDC vault yield accumulation over time
    function test_moonwell_usdc_yield_accumulation() public {
        vm.startPrank(allocator);
        
        // Allocate initial amount
        uint256 allocAmount = 400e6; // 400 USDC
        IVaultV2(vault).allocate(strategy, getVaultParams(), allocAmount);
        uint256 initialRealAssets = IMYTStrategy(strategy).realAssets();
        
        // Track real assets over time with warps
        uint256[] memory realAssetsSnapshots = new uint256[](4);
        uint256 minExpected = initialRealAssets * 95 / 100; // Start with 95% of initial as minimum
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(block.timestamp + 30 days);
            
            // Simulate yield by transferring small amount to strategy (0.5% per period)
            deal(testConfig.vaultAsset, strategy, initialRealAssets * 5 / 1000);
            
            realAssetsSnapshots[i] = IMYTStrategy(strategy).realAssets();
            
            // Real assets should not significantly decrease (may increase with yield)
            uint256 tolerance = minExpected / 50; // 2%
            assertGe(realAssetsSnapshots[i] + tolerance, minExpected, "Real assets decreased significantly");
            // Update minExpected to the new baseline
            minExpected = realAssetsSnapshots[i];
            
            // Small deallocation on second snapshot
            if (i == 1) {
                uint256 smallDealloc = _effectiveDeallocateAmount(IMYTStrategy(strategy).realAssets());
                uint256 deallocPreview = IMYTStrategy(strategy).previewAdjustedWithdraw(smallDealloc);
                IVaultV2(vault).deallocate(strategy, getVaultParams(), deallocPreview);
                // Update minExpected after deallocation to account for the reduction
                minExpected = IMYTStrategy(strategy).realAssets();
            }
        }
        
        // Final deallocation
        uint256 finalRealAssets = IMYTStrategy(strategy).realAssets();
        if (finalRealAssets > 1e6) {
            uint256 finalDeallocPreview =
                IMYTStrategy(strategy).previewAdjustedWithdraw(_effectiveDeallocateAmount(finalRealAssets));
            IVaultV2(vault).deallocate(strategy, getVaultParams(), finalDeallocPreview);
        }

        assertLe(IMYTStrategy(strategy).realAssets(), minExpected, "Final real assets should not exceed tracked baseline");
        
        vm.stopPrank();
    }

    // Test that allocation reverts when mint returns non-zero error code
    function test_strategy_allocate_reverts_on_mint_failure() public {
        uint256 amountToAllocate = 100 * 10 ** testConfig.decimals;
        uint256 errorCode = 1; // Non-zero error code to simulate failure
        bytes memory params = getVaultParams();
        
        vm.startPrank(vault);
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        
        // Mock the mint function to return a non-zero error code
        vm.mockCall(
            MOONWELL_USDC_MTOKEN,
            abi.encodeWithSelector(bytes4(keccak256("mint(uint256)")), amountToAllocate),
            abi.encode(errorCode)
        );
        
        // Expect the allocation to revert with MoonwellUSDCStrategyMintFailed
        vm.expectRevert(abi.encodeWithSignature("MoonwellUSDCStrategyMintFailed(uint256)", errorCode));
        IMYTStrategy(strategy).allocate(params, amountToAllocate, "", address(vault));
        
        vm.clearMockedCalls();
        vm.stopPrank();
    }

    // Test that deallocation reverts when redeem returns non-zero error code
    function test_strategy_deallocate_reverts_on_redeem_failure() public {
        uint256 amountToAllocate = 100 * 10 ** testConfig.decimals;
        uint256 amountToDeallocate = 50 * 10 ** testConfig.decimals;
        uint256 errorCode = 2; // Non-zero error code to simulate failure
        bytes memory params = getVaultParams();
        
        vm.startPrank(vault);
        
        // First, successfully allocate funds
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        IMYTStrategy(strategy).allocate(params, amountToAllocate, "", address(vault));
        uint256 initialRealAssets = IMYTStrategy(strategy).realAssets();
        require(initialRealAssets > 0, "Initial real assets is 0");
        
        // Mock the redeem function to return a non-zero error code
        vm.mockCall(
            MOONWELL_USDC_MTOKEN,
            abi.encodeWithSelector(bytes4(keccak256("redeem(uint256)"))),
            abi.encode(errorCode)
        );
        
        // Expect the deallocation to revert with MoonwellUSDCStrategyRedeemUnderlyingFailed
        vm.expectRevert(abi.encodeWithSignature("MoonwellUSDCStrategyRedeemUnderlyingFailed(uint256)", errorCode));
        IMYTStrategy(strategy).deallocate(params, amountToDeallocate, "", address(vault));
        
        vm.clearMockedCalls();
        vm.stopPrank();
    }

    function test_claimRewards_succeeds() public {
        bytes memory params = getVaultParams();
        // Allocate some assets first so there are positions to claim rewards for
        uint256 amountToAllocate = 1000e6;
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        vm.prank(vault);
        IMYTStrategy(strategy).allocate(params, amountToAllocate, "", address(vault));
        
        // Claim rewards should not revert
        vm.prank(address(1));
        IMYTStrategy(strategy).claimRewards(0xA88594D404727625A9437C3f886C7643872296AE, "", 1);
        vm.stopPrank();
    }

    function test_claimRewards_emits_event_and_vault_receives_asset() public {
        // Allocate assets to create a Moonwell position
        bytes memory params = getVaultParams();
        uint256 amountToAllocate = 100e6;
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        vm.prank(vault);
        IMYTStrategy(strategy).allocate(params, amountToAllocate, "", address(vault));

        // Configure mock reward claim
        uint256 wellRewardAmount = 10e18;   // 10 WELL tokens claimed
        uint256 mockSwapReturn = 5e6;       // Simulated USDC swap output

        // Deploy a MockComptroller and etch its bytecode over the real
        // comptroller address so claimReward actually transfers WELL.
        MockComptroller mockComp = new MockComptroller(WELL, wellRewardAmount);
        vm.etch(COMPTROLLER, address(mockComp).code);
        deal(WELL, COMPTROLLER, wellRewardAmount);

        // Setup MockSwapExecutor as allowanceHolder to simulate DEX swap.
        // Swap output should be measured in vault asset terms (USDC).
        MockSwapExecutor mockSwap = new MockSwapExecutor(USDC, mockSwapReturn);
        deal(USDC, address(mockSwap), mockSwapReturn);

        // Point the strategy's allowanceHolder to our mock
        vm.prank(address(1)); // strategy owner
        MYTStrategy(strategy).setAllowanceHolder(address(mockSwap));

        // Record vault USDC balance before claiming
        uint256 vaultBalanceBefore = IERC20(USDC).balanceOf(vault);

        // Expect the RewardsClaimed event with correct token and amount
        vm.expectEmit(true, true, false, true, strategy);
        emit IMYTStrategy.RewardsClaimed(WELL, wellRewardAmount);

        // Execute claimRewards as strategy owner
        bytes memory quote = hex"01";
        vm.prank(address(1));
        uint256 received = IMYTStrategy(strategy).claimRewards(WELL, quote, 4.99e6);

        // Verify rewards were received and vault got the asset
        uint256 vaultBalanceAfter = IERC20(USDC).balanceOf(vault);
        uint256 vaultAssetReceived = vaultBalanceAfter - vaultBalanceBefore;
        assertGt(received, 0, "No rewards received from claim");
        assertEq(vaultAssetReceived, mockSwapReturn, "Vault did not receive expected USDC amount");
        assertEq(received, vaultAssetReceived, "Returned amount is not in vault asset terms");
    }
}
