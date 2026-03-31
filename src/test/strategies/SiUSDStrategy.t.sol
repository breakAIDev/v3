// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseStrategyTest} from "../BaseStrategyTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {IAllocator} from "../../interfaces/IAllocator.sol";
import {SiUSDStrategy} from "../../strategies/SiUSDStrategy.sol";

interface ISIUSDView {
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}

interface IRedeemControllerView {
    function receiptToAsset(uint256 receiptAmount) external view returns (uint256);
}

contract SiUSDStrategyTest is BaseStrategyTest {
    uint256 internal constant INITIAL_VAULT_DEPOSIT = 1_000_000e6;
    uint256 internal constant ABSOLUTE_CAP = 10_000_000e6;
    uint256 internal constant RELATIVE_CAP = 1e18;

    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant IUSD = 0x48f9e38f3070AD8945DFEae3FA70987722E3D89c;
    address public constant SIUSD = 0xDBDC1Ef57537E34680B898E1FEBD3D68c7389bCB;
    address public constant GATEWAY = 0x3f04b65Ddbd87f9CE0A2e7Eb24d80e7fb87625b5;
    address public constant MINT_CONTROLLER = 0x49877d937B9a00d50557bdC3D87287b5c3a4C256;
    address public constant REDEEM_CONTROLLER = 0xCb1747E89a43DEdcF4A2b831a0D94859EFeC7601;

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "siUSD",
            protocol: "InfiniFi",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: ABSOLUTE_CAP,
            globalCap: ABSOLUTE_CAP,
            estimatedYield: 100e18,
            additionalIncentives: false,
            slippageBPS: 0
        });
    }

    function getTestConfig() internal pure override returns (TestConfig memory) {
        return TestConfig({
            vaultAsset: USDC,
            vaultInitialDeposit: INITIAL_VAULT_DEPOSIT,
            absoluteCap: ABSOLUTE_CAP,
            relativeCap: RELATIVE_CAP,
            decimals: 6
        });
    }

    function createStrategy(address vault_, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new SiUSDStrategy(vault_, params, USDC, IUSD, SIUSD, GATEWAY, MINT_CONTROLLER, REDEEM_CONTROLLER));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 24595012;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envString("MAINNET_RPC_URL");
    }

    function _getMinAllocateAmount() internal pure override returns (uint256) {
        return 1e6;
    }

    function test_allocator_allocate_direct_mintsSiUsd(uint256 amount) public {
        amount = bound(amount, 1e6, INITIAL_VAULT_DEPOSIT);

        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, amount);

        uint256 siUsdShares = ISIUSDView(SIUSD).balanceOf(strategy);
        assertGt(siUsdShares, 0, "strategy should receive siUSD shares");
        assertLe(IERC20(USDC).balanceOf(strategy), 1, "strategy should only retain minimal USDC dust after allocate");
        assertApproxEqAbs(
            IMYTStrategy(strategy).realAssets(),
            _expectedTotalValue(),
            5,
            "realAssets should track redeemable USDC value"
        );
    }

    function test_allocator_deallocate_direct_redeemsBackToUsdc() public {
        uint256 allocateAmount = 10_000e6;
        uint256 deallocateAmount = 4_000e6;

        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, allocateAmount);

        uint256 vaultBalanceBefore = IERC20(USDC).balanceOf(vault);
        uint256 strategySharesBefore = ISIUSDView(SIUSD).balanceOf(strategy);
        uint256 allocationBefore = IVaultV2(vault).allocation(IMYTStrategy(strategy).adapterId());

        vm.prank(admin);
        IAllocator(allocator).deallocate(strategy, deallocateAmount);

        assertEq(IERC20(USDC).balanceOf(vault), vaultBalanceBefore + deallocateAmount, "vault should receive USDC");
        assertLt(ISIUSDView(SIUSD).balanceOf(strategy), strategySharesBefore, "strategy should burn siUSD shares");
        assertLt(
            IVaultV2(vault).allocation(IMYTStrategy(strategy).adapterId()),
            allocationBefore,
            "allocation should decrease after deallocation"
        );
    }

    function test_previewAdjustedWithdraw_isPositiveAfterAllocation() public {
        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, 10_000e6);

        uint256 preview = IMYTStrategy(strategy).previewAdjustedWithdraw(4_000e6);
        assertGt(preview, 0, "preview should be positive");
        assertLe(preview, 4_000e6, "preview should not exceed requested amount");
    }

    function test_allocator_allocateWithSwap_reverts_noDexSwaps() public {
        vm.expectRevert(IMYTStrategy.ActionNotSupported.selector);
        vm.prank(admin);
        IAllocator(allocator).allocateWithSwap(strategy, 1e6, hex"01");
    }

    function test_allocator_deallocateWithSwap_reverts_noDexSwaps() public {
        vm.prank(admin);
        IAllocator(allocator).allocate(strategy, 10_000e6);

        vm.expectRevert(IMYTStrategy.ActionNotSupported.selector);
        vm.prank(admin);
        IAllocator(allocator).deallocateWithSwap(strategy, 1e6, hex"01");
    }

    function _expectedTotalValue() internal view returns (uint256) {
        uint256 siUsdShares = ISIUSDView(SIUSD).balanceOf(strategy);
        uint256 iUsdFromShares = ISIUSDView(SIUSD).convertToAssets(siUsdShares);
        uint256 idleIUsd = IERC20(IUSD).balanceOf(strategy);
        uint256 idleUsdc = IERC20(USDC).balanceOf(strategy);
        return idleUsdc + IRedeemControllerView(REDEEM_CONTROLLER).receiptToAsset(iUsdFromShares + idleIUsd);
    }
}
