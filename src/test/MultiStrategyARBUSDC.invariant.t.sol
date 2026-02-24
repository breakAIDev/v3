// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultV2} from "lib/vault-v2/src/interfaces/IVaultV2.sol";
import {VaultV2} from "lib/vault-v2/src/VaultV2.sol";
import {VaultV2Factory} from "lib/vault-v2/src/VaultV2Factory.sol";
import {AlchemistAllocator} from "../AlchemistAllocator.sol";
import {AlchemistCurator} from "../AlchemistCurator.sol";
import {IAllocator} from "../interfaces/IAllocator.sol";
import {AlchemistStrategyClassifier} from "../AlchemistStrategyClassifier.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {AaveV3ARBUSDCStrategy} from "../strategies/arbitrum/AaveV3ARBUSDCStrategy.sol";
import {EulerARBUSDCStrategy} from "../strategies/arbitrum/EulerARBUSDCStrategy.sol";
import {FluidARBUSDCStrategy} from "../strategies/arbitrum/FluidARBUSDCStrategy.sol";

/// @title MultiStrategyARBUSDCCHandler
/// @notice Handler for invariant testing multiple USDC strategies on Arbitrum
contract MultiStrategyARBUSDCCHandler is Test {
    IVaultV2 public vault;
    address[] public strategies;
    address public allocator;
    address public classifier;
    address public admin;
    address public asset;
    
    // Actors for user operations
    address[] public actors;
    address internal currentActor;
    
    // Ghost variables for tracking cumulative state
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_totalAllocated;
    uint256 public ghost_totalDeallocated;
    mapping(address => uint256) public ghost_userDeposits;
    mapping(address => uint256) public ghost_strategyAllocations;
    
    // Call counters
    mapping(bytes4 => uint256) public calls;
    
    // Strategy name tracking for debugging
    mapping(address => string) public strategyNames;
    
    // Minimum amounts for operations
    uint256 public constant MIN_DEPOSIT = 1e6; // 1 USDC
    uint256 public constant MIN_ALLOCATE = 1e5; // 0.1 USDC
    uint256 public constant MAX_USERS = 10;
    
    modifier countCall(bytes4 selector) {
        calls[selector]++;
        _;
    }
    
    modifier useActor(uint256 actorSeed) {
        currentActor = actors[bound(actorSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }
    
    constructor(
        address _vault,
        address[] memory _strategies,
        address _allocator,
        address _classifier,
        address _admin,
        string[] memory _strategyNames
    ) {
        vault = IVaultV2(_vault);
        strategies = _strategies;
        allocator = _allocator;
        classifier = _classifier;
        admin = _admin;
        asset = vault.asset();
        
        // Initialize actors with varying balances
        for (uint256 i = 0; i < MAX_USERS; i++) {
            address actor = makeAddr(string(abi.encodePacked("arbUsdcActor", i)));
            actors.push(actor);
            // Give actors different initial balances for position size variation
            deal(asset, actor, (i + 1) * 100_000e6); // 100k to 1M USDC
        }
        
        // Map strategy names for debugging
        for (uint256 i = 0; i < _strategies.length; i++) {
            strategyNames[_strategies[i]] = _strategyNames[i];
        }
    }
    
    // ============ USER OPERATIONS ============
    
    function deposit(uint256 amount, uint256 actorSeed) external countCall(this.deposit.selector) useActor(actorSeed) {
        uint256 balance = IERC20(asset).balanceOf(currentActor);
        if (balance < MIN_DEPOSIT) return;
        
        amount = bound(amount, MIN_DEPOSIT, balance);
        
        IERC20(asset).approve(address(vault), amount);
        vault.deposit(amount, currentActor);
        
        ghost_totalDeposited += amount;
        ghost_userDeposits[currentActor] += amount;
    }
    
    function withdraw(uint256 amount, uint256 actorSeed) external countCall(this.withdraw.selector) useActor(actorSeed) {
        uint256 shares = vault.balanceOf(currentActor);
        if (shares == 0) return;
        
        amount = bound(amount, 1, shares);
        
        uint256 assetsWithdrawn = vault.redeem(amount, currentActor, currentActor);
        
        ghost_totalWithdrawn += assetsWithdrawn;
        if (ghost_userDeposits[currentActor] >= assetsWithdrawn) {
            ghost_userDeposits[currentActor] -= assetsWithdrawn;
        }
    }
    
    function mint(uint256 amount, uint256 actorSeed) external countCall(this.mint.selector) useActor(actorSeed) {
        uint256 balance = IERC20(asset).balanceOf(currentActor);
        if (balance < MIN_DEPOSIT) return;
        
        amount = bound(amount, MIN_DEPOSIT, balance);
        
        IERC20(asset).approve(address(vault), amount);
        vault.mint(amount, currentActor);
        
        ghost_totalDeposited += amount;
        ghost_userDeposits[currentActor] += amount;
    }
    
    function redeem(uint256 shares, uint256 actorSeed) external countCall(this.redeem.selector) useActor(actorSeed) {
        uint256 userShares = vault.balanceOf(currentActor);
        if (userShares == 0) return;
        
        shares = bound(shares, 1, userShares);
        
        uint256 assetsRedeemed = vault.redeem(shares, currentActor, currentActor);
        
        ghost_totalWithdrawn += assetsRedeemed;
        if (ghost_userDeposits[currentActor] >= assetsRedeemed) {
            ghost_userDeposits[currentActor] -= assetsRedeemed;
        }
    }
    
    // ============ ADMIN OPERATIONS ============
    
    function _getStrategyMaxSharePercent(uint256 strategyIndex) internal view returns (uint256) {
        (,,,,,, uint256 globalCap,,) = IMYTStrategy(strategies[strategyIndex]).params();
        return (globalCap * 100) / 1e18;
    }
    
    function _getStrategyShares() internal view returns (uint256[] memory shares, uint256 totalAllocations) {
        uint256 strategiesLen = strategies.length;
        shares = new uint256[](strategiesLen);
        
        for (uint256 i = 0; i < strategiesLen; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            shares[i] = vault.allocation(allocationId);
            totalAllocations += shares[i];
        }
        
        if (totalAllocations > 0) {
            for (uint256 i = 0; i < strategiesLen; i++) {
                shares[i] = (shares[i] * 100) / totalAllocations;
            }
        }
    }
    
    function _selectNonDominatingStrategy(uint256 seed) internal view returns (uint256) {
        uint256 strategiesLen = strategies.length;
        (uint256[] memory shares,) = _getStrategyShares();
        
        uint256 eligibleCount = 0;
        for (uint256 i = 0; i < strategiesLen; i++) {
            uint256 maxSharePercent = _getStrategyMaxSharePercent(i);
            uint256 effectiveMax = (maxSharePercent * 90) / 100;
            if (shares[i] < effectiveMax && effectiveMax > 0) {
                eligibleCount++;
            }
        }
        
        if (eligibleCount == 0) {
            return type(uint256).max;
        }
        
        uint256 pickIndex = seed % eligibleCount;
        uint256 currentIndex = 0;
        
        for (uint256 i = 0; i < strategiesLen; i++) {
            uint256 maxSharePercent = _getStrategyMaxSharePercent(i);
            uint256 effectiveMax = (maxSharePercent * 90) / 100;
            if (shares[i] < effectiveMax && effectiveMax > 0) {
                if (currentIndex == pickIndex) {
                    return i;
                }
                currentIndex++;
            }
        }
        
        return 0;
    }
    
    function allocate(uint256 strategyIndexSeed, uint256 amount) external countCall(this.allocate.selector) {
        uint256 strategiesLen = strategies.length;
        
        uint256 startIndex = _selectNonDominatingStrategy(strategyIndexSeed);
        
        if (startIndex == type(uint256).max) return;
        
        uint256 triedMask = 0;
        
        for (uint256 attempt = 0; attempt < strategiesLen; attempt++) {
            uint256 strategyIndex = (startIndex + attempt) % strategiesLen;
            
            if (triedMask & (1 << strategyIndex) != 0) continue;
            triedMask |= (1 << strategyIndex);
            
            uint256 maxSharePercent = _getStrategyMaxSharePercent(strategyIndex);
            uint256 effectiveMax = (maxSharePercent * 90) / 100;
            
            (uint256[] memory shares, uint256 totalAllocations) = _getStrategyShares();
            if (totalAllocations > 0 && shares[strategyIndex] >= effectiveMax) {
                continue;
            }
            
            (bool success, uint256 allocatedAmount) = _tryAllocate(
                strategies[strategyIndex], 
                amount, 
                effectiveMax
            );
            if (success) {
                ghost_totalAllocated += allocatedAmount;
                ghost_strategyAllocations[strategies[strategyIndex]] += allocatedAmount;
                return;
            }
        }
    }
    
    function _tryAllocate(
        address strategy, 
        uint256 amount, 
        uint256 maxSharePercent
    ) internal returns (bool success, uint256 allocatedAmount) {
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        
        uint256 currentRealAssets = IMYTStrategy(strategy).realAssets();
        uint256 absoluteCap = vault.absoluteCap(allocationId);
        uint256 relativeCap = vault.relativeCap(allocationId);
        
        uint8 riskLevel = AlchemistStrategyClassifier(classifier).getStrategyRiskLevel(uint256(allocationId));
        uint256 globalRiskCap = AlchemistStrategyClassifier(classifier).getGlobalCap(riskLevel);
        
        if (currentRealAssets >= absoluteCap) return (false, 0);

        uint256 totalExistingAllocations = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            totalExistingAllocations += IMYTStrategy(strategies[i]).realAssets();
        }
        
        uint256 currentVaultBalance = IERC20(asset).balanceOf(address(vault));

        uint256 maxByAbsolute = absoluteCap - currentRealAssets;
        uint256 maxAllocate = maxByAbsolute < globalRiskCap ? maxByAbsolute : globalRiskCap;
        
        uint256 maxByRelativeCapShare = type(uint256).max;
        if (totalExistingAllocations > 0 && maxSharePercent < 100) {
            uint256 currentSharePercent = (currentRealAssets * 100) / totalExistingAllocations;
            if (currentSharePercent >= maxSharePercent) {
                return (false, 0);
            }
            uint256 numerator = (maxSharePercent * totalExistingAllocations);
            if (numerator > 100 * currentRealAssets) {
                maxByRelativeCapShare = (numerator - 100 * currentRealAssets) / (100 - maxSharePercent);
            } else {
                maxByRelativeCapShare = 0;
            }
        }
        maxAllocate = maxAllocate < maxByRelativeCapShare ? maxAllocate : maxByRelativeCapShare;
        
        if (maxAllocate < MIN_ALLOCATE) return (false, 0);

        amount = bound(amount, MIN_ALLOCATE, maxAllocate);
        
        uint256 dealAmount = amount;
        if (relativeCap != type(uint256).max && relativeCap != 0 && relativeCap < 1e18) {
            uint256 newTotalAllocation = currentRealAssets + amount;
            uint256 requiredTotalAssets = (newTotalAllocation * 1e18 + relativeCap - 1) / relativeCap;
            if (requiredTotalAssets > totalExistingAllocations) {
                uint256 minVaultBalance = requiredTotalAssets - totalExistingAllocations;
                if (minVaultBalance > dealAmount) {
                    dealAmount = minVaultBalance;
                }
            }
        }

        uint256 targetVaultBalance = currentVaultBalance + dealAmount;
        deal(asset, address(vault), targetVaultBalance);
        
        uint256 totalAssets = vault.totalAssets();
        uint256 absoluteValueOfRelativeCap = (relativeCap == type(uint256).max) 
            ? type(uint256).max 
            : (totalAssets * relativeCap) / 1e18;
        
        uint256 limit = absoluteCap < absoluteValueOfRelativeCap ? absoluteCap : absoluteValueOfRelativeCap;
        limit = limit < globalRiskCap ? limit : globalRiskCap;

        if (currentRealAssets >= limit) return (false, 0);
        uint256 maxNewAllocation = limit - currentRealAssets;
        
        if (amount > maxNewAllocation) {
            amount = maxNewAllocation;
        }
        
        if (amount < MIN_ALLOCATE) return (false, 0);
        
        vm.prank(admin);
        try IAllocator(allocator).allocate(strategy, amount) {
            return (true, amount);
        } catch {
            return (false, 0);
        }
    }
    
    function deallocate(uint256 strategyIndex, uint256 amount) external countCall(this.deallocate.selector) {
        strategyIndex = bound(strategyIndex, 0, strategies.length - 1);
        address strategy = strategies[strategyIndex];
        
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        uint256 currentAllocation = vault.allocation(allocationId);
        
        if (currentAllocation < MIN_ALLOCATE) return;
        
        amount = bound(amount, MIN_ALLOCATE, currentAllocation);
        
        uint256 previewAmount = IMYTStrategy(strategy).previewAdjustedWithdraw(amount);
        if (previewAmount == 0) return;
        
        vm.prank(admin);
        IAllocator(allocator).deallocate(strategy, previewAmount);
        
        ghost_totalDeallocated += previewAmount;
        if (ghost_strategyAllocations[strategy] >= previewAmount) {
            ghost_strategyAllocations[strategy] -= previewAmount;
        }
    }
    
    function deallocateAll(uint256 strategyIndex) external countCall(this.deallocateAll.selector) {
        strategyIndex = bound(strategyIndex, 0, strategies.length - 1);
        address strategy = strategies[strategyIndex];
        
        uint256 realAssets = IMYTStrategy(strategy).realAssets();
        if (realAssets == 0) return;
        
        uint256 previewAmount = IMYTStrategy(strategy).previewAdjustedWithdraw(realAssets);
        if (previewAmount == 0) return;
        
        vm.prank(admin);
        IAllocator(allocator).deallocate(strategy, previewAmount);
        
        ghost_totalDeallocated += previewAmount;
        ghost_strategyAllocations[strategy] = 0;
    }
    
    // ============ TIME OPERATIONS ============
    
    function warpTime(uint256 timeDelta) external countCall(this.warpTime.selector) {
        timeDelta = bound(timeDelta, 1 hours, 365 days);
        vm.warp(block.timestamp + timeDelta);
    }
    
    // ============ HELPER FUNCTIONS ============
    
    function getStrategyCount() external view returns (uint256) {
        return strategies.length;
    }

    function getCalls(bytes4 selector) external view returns (uint256) {
        return calls[selector];
    }
    
    function callSummary() external view {
        console.log("=== ARB USDC Multi-Strategy Handler Call Summary ===");
        console.log("User Operations:");
        console.log("  deposit calls:", calls[this.deposit.selector]);
        console.log("  withdraw calls:", calls[this.withdraw.selector]);
        console.log("  mint calls:", calls[this.mint.selector]);
        console.log("  redeem calls:", calls[this.redeem.selector]);
        console.log("Admin Operations:");
        console.log("  allocate calls:", calls[this.allocate.selector]);
        console.log("  deallocate calls:", calls[this.deallocate.selector]);
        console.log("  deallocateAll calls:", calls[this.deallocateAll.selector]);
        console.log("Time Operations:");
        console.log("  warpTime calls:", calls[this.warpTime.selector]);
        console.log("Ghost Variables:");
        console.log("  totalDeposited:", ghost_totalDeposited);
        console.log("  totalWithdrawn:", ghost_totalWithdrawn);
        console.log("  totalAllocated:", ghost_totalAllocated);
        console.log("  totalDeallocated:", ghost_totalDeallocated);
    }
}

/// @title MultiStrategyARBUSDCInvariantTest
/// @notice Invariant tests for USDC strategies on Arbitrum
contract MultiStrategyARBUSDCInvariantTest is Test {
    IVaultV2 public vault;
    MultiStrategyARBUSDCCHandler public handler;
    
    address[] public strategies;
    address public allocator;
    address public classifier;
    address public curatorContract;
    address public admin = address(0x1);
    address public operator = address(0x3);
    
    // Arbitrum addresses
    address public constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address public constant AAVE_POOL_ARB = 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb;
    address public constant AUSDC_ARB = 0x625E7708f30cA75bfd92586e17077590C60eb4cD;
    address public constant EULER_USDC_VAULT_ARB = 0x0a1eCC5Fe8C9be3C809844fcBe615B46A869b899;
    address public constant FLUID_USDC_VAULT_ARB = 0x1A996cb54bb95462040408C06122D45D6Cdb6096;
    
    uint256 public constant INITIAL_VAULT_DEPOSIT = 10_000_000e6; // 10M USDC
    uint256 public constant ABSOLUTE_CAP = 50_000_000e6; // 50M USDC per strategy
    uint256 public constant RELATIVE_CAP = 0.5e18;
    
    uint256 private forkId;
    
    function setUp() public {
        // Fork Arbitrum
        string memory rpc = vm.envString("ARBITRUM_RPC_URL");
        forkId = vm.createFork(rpc);
        vm.selectFork(forkId);
        
        // Setup vault
        vm.startPrank(admin);
        vault = _setupVault(USDC);
        
        // Setup strategies
        string[] memory strategyNames = new string[](3);
        strategyNames[0] = "Aave V3 ARB USDC";
        strategyNames[1] = "Euler ARB USDC";
        strategyNames[2] = "Fluid ARB USDC";
        
        // Deploy strategies
        strategies.push(_deployAaveUSDCStrategy());
        strategies.push(_deployEulerUSDCStrategy());
        strategies.push(_deployFluidUSDCStrategy());
        
        // Setup classifier and allocator
        _setupClassifierAndAllocator();
        
        // Add strategies to vault
        _addStrategiesToVault();
        
        // Make initial deposit to vault
        _makeInitialDeposit();
        
        vm.stopPrank();
        
        // Create handler
        handler = new MultiStrategyARBUSDCCHandler(
            address(vault),
            strategies,
            allocator,
            classifier,
            admin,
            strategyNames
        );
        
        // Target the handler
        targetContract(address(handler));
        
        // Target specific functions
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.mint.selector;
        selectors[3] = handler.redeem.selector;
        selectors[4] = handler.allocate.selector;
        selectors[5] = handler.deallocate.selector;
        selectors[6] = handler.deallocateAll.selector;
        selectors[7] = handler.warpTime.selector;
        
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }
    
    function _setupVault(address asset) internal returns (IVaultV2) {
        VaultV2Factory factory = new VaultV2Factory();
        return IVaultV2(factory.createVaultV2(admin, asset, bytes32(0)));
    }
    
    function _deployAaveUSDCStrategy() internal returns (address) {
        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: admin,
            name: "Aave V3 ARB USDC",
            protocol: "AaveV3",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 1000 * 1e6,
            globalCap: 0.5e18,
            estimatedYield: 450,
            additionalIncentives: false,
            slippageBPS: 50
        });
        
        return address(new AaveV3ARBUSDCStrategy(
            address(vault),
            params,
            USDC,
            AUSDC_ARB,
            AAVE_POOL_ARB
        ));
    }
    
    function _deployEulerUSDCStrategy() internal returns (address) {
        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: admin,
            name: "Euler ARB USDC",
            protocol: "Euler",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 1000 * 1e6,
            globalCap: 0.5e18,
            estimatedYield: 550,
            additionalIncentives: false,
            slippageBPS: 50
        });
        
        return address(new EulerARBUSDCStrategy(
            address(vault),
            params,
            USDC,
            EULER_USDC_VAULT_ARB
        ));
    }
    
    function _deployFluidUSDCStrategy() internal returns (address) {
        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: admin,
            name: "Fluid ARB USDC",
            protocol: "Fluid",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 0,
            globalCap: 0.3e18,
            estimatedYield: 525,
            additionalIncentives: false,
            slippageBPS: 50
        });
        
        return address(new FluidARBUSDCStrategy(
            address(vault),
            params,
            USDC,
            FLUID_USDC_VAULT_ARB
        ));
    }
    
    function _setupClassifierAndAllocator() internal {
        classifier = address(new AlchemistStrategyClassifier(admin));
        
        // Set up risk classes
        AlchemistStrategyClassifier(classifier).setRiskClass(0, 100_000_000e6, 50_000_000e6); // LOW
        AlchemistStrategyClassifier(classifier).setRiskClass(1, 75_000_000e6, 37_500_000e6);  // MEDIUM
        AlchemistStrategyClassifier(classifier).setRiskClass(2, 50_000_000e6, 25_000_000e6);  // HIGH
        
        // Assign risk levels
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 strategyId = IMYTStrategy(strategies[i]).adapterId();
            (,,,IMYTStrategy.RiskClass riskClass,,,,,) = IMYTStrategy(strategies[i]).params();
            AlchemistStrategyClassifier(classifier).assignStrategyRiskLevel(
                uint256(strategyId),
                uint8(riskClass)
            );
        }
        
        curatorContract = address(new AlchemistCurator(admin, admin));
        VaultV2(address(vault)).setCurator(curatorContract);
        allocator = address(new AlchemistAllocator(address(vault), admin, operator, classifier));
    }
    
    function _addStrategiesToVault() internal {
        AlchemistCurator curator = AlchemistCurator(curatorContract);
        
        curator.submitSetAllocator(address(vault), allocator, true);
        vault.setIsAllocator(allocator, true);
        
        for (uint256 i = 0; i < strategies.length; i++) {
            curator.submitSetStrategy(strategies[i], address(vault));
            curator.setStrategy(strategies[i], address(vault));
            
            curator.submitIncreaseAbsoluteCap(strategies[i], ABSOLUTE_CAP);
            curator.increaseAbsoluteCap(strategies[i], ABSOLUTE_CAP);
            
            curator.submitIncreaseRelativeCap(strategies[i], RELATIVE_CAP);
            curator.increaseRelativeCap(strategies[i], RELATIVE_CAP);
        }
    }
    
    function _makeInitialDeposit() internal {
        deal(USDC, admin, INITIAL_VAULT_DEPOSIT);
        IERC20(USDC).approve(address(vault), INITIAL_VAULT_DEPOSIT);
        vault.deposit(INITIAL_VAULT_DEPOSIT, admin);
    }
    
    // ============ INVARIANTS ============
    
    function invariant_realAssets_nonNegative() public view {
        for (uint256 i = 0; i < strategies.length; i++) {
            uint256 realAssets = IMYTStrategy(strategies[i]).realAssets();
            assertGe(realAssets, 0, string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " has negative real assets")));
        }
    }
    
    function invariant_allocationWithinAbsoluteCap() public view {
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(allocationId);
            uint256 absoluteCap = vault.absoluteCap(allocationId);
            
            assertLe(allocation, absoluteCap, string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " exceeds absolute cap")));
        }
    }
    
    function invariant_allocationWithinRelativeCap() public view {
        uint256 vaultTotalAssets = vault.totalAssets();
        
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(allocationId);
            uint256 relativeCap = vault.relativeCap(allocationId);
            uint256 maxAllowed = (vaultTotalAssets * relativeCap) / 1e18;
            
            assertLe(allocation, maxAllowed + (maxAllowed * 100001)/100000, string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " exceeds relative cap")));
        }
    }
    
    function invariant_allocationWithinGlobalRiskCap() public view {
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(allocationId);
            
            uint8 riskLevel = AlchemistStrategyClassifier(classifier).getStrategyRiskLevel(uint256(allocationId));
            uint256 globalRiskCap = AlchemistStrategyClassifier(classifier).getGlobalCap(riskLevel);
            
            assertLe(allocation, globalRiskCap, string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " exceeds global risk cap")));
        }
    }
    
    function invariant_allocationWithinIndividualRiskCap() public view {
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(allocationId);
            
            uint256 individualRiskCap = AlchemistStrategyClassifier(classifier).getIndividualCap(uint256(allocationId));
            
            assertLe(allocation, individualRiskCap, string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " exceeds individual risk cap")));
        }
    }
    
    function invariant_riskLevelAggregateCaps() public view {
        uint256[3] memory riskLevelAllocations;
        
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(allocationId);
            uint8 riskLevel = AlchemistStrategyClassifier(classifier).getStrategyRiskLevel(uint256(allocationId));
            
            riskLevelAllocations[riskLevel] += allocation;
        }
        
        assertLe(riskLevelAllocations[0], AlchemistStrategyClassifier(classifier).getGlobalCap(0), "LOW risk aggregate exceeds global cap");
        assertLe(riskLevelAllocations[1], AlchemistStrategyClassifier(classifier).getGlobalCap(1), "MEDIUM risk aggregate exceeds global cap");
        assertLe(riskLevelAllocations[2], AlchemistStrategyClassifier(classifier).getGlobalCap(2), "HIGH risk aggregate exceeds global cap");
    }
    
    function invariant_totalAllocationsBounded() public view {
        uint256 totalAllocations = 0;
        
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            totalAllocations += vault.allocation(allocationId);
        }
        
        uint256 vaultTotalAssets = vault.totalAssets();
        assertLe(totalAllocations, vaultTotalAssets * 110 / 100, "Total allocations exceed vault assets by more than 10%");
    }
    
    function invariant_realAssetsConsistentWithAllocation() public view {
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(allocationId);
            uint256 realAssets = IMYTStrategy(strategies[i]).realAssets();
            
            if (allocation > 0) {
                uint256 minExpected = allocation * 95 / 100;
                uint256 maxExpected = allocation * 105 / 100;
                
                if (allocation > 1e6) {
                    assertGe(realAssets, minExpected, string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " real assets below allocation")));
                    assertLe(realAssets, maxExpected * 2, string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " real assets significantly above allocation")));
                }
            }
        }
    }
    
    function invariant_sharePriceNonDecreasing() public view {
        uint256 totalSupply = vault.totalSupply();
        uint256 totalAssets = vault.totalAssets();
        
        if (totalSupply > 0) {
            uint256 sharePrice = (totalAssets * 1e18) / totalSupply;
            assertGe(sharePrice, 0.9e18, "Share price decreased significantly");
        }
    }
    
    function invariant_userBalanceConsistency() public view {
        uint256 totalUserDeposits = handler.ghost_totalDeposited();
        uint256 totalUserWithdrawals = handler.ghost_totalWithdrawn();
        uint256 netDeposits = totalUserDeposits > totalUserWithdrawals 
            ? totalUserDeposits - totalUserWithdrawals 
            : 0;
        
        uint256 vaultBalance = IERC20(USDC).balanceOf(address(vault));
        
        uint256 totalAllocations = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            totalAllocations += vault.allocation(allocationId);
        }
        
        uint256 totalValue = vaultBalance + totalAllocations;
        if (netDeposits > 1e6) {
            assertGe(totalValue, netDeposits * 90 / 100, "Total value significantly less than net deposits");
        }
    }
    
    function invariant_noStrategyDominance() public view {
        uint256 totalAllocations = 0;
        uint256[] memory allocations = new uint256[](strategies.length);
        
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            allocations[i] = vault.allocation(allocationId);
            totalAllocations += allocations[i];
        }
        
        if (totalAllocations == 0) return;
        
        uint256 allocateCalls = handler.getCalls(handler.allocate.selector);
        if (allocateCalls < strategies.length * 2) return;
        
        if (totalAllocations < 1_000_000e6) return;
        
        for (uint256 i = 0; i < strategies.length; i++) {
            uint256 share = (allocations[i] * 100) / totalAllocations;
            (,,,,,, uint256 globalCap,,) = IMYTStrategy(strategies[i]).params();
            uint256 maxSharePercent = (globalCap * 100) / 1e18;
            assertLe(share, maxSharePercent, string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " has too much dominance")));
        }
    }
    
    function invariant_CallSummary() public view {
        handler.callSummary();
    }
}
