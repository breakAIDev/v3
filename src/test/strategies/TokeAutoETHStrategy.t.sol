// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
// Adjust these imports to your layout

import {TokeAutoEthStrategy} from "src/strategies/mainnet/TokeAutoEth.sol";
import {BaseStrategyTest} from "../libraries/BaseStrategyTest.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

/*contract TokeAutoEthStrategyTest is Test {
    // Addresses sourced from environment so you can swap networks/blocks easily
    address public constant AUTOETH = 0x0A2b94F6871c1D7A32Fe58E1ab5e6deA2f114E56;
    address public constant ROUTER = 0x37dD409f5e98aB4f151F4259Ea0CC13e97e8aE21;
    address public constant REWARDER = 0x60882D6f70857606Cdd37729ccCe882015d1755E;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant ORACLE = 0x61F8BE7FD721e80C0249829eaE6f0DAf21bc2CaC;

    IERC20 public autoEth;
    IAutopilotRouter public router;
    IMainRewarder public rewarder;

    TokeAutoEthStrategy public strat;

    address public constant MYT = address(0xbeef);

    uint256 private _forkId;

    function setUp() public {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        _forkId = vm.createFork(rpc, 22_089_302);
        vm.selectFork(_forkId);

        autoEth = IERC20(AUTOETH);
        router = IAutopilotRouter(ROUTER);
        rewarder = IMainRewarder(REWARDER);

        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: address(this),
            name: "autoETH",
            protocol: "tokemak",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: type(uint256).max,
            globalCap: type(uint256).max,
            estimatedYield: 0,
            additionalIncentives: false,
            slippageBPS: 1
        });

        address permit2Address = 0x000000000022d473030f1dF7Fa9381e04776c7c5; // Mainnet Permit2
        strat = new TokeAutoEthStrategy(MYT, params, AUTOETH, ROUTER, REWARDER, WETH, ORACLE, permit2Address);

        strat.setWhitelistedAllocator(address(0xbeef), true);

        vm.prank(address(strat));
        IERC20(WETH).approve(ROUTER, type(uint256).max);

        vm.makePersistent(address(strat));
    }

    function testAllocate() public {
        uint256 ethAmt = 0.2 ether;
        deal(WETH, address(strat), ethAmt);

        vm.startPrank(address(0xbeef));
        bytes memory prevAllocationAmount = abi.encode(0);
        (bytes32[] memory strategyIds, int256 change) = strat.allocate(prevAllocationAmount, ethAmt, "", address(MYT));
        vm.stopPrank();

        assertGt(change, int256(0), "positive change expected");
        assertGt(strategyIds.length, 0, "strategyIds is empty");
        assertEq(strategyIds[0], strat.adapterId(), "adapter id not in strategyIds");
        uint256 shares = IMainRewarder(REWARDER).balanceOf(address(strat));
        assertGe(strat.realAssets(), shares, "ETH not deposited into strategy");
        // assertEq(strat.realAssets(), ethAmt, "ETH not deposited into strategy");
    }

    function testDeallocate() public {
        uint256 ethAmt = 0.15 ether;
        deal(WETH, address(strat), ethAmt);
        vm.startPrank(address(0xbeef));
        bytes memory prevAllocationAmount = abi.encode(0);
        strat.allocate(prevAllocationAmount, ethAmt, "", address(MYT));
        bytes memory prevAllocationAmount2 = abi.encode(ethAmt);
        (bytes32[] memory strategyIds, int256 change) = strat.deallocate(prevAllocationAmount2, ethAmt, "", address(MYT));
        vm.stopPrank();
        assertLt(change, int256(0), "negative change expected");
        assertGt(strategyIds.length, 0, "strategyIds is empty");
        assertEq(strategyIds[0], strat.adapterId(), "adapter id not in strategyIds");
        assertEq(strat.realAssets(), 0, "ETH not deallocated from strategy");
    }

    // TODO find blocks to test where we actually will acrue rewards
    // Currently earned 0
    function testClaim() public {
        uint256 ethAmt = 0.15 ether;
        vm.deal(address(0xbeef), ethAmt);

        vm.startPrank(address(0xbeef));
        uint256 shares = strat.allocate{value: ethAmt}(ethAmt);
        vm.stopPrank();
        assertGt(shares, 0, "allocate failed");

        vm.rollFork(23281065);

        strat.claimRewards();
    }

    function testSnapshotYield() public {
        uint256 ethAmt = 0.2 ether;
        deal(WETH, address(strat), ethAmt);

        vm.startPrank(address(0xbeef));
        bytes memory prevAllocationAmount = abi.encode(0);
        (bytes32[] memory strategyIds, int256 change) = strat.allocate(prevAllocationAmount, ethAmt, "", address(MYT));
        vm.stopPrank();

        uint256 first = strat.snapshotYield();
        assertEq(first, 0, "first snapshot should be 0");

        vm.rollFork(23_281_065);

        uint256 second = strat.snapshotYield();
        assertGt(second, 0, "APY should be > 0 after moving to later block");
    }
}*/

contract MockTokeAutoEthStrategy is TokeAutoEthStrategy {
    constructor(
        address _myt,
        StrategyParams memory _params,
        address _autoEth,
        address _router,
        address _rewarder,
        address _weth,
        address _oracle,
        address _permit2Address
    ) TokeAutoEthStrategy(_myt, _params, _autoEth, _router, _rewarder, _weth, _oracle, _permit2Address) {}
}

contract TokeAutoETHStrategyTest is BaseStrategyTest {
    address public constant TOKE_AUTO_ETH_VAULT = 0x0A2b94F6871c1D7A32Fe58E1ab5e6deA2f114E56;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant MAINNET_PERMIT2 = 0x000000000022d473030f1dF7Fa9381e04776c7c5;
    address public constant AUTOPILOT_ROUTER = 0x37dD409f5e98aB4f151F4259Ea0CC13e97e8aE21;
    address public constant REWARDER = 0x60882D6f70857606Cdd37729ccCe882015d1755E;
    address public constant ORACLE = 0x61F8BE7FD721e80C0249829eaE6f0DAf21bc2CaC;

    function getStrategyConfig() internal pure override returns (IMYTStrategy.StrategyParams memory) {
        return IMYTStrategy.StrategyParams({
            owner: address(1),
            name: "TokeAutoEth",
            protocol: "TokeAutoEth",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 10_000e18,
            globalCap: 1e18,
            estimatedYield: 100e18,
            additionalIncentives: false,
            slippageBPS: 1
        });
    }

    function getTestConfig() internal pure override returns (TestConfig memory) {
        return TestConfig({vaultAsset: WETH, vaultInitialDeposit: 1000e18, absoluteCap: 10_000e18, relativeCap: 1e18, decimals: 18});
    }

    function createStrategy(address vault, IMYTStrategy.StrategyParams memory params) internal override returns (address) {
        return address(new MockTokeAutoEthStrategy(vault, params, TOKE_AUTO_ETH_VAULT, AUTOPILOT_ROUTER, REWARDER, WETH, ORACLE, MAINNET_PERMIT2));
    }

    function getForkBlockNumber() internal pure override returns (uint256) {
        return 22_089_302;
    }

    function getRpcUrl() internal view override returns (string memory) {
        return vm.envString("MAINNET_RPC_URL");
    }

    // Add any strategy-specific tests here
    function test_strategy_deallocate_reverts_due_to_slippage(uint256 amountToAllocate, uint256 amountToDeallocate) public {
        amountToAllocate = bound(amountToAllocate, 1e6, testConfig.vaultInitialDeposit);
        amountToDeallocate = amountToAllocate;
        vm.startPrank(vault);
        deal(testConfig.vaultAsset, strategy, amountToAllocate);
        bytes memory prevAllocationAmount = abi.encode(0);
        IMYTStrategy(strategy).allocate(prevAllocationAmount, amountToAllocate, "", address(vault));
        uint256 initialRealAssets = IMYTStrategy(strategy).realAssets();
        require(initialRealAssets > 0, "Initial real assets is 0");
        bytes memory prevAllocationAmount2 = abi.encode(amountToAllocate);
        vm.expectRevert();
        IMYTStrategy(strategy).deallocate(prevAllocationAmount2, amountToDeallocate, "", address(vault));
        vm.stopPrank();
    }
}
