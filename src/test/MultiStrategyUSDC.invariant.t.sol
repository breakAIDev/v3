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
import {IAllocator} from "../interfaces/IAllocator.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {EulerUSDCStrategy} from "../strategies/mainnet/EulerUSDCStrategy.sol";
import {PeapodsUSDCStrategy} from "../strategies/mainnet/PeapodsUSDCStrategy.sol";
import {TokeAutoUSDStrategy} from "../strategies/mainnet/TokeAutoUSDStrategy.sol";

/// @title MultiStrategyUSDCHandler
/// @notice Handler for invariant testing multiple USDC strategies attached to a single vault
contract MultiStrategyUSDCHandler is Test {
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
            address actor = makeAddr(string(abi.encodePacked("usdcActor", i)));
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
    
    /// @notice User deposits assets into the vault
    function deposit(uint256 amount, uint256 actorSeed) external countCall(this.deposit.selector) useActor(actorSeed) {
        uint256 balance = IERC20(asset).balanceOf(currentActor);
        if (balance < MIN_DEPOSIT) return;
        
        amount = bound(amount, MIN_DEPOSIT, balance);
        
        IERC20(asset).approve(address(vault), amount);
        vault.deposit(amount, currentActor);
        
        ghost_totalDeposited += amount;
        ghost_userDeposits[currentActor] += amount;
    }
    
    /// @notice User withdraws assets from the vault
    function withdraw(uint256 amount, uint256 actorSeed) external countCall(this.withdraw.selector) useActor(actorSeed) {
        uint256 shares = vault.balanceOf(currentActor);
        if (shares == 0) return;
        
        // Withdraw up to user's share balance
        amount = bound(amount, 1, shares);
        
        uint256 assetsWithdrawn = vault.redeem(amount, currentActor, currentActor);
        
        ghost_totalWithdrawn += assetsWithdrawn;
        if (ghost_userDeposits[currentActor] >= assetsWithdrawn) {
            ghost_userDeposits[currentActor] -= assetsWithdrawn;
        }
    }
    
    /// @notice User mints shares by providing exact assets
    function mint(uint256 amount, uint256 actorSeed) external countCall(this.mint.selector) useActor(actorSeed) {
        uint256 balance = IERC20(asset).balanceOf(currentActor);
        if (balance < MIN_DEPOSIT) return;
        
        amount = bound(amount, MIN_DEPOSIT, balance);
        
        IERC20(asset).approve(address(vault), amount);
        vault.mint(amount, currentActor);
        
        ghost_totalDeposited += amount;
        ghost_userDeposits[currentActor] += amount;
    }
    
    /// @notice User redeems exact shares for assets
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
    
    /// @notice Maximum share any single strategy can have of total allocations (as safety buffer)
    uint256 public constant MAX_STRATEGY_SHARE = 60;
    
    /// @notice Returns the maximum allowed share percentage for each strategy based on globalCap
    /// @dev Uses the strategy's params.globalCap which defines max % of total assets
    function _getStrategyMaxSharePercent(uint256 strategyIndex) internal view returns (uint256) {
        (,,,,,, uint256 globalCap,,) = IMYTStrategy(strategies[strategyIndex]).params();
        // Convert from WAD (1e18) to percentage (0-100)
        return (globalCap * 100) / 1e18;
    }
    
    /// @notice Returns the current share percentage (0-100) of each strategy
    function _getStrategyShares() internal view returns (uint256[] memory shares, uint256 totalAllocations) {
        uint256 strategiesLen = strategies.length;
        shares = new uint256[](strategiesLen);
        
        for (uint256 i = 0; i < strategiesLen; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            shares[i] = vault.allocation(allocationId);
            totalAllocations += shares[i];
        }
        
        // Convert to percentages
        if (totalAllocations > 0) {
            for (uint256 i = 0; i < strategiesLen; i++) {
                shares[i] = (shares[i] * 100) / totalAllocations;
            }
        }
    }
    
    /// @notice Selects a random strategy from those that haven't reached their relative cap share
    /// @dev Uses each strategy's actual relative cap to determine eligibility
    function _selectNonDominatingStrategy(uint256 seed) internal view returns (uint256) {
        uint256 strategiesLen = strategies.length;
        (uint256[] memory shares,) = _getStrategyShares();
        
        // Count eligible strategies (those below their relative cap share)
        uint256 eligibleCount = 0;
        for (uint256 i = 0; i < strategiesLen; i++) {
            uint256 maxSharePercent = _getStrategyMaxSharePercent(i);
            // Use 90% of max as buffer to avoid hitting cap exactly
            uint256 effectiveMax = (maxSharePercent * 90) / 100;
            if (shares[i] < effectiveMax && effectiveMax > 0) {
                eligibleCount++;
            }
        }
        
        // If no eligible strategies, all are at cap - return type(uint256).max as signal
        if (eligibleCount == 0) {
            return type(uint256).max;
        }
        
        // Pick randomly among eligible strategies
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
        
        // Should never reach here
        return 0;
    }
    
    /// @notice Admin allocates assets to a specific strategy
    /// @dev Respects each strategy's relative cap to ensure balanced distribution
    function allocate(uint256 strategyIndexSeed, uint256 amount) external countCall(this.allocate.selector) {
        uint256 strategiesLen = strategies.length;
        
        // Select a strategy that hasn't reached its relative cap share
        uint256 startIndex = _selectNonDominatingStrategy(strategyIndexSeed);
        
        // If all strategies are at cap, we can't allocate
        if (startIndex == type(uint256).max) return;
        
        // Track which strategies we've tried to avoid infinite loops
        uint256 triedMask = 0;
        
        for (uint256 attempt = 0; attempt < strategiesLen; attempt++) {
            uint256 strategyIndex = (startIndex + attempt) % strategiesLen;
            
            // Skip if already tried
            if (triedMask & (1 << strategyIndex) != 0) continue;
            triedMask |= (1 << strategyIndex);
            
            // Check relative cap guard - use strategy's specific max share
            uint256 maxSharePercent = _getStrategyMaxSharePercent(strategyIndex);
            uint256 effectiveMax = (maxSharePercent * 90) / 100; // 90% buffer
            
            (uint256[] memory shares, uint256 totalAllocations) = _getStrategyShares();
            if (totalAllocations > 0 && shares[strategyIndex] >= effectiveMax) {
                continue;
            }
            
            (bool success, uint256 allocatedAmount) = _tryAllocate(
                strategies[strategyIndex], 
                amount, 
                strategyIndexSeed,
                strategyIndex,
                effectiveMax
            );
            if (success) {
                ghost_totalAllocated += allocatedAmount;
                ghost_strategyAllocations[strategies[strategyIndex]] += allocatedAmount;
                console.log("allocation finished");
                return;
            }
        }
        // If no strategy could accept allocation, silently return
    }
    
    /// @notice Attempts to allocate to a specific strategy, returns success and amount allocated
    /// @param maxSharePercent The maximum share percentage this strategy can have (based on relative cap)
    function _tryAllocate(
        address strategy, 
        uint256 amount, 
        uint256 /* seed */,
        uint256 /* strategyIndex */,
        uint256 maxSharePercent
    ) internal returns (bool success, uint256 allocatedAmount) {
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        
        // Use realAssets() to account for accrued yield that will be reported in _totalValue()
        uint256 currentRealAssets = IMYTStrategy(strategy).realAssets();
        uint256 absoluteCap = vault.absoluteCap(allocationId);
        uint256 relativeCap = vault.relativeCap(allocationId);
        
        // Get risk caps from classifier
        uint8 riskLevel = AlchemistStrategyClassifier(classifier).getStrategyRiskLevel(uint256(allocationId));
        uint256 globalRiskCap = AlchemistStrategyClassifier(classifier).getGlobalCap(riskLevel);
        
        // Get the underlying vault's max deposit to respect protocol-level caps
        uint256 underlyingMaxDeposit = _getUnderlyingMaxDeposit(strategy);
        if (underlyingMaxDeposit < MIN_ALLOCATE) return (false, 0);
        
        // Check absolute cap headroom
        if (currentRealAssets >= absoluteCap) return (false, 0);

        uint256 totalExistingAllocations = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            totalExistingAllocations += IMYTStrategy(strategies[i]).realAssets();
        }
        
        uint256 currentVaultBalance = IERC20(asset).balanceOf(address(vault));

        uint256 maxByAbsolute = absoluteCap - currentRealAssets;
        uint256 maxAllocate = maxByAbsolute < globalRiskCap ? maxByAbsolute : globalRiskCap;
        maxAllocate = maxAllocate < underlyingMaxDeposit ? maxAllocate : underlyingMaxDeposit;
        
        // Constrain by this strategy's relative cap share
        // We want: (currentRealAssets + x) / (totalExistingAllocations + x) <= maxSharePercent / 100
        // Solving: x <= (maxSharePercent * totalExistingAllocations - 100 * currentRealAssets) / (100 - maxSharePercent)
        uint256 maxByRelativeCapShare = type(uint256).max;
        if (totalExistingAllocations > 0 && maxSharePercent < 100) {
            uint256 currentSharePercent = (currentRealAssets * 100) / totalExistingAllocations;
            if (currentSharePercent >= maxSharePercent) {
                return (false, 0); // Already at or over limit
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
        
        // Calculate deal amount for relative cap compliance
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
        
        // Re-calculate effective limit AFTER deal
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
    
    /// @notice Admin deallocates assets from a specific strategy
    function deallocate(uint256 strategyIndex, uint256 amount) external countCall(this.deallocate.selector) {
        strategyIndex = bound(strategyIndex, 0, strategies.length - 1);
        address strategy = strategies[strategyIndex];
        
        bytes32 allocationId = IMYTStrategy(strategy).adapterId();
        uint256 currentAllocation = vault.allocation(allocationId);
        
        if (currentAllocation < MIN_ALLOCATE) return;
        
        amount = bound(amount, MIN_ALLOCATE, currentAllocation);
        
        // Get preview for adjusted withdraw
        uint256 previewAmount = IMYTStrategy(strategy).previewAdjustedWithdraw(amount);
        if (previewAmount == 0) return;
        
        vm.prank(admin);
        IAllocator(allocator).deallocate(strategy, previewAmount);
        
        ghost_totalDeallocated += previewAmount;
        if (ghost_strategyAllocations[strategy] >= previewAmount) {
            ghost_strategyAllocations[strategy] -= previewAmount;
        }
    }
    
    /// @notice Deallocaes all assets from a specific strategy
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
    
    /// @notice Advance time for yield accumulation
    function warpTime(uint256 timeDelta) external countCall(this.warpTime.selector) {
        timeDelta = bound(timeDelta, 1 hours, 365 days);
        vm.warp(block.timestamp + timeDelta);
    }
    
    /// @notice Advance time with strategy-specific hooks
    function warpTimeWithStrategyHook(uint256 timeDelta, uint256 strategyIndex) external countCall(this.warpTimeWithStrategyHook.selector) {
        timeDelta = bound(timeDelta, 1 hours, 365 days);
        strategyIndex = bound(strategyIndex, 0, strategies.length - 1);
        
        // Strategy-specific time hooks could be added here for protocols that need them
        // (e.g., Tokemak oracle mocking)
        
        vm.warp(block.timestamp + timeDelta);
    }
    
    // ============ REWARD OPERATIONS ============
    
    /// @notice Claim rewards from a strategy (mocked swap)
    /// @dev This is a placeholder - actual implementation needs real swap calldata
    function claimRewards(uint256 strategyIndex, uint256 /* minAmountOut */) external countCall(this.claimRewards.selector) {
        strategyIndex = bound(strategyIndex, 0, strategies.length - 1);
        address strategy = strategies[strategyIndex];
        
        // Check if strategy has rewards functionality
        try IMYTStrategy(strategy).claimRewards(address(0), "", 0) returns (uint256) {
            // If it doesn't revert, rewards might be available
            // In production, we'd need proper swap calldata
        } catch {
            // Expected for strategies without rewards or with bad calldata
        }
    }
    
    /// @dev Get the maximum deposit amount for the underlying protocol vault
    /// This accounts for protocol-level supply caps (e.g., Euler's E_SupplyCapExceeded)
    function _getUnderlyingMaxDeposit(address strategy) internal view returns (uint256) {
        // Try to get the underlying vault from the strategy and query its maxDeposit
        // EulerUSDCStrategy exposes `vault` as an IERC4626
        if (keccak256(bytes(strategyNames[strategy])) == keccak256("Euler Mainnet USDC")) {
            try EulerUSDCStrategy(strategy).vault().maxDeposit(strategy) returns (uint256 max) {
                return max;
            } catch {
                return type(uint256).max; // If call fails, don't constrain
            }
        }
        // For other strategies, add similar checks as needed
        return type(uint256).max; // Default: no additional constraint
    }
    
    function getStrategyCount() external view returns (uint256) {
        return strategies.length;
    }
    
    function getStrategy(uint256 index) external view returns (address) {
        return strategies[index];
    }
    
    function getCalls(bytes4 selector) external view returns (uint256) {
        return calls[selector];
    }
    
    function callSummary() external view {
        console.log("=== USDC Multi-Strategy Handler Call Summary ===");
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
        console.log("  warpTimeWithStrategyHook calls:", calls[this.warpTimeWithStrategyHook.selector]);
        console.log("Reward Operations:");
        console.log("  claimRewards calls:", calls[this.claimRewards.selector]);
        console.log("Ghost Variables:");
        console.log("  totalDeposited:", ghost_totalDeposited);
        console.log("  totalWithdrawn:", ghost_totalWithdrawn);
        console.log("  totalAllocated:", ghost_totalAllocated);
        console.log("  totalDeallocated:", ghost_totalDeallocated);
    }
}

/// @title MultiStrategyUSDCInvariantTest
/// @notice Invariant tests for USDC strategies attached to a single vault
contract MultiStrategyUSDCInvariantTest is Test {
    IVaultV2 public vault;
    MultiStrategyUSDCHandler public handler;
    
    address[] public strategies;
    address public allocator;
    address public classifier;
    address public curatorContract;
    address public admin = address(0x1);
    address public operator = address(0x3);
    
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant EULER_USDC_VAULT = 0xe0a80d35bB6618CBA260120b279d357978c42BCE;
    address public constant PEAPODS_USDC_VAULT = 0x3717e340140D30F3A077Dd21fAc39A86ACe873AA;
    address public constant TOKE_AUTO_USD_VAULT = 0xa7569A44f348d3D70d8ad5889e50F78E33d80D35;
    address public constant AUTOPILOT_ROUTER = 0x37dD409f5e98aB4f151F4259Ea0CC13e97e8aE21;
    address public constant TOKE_REWARDER_USD = 0x726104CfBd7ece2d1f5b3654a19109A9e2b6c27B;
    
    uint256 public constant INITIAL_VAULT_DEPOSIT = 10_000_000e6; // 10M USDC
    uint256 public constant ABSOLUTE_CAP = 50_000_000e6; // 50M USDC per strategy
    uint256 public constant RELATIVE_CAP = 0.5e18; // 50% of vault assets
    
    uint256 private forkId;
    
    function setUp() public {
        // Fork mainnet at specific block
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        forkId = vm.createFork(rpc, 22_089_302);
        vm.selectFork(forkId);
        
        // Setup vault
        vm.startPrank(admin);
        vault = _setupVault(USDC);
        
        // Setup strategies
        string[] memory strategyNames = new string[](3);
        strategyNames[0] = "Euler Mainnet USDC";
        strategyNames[1] = "Peapods Mainnet USDC";
        strategyNames[2] = "TokeAutoUSD Mainnet";
        
        // Deploy Euler USDC Strategy
        strategies.push(_deployEulerStrategy());
        
        // Deploy Peapods USDC Strategy
        strategies.push(_deployPeapodsStrategy());
        
        // Deploy TokeAuto USD Strategy
        strategies.push(_deployTokeStrategy());
        
        // Setup classifier and allocator
        _setupClassifierAndAllocator();
        
        // Add strategies to vault
        _addStrategiesToVault();
        
        // Make initial deposit to vault
        _makeInitialDeposit();
        
        vm.stopPrank();
        
        // Create handler
        handler = new MultiStrategyUSDCHandler(
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
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.mint.selector;
        selectors[3] = handler.redeem.selector;
        selectors[4] = handler.allocate.selector;
        selectors[5] = handler.deallocate.selector;
        selectors[6] = handler.deallocateAll.selector;
        selectors[7] = handler.warpTime.selector;
        selectors[8] = handler.claimRewards.selector;
        
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }
    
    function _setupVault(address asset) internal returns (IVaultV2) {
        // Deploy vault using factory pattern matching deployment script
        VaultV2Factory factory = new VaultV2Factory();
        return IVaultV2(factory.createVaultV2(admin, asset, bytes32(0)));
    }
    
    function _deployEulerStrategy() internal returns (address) {
        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: admin,
            name: "Euler Mainnet USDC",
            protocol: "Euler",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 1e6 * 1e6,
            globalCap: 0.5e18,
            estimatedYield: 500,
            additionalIncentives: false,
            slippageBPS: 50
        });
        
        return address(new EulerUSDCStrategy(address(vault), params, USDC, EULER_USDC_VAULT));
    }
    
    function _deployPeapodsStrategy() internal returns (address) {
        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: admin,
            name: "Peapods Mainnet USDC",
            protocol: "Peapods",
            riskClass: IMYTStrategy.RiskClass.HIGH,
            cap: 1e6 * 1e6,
            globalCap: 0.2e18,
            estimatedYield: 550,
            additionalIncentives: false,
            slippageBPS: 50
        });
        
        return address(new PeapodsUSDCStrategy(address(vault), params, PEAPODS_USDC_VAULT, USDC));
    }
    
    function _deployTokeStrategy() internal returns (address) {
        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: admin,
            name: "TokeAutoUSD Mainnet",
            protocol: "TokeAuto",
            riskClass: IMYTStrategy.RiskClass.MEDIUM,
            cap: 1e6 * 1e6,
            globalCap: 0.3e18,
            estimatedYield: 750,
            additionalIncentives: false,
            slippageBPS: 50
        });
        
        return address(new TokeAutoUSDStrategy(
            address(vault),
            params,
            USDC,
            TOKE_AUTO_USD_VAULT,
            AUTOPILOT_ROUTER,
            TOKE_REWARDER_USD
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
        
        // Deploy curator for timelocked operations
        curatorContract = address(new AlchemistCurator(admin, admin));
        
        // Set curator on vault (owner can do this directly)
        VaultV2(address(vault)).setCurator(curatorContract);
        
        allocator = address(new AlchemistAllocator(address(vault), admin, operator, classifier));
    }
    
    function _addStrategiesToVault() internal {
        // Use curator for timelocked operations
        AlchemistCurator curator = AlchemistCurator(curatorContract);
        
        // Submit and set allocator through curator
        curator.submitSetAllocator(address(vault), allocator, true);
        vault.setIsAllocator(allocator, true);
        
        for (uint256 i = 0; i < strategies.length; i++) {
            // Submit and add adapter through curator
            curator.submitSetStrategy(strategies[i], address(vault));
            curator.setStrategy(strategies[i], address(vault));
            
            // Submit and set absolute cap through curator
            curator.submitIncreaseAbsoluteCap(strategies[i], ABSOLUTE_CAP);
            curator.increaseAbsoluteCap(strategies[i], ABSOLUTE_CAP);
            
            // Note: relative caps are already defined in strategy params.globalCap
            // (Euler: 50%, Peapods: 20%, TokeAuto: 30%)
        }
    }
    
    function _makeInitialDeposit() internal {
        deal(USDC, admin, INITIAL_VAULT_DEPOSIT);
        IERC20(USDC).approve(address(vault), INITIAL_VAULT_DEPOSIT);
        vault.deposit(INITIAL_VAULT_DEPOSIT, admin);
    }
    
    // ============ INVARIANTS ============
    
    /// @notice Invariant: All strategies must have non-negative real assets
    function invariant_realAssets_nonNegative() public view {
        for (uint256 i = 0; i < strategies.length; i++) {
            uint256 realAssets = IMYTStrategy(strategies[i]).realAssets();
            assertGe(realAssets, 0, string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " has negative real assets")));
        }
    }
    
    /// @notice Invariant: No strategy allocation exceeds absolute cap
    function invariant_allocationWithinAbsoluteCap() public view {
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(allocationId);
            uint256 absoluteCap = vault.absoluteCap(allocationId);
            
            assertLe(allocation, absoluteCap, string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " exceeds absolute cap")));
        }
    }
    
    /// @notice Invariant: No strategy allocation exceeds relative cap
    function invariant_allocationWithinRelativeCap() public view {
        uint256 vaultTotalAssets = vault.totalAssets();
        
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(allocationId);
            uint256 relativeCap = vault.relativeCap(allocationId);
            uint256 maxAllowed = (vaultTotalAssets * relativeCap) / 1e18;
            
            // Allow small tolerance for rounding (0.001%)
            assertLe(allocation, maxAllowed + (maxAllowed * 100001)/100000 , string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " exceeds relative cap")));
        }
    }
    
    /// @notice Invariant: No strategy allocation exceeds global risk cap for its risk level
    function invariant_allocationWithinGlobalRiskCap() public view {
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(allocationId);
            
            // Get risk level and global cap from classifier
            uint8 riskLevel = AlchemistStrategyClassifier(classifier).getStrategyRiskLevel(uint256(allocationId));
            uint256 globalRiskCap = AlchemistStrategyClassifier(classifier).getGlobalCap(riskLevel);
            
            assertLe(allocation, globalRiskCap, string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " exceeds global risk cap")));
        }
    }
    
    /// @notice Invariant: No strategy allocation exceeds individual/local risk cap
    function invariant_allocationWithinIndividualRiskCap() public view {
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(allocationId);
            
            // Get individual cap from classifier
            uint256 individualRiskCap = AlchemistStrategyClassifier(classifier).getIndividualCap(uint256(allocationId));
            
            assertLe(allocation, individualRiskCap, string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " exceeds individual risk cap")));
        }
    }
    
    /// @notice Invariant: Total allocations per risk level don't exceed aggregate limits
    function invariant_riskLevelAggregateCaps() public view {
        uint256[3] memory riskLevelAllocations; // LOW, MEDIUM, HIGH
        
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(allocationId);
            uint8 riskLevel = AlchemistStrategyClassifier(classifier).getStrategyRiskLevel(uint256(allocationId));
            
            riskLevelAllocations[riskLevel] += allocation;
        }
        
        // Check each risk level's aggregate doesn't exceed its global cap
        assertLe(riskLevelAllocations[0], AlchemistStrategyClassifier(classifier).getGlobalCap(0), "LOW risk aggregate exceeds global cap");
        assertLe(riskLevelAllocations[1], AlchemistStrategyClassifier(classifier).getGlobalCap(1), "MEDIUM risk aggregate exceeds global cap");
        assertLe(riskLevelAllocations[2], AlchemistStrategyClassifier(classifier).getGlobalCap(2), "HIGH risk aggregate exceeds global cap");
    }
    
    /// @notice Invariant: Sum of all allocations should not exceed vault total assets significantly
    function invariant_totalAllocationsBounded() public view {
        uint256 totalAllocations = 0;
        
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            totalAllocations += vault.allocation(allocationId);
        }
        
        uint256 vaultTotalAssets = vault.totalAssets();
        
        // Total allocations should not exceed vault assets (plus tolerance for yield/rounding)
        assertLe(totalAllocations, vaultTotalAssets * 110 / 100, "Total allocations exceed vault assets by more than 10%");
    }
    
    /// @notice Invariant: Each strategy's real assets should be consistent with vault allocation
    function invariant_realAssetsConsistentWithAllocation() public view {
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            uint256 allocation = vault.allocation(allocationId);
            uint256 realAssets = IMYTStrategy(strategies[i]).realAssets();
            
            // Real assets should be within reasonable bounds of allocation
            // Allow 5% tolerance for yield/losses
            if (allocation > 0) {
                uint256 minExpected = allocation * 95 / 100;
                uint256 maxExpected = allocation * 105 / 100;
                
                // Only assert if allocation is significant
                if (allocation > 1e6) {
                    assertGe(realAssets, minExpected, string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " real assets below allocation")));
                    assertLe(realAssets, maxExpected * 2, string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " real assets significantly above allocation")));
                }
            }
        }
    }
    
    /// @notice Invariant: Vault share price should never decrease significantly
    /// While strategies can indeed suffer losses and realAssets can decrease
    /// between calls, price action is not part of the invariant testing suite :)
    function invariant_sharePriceNonDecreasing() public view {
        uint256 totalSupply = vault.totalSupply();
        uint256 totalAssets = vault.totalAssets();
        
        if (totalSupply > 0) {
            uint256 sharePrice = (totalAssets * 1e18) / totalSupply;
            // Share price should be at least 0.9 (assuming initial share price of ~1)
            assertGe(sharePrice, 0.9e18, "Share price decreased significantly");
        }
    }
    
    /// @notice Invariant: User deposits minus withdrawals should equal their share of vault
    function invariant_userBalanceConsistency() public view {
        uint256 totalUserDeposits = handler.ghost_totalDeposited();
        uint256 totalUserWithdrawals = handler.ghost_totalWithdrawn();
        uint256 netDeposits = totalUserDeposits > totalUserWithdrawals 
            ? totalUserDeposits - totalUserWithdrawals 
            : 0;
        
        uint256 vaultBalance = IERC20(USDC).balanceOf(address(vault));
        
        // Vault balance + allocations should roughly equal net deposits
        uint256 totalAllocations = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            totalAllocations += vault.allocation(allocationId);
        }
        
        // Allow 10% tolerance for yield
        uint256 totalValue = vaultBalance + totalAllocations;
        if (netDeposits > 1e6) {
            assertGe(totalValue, netDeposits * 90 / 100, "Total value significantly less than net deposits");
        }
    }
    
    /// @notice Invariant: No single strategy dominates all allocations
    function invariant_noStrategyDominance() public view {
        uint256 totalAllocations = 0;
        uint256[] memory allocations = new uint256[](strategies.length);
        
        for (uint256 i = 0; i < strategies.length; i++) {
            bytes32 allocationId = IMYTStrategy(strategies[i]).adapterId();
            allocations[i] = vault.allocation(allocationId);
            totalAllocations += allocations[i];
        }
        
        // Skip if no allocations
        if (totalAllocations == 0) return;
        
        // Skip during warmup phase - need enough allocate calls to expect diversification
        // Require at least (strategies.length * 2) calls to give each strategy a fair chance
        uint256 allocateCalls = handler.getCalls(handler.allocate.selector);
        if (allocateCalls < strategies.length * 2) return;
        
        // Skip if total allocations are too small to be meaningful
        if (totalAllocations < 1_000_000e6) return; // Less than 1M USDC allocated
        console.log("we have", strategies.length, "strategies");
        console.log("total", totalAllocations);
        // No single strategy should have more than its globalCap share of total allocations
        for (uint256 i = 0; i < strategies.length; i++) {
            console.log("Strat has", allocations[i], " allocations");
            uint256 share = (allocations[i] * 100) / totalAllocations;
            console.log("Strat has", share, "shares");
            (,,,,,, uint256 globalCap,,) = IMYTStrategy(strategies[i]).params();
            uint256 maxSharePercent = (globalCap * 100) / 1e18;
            assertLe(share, maxSharePercent, string(abi.encodePacked("Strategy ", handler.strategyNames(strategies[i]), " has too much dominance")));
        }
    }
    
    /// @notice Print call summary for debugging
    function invariant_CallSummary() public view {
        handler.callSummary();
    }
}
