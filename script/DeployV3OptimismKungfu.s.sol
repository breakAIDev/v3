// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {VaultV2Factory} from "lib/vault-v2/src/VaultV2Factory.sol";
import {VaultV2, IVaultV2} from "lib/vault-v2/src/VaultV2.sol";

import {AlchemistV3} from "../src/AlchemistV3.sol";
import {Transmuter} from "../src/Transmuter.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {AlchemistInitializationParams} from "../src/interfaces/IAlchemistV3.sol";
import {ITransmuter} from "../src/interfaces/ITransmuter.sol";
import {AlchemistCurator} from "../src/AlchemistCurator.sol";
import {AlchemistAllocator} from "../src/AlchemistAllocator.sol";
import {AlchemistStrategyClassifier} from "../src/AlchemistStrategyClassifier.sol";
import {AlchemistTokenVault} from "../src/AlchemistTokenVault.sol";
import {AlchemistV3Position} from "../src/AlchemistV3Position.sol";

// Optimism Strategy Imports
import {AaveV3OPUSDCStrategy} from "../src/strategies/optimism/AaveV3OPUSDCStrategy.sol";
import {MoonwellUSDCStrategy} from "../src/strategies/optimism/MoonwellUSDCStrategy.sol";
import {MoonwellWETHStrategy} from "../src/strategies/optimism/MoonwellWETHStrategy.sol";

// AlAsset
//import {CrossChainCanonicalAlchemicTokenV2} from "../lib/v2-foundry/src/CrossChainCanonicalAlchemicTokenV2.sol";
import {CrossChainCanonicalAlchemicTokenV3} from "../src/AlTokenV3.sol";

// TODO
// deploy dummy alAssets first
// each alAsset has its own MYT, Alchemist, Transmuter
// each strategy binds to EITHER of these combos

interface AlAsset {
    function setWhitelist(address a, bool v) external;
}

contract DeployV3OptimismKungfuScript is Script {
    address immutable self;

    // Asset addresses
    address public aUSDC = 0x625E7708f30cA75bfd92586e17077590C60eb4cD;
    address public wethOP = 0x4200000000000000000000000000000000000006;
    address public alUSD = 0xb2c22A9fb4FC02eb9D1d337655Ce079a04a526C7;
    address public alETH = 0x3E29D3A9316dAB217754d13b28646B76607c5f04;
    address public USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

    // Price feed addresses
    address public ETH_USD_PRICE_FEED_MAINNET = 0x13e3Ee699D1909E989722E753853AE30b17e08c5;
    uint256 public ETH_USD_UPDATE_TIME_MAINNET = 3600 seconds;
    uint256 public constant liquidationTargetCollateralization = uint256(1e36) / 88e16; // ~113.63% (88% LTV)
                                                                                        //
    address public receiver = 0xC224bf25Dcc99236F00843c7D8C4194abE8AA94a;
    address public protocolFeeReceiver = 0xC224bf25Dcc99236F00843c7D8C4194abE8AA94a;

    // Contract addresses
    address public vaultAdmin = 0xC224bf25Dcc99236F00843c7D8C4194abE8AA94a;
    address public newOwner = 0xC224bf25Dcc99236F00843c7D8C4194abE8AA94a;

    VaultV2Factory public vaultFactory;
    VaultV2 public usdcVault;
    VaultV2 public ethVault;
    AlchemistV3 public usdcAlchemist;
    AlchemistV3 public ethAlchemist;
    Transmuter public usdcTransmuter;
    Transmuter public ethTransmuter;
    AlchemistCurator public curator;
    AlchemistStrategyClassifier public classifier;
    AlchemistAllocator public usdcAllocator;
    AlchemistAllocator public ethAllocator;

    // Strategy-specific addresses
    // TODO double-check!
    address public aavePoolProvider = 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb;
    address public velodromeRouter = 0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858;
    address public velodromeFactory = 0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a;
    address public usdt0OP = 0x01bFF41798a0BcF287b996046Ca68b395DbC1071;
    address public usdtOP = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;
    address public moonwellMUSDC = 0x8E08617b0d66359D73Aa11E11017834C29155525;
    address public moonwellMWETH = 0xb4104C02BBf4E9be85AAa41a62974E4e28D59A33;
    address public wstETHOP = 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb;
    address public velodromePool = 0xbF30Ff33CF9C6b0c48702Ff17891293b002DfeA4;

    address constant deployer = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; // FIXME

    // Strategy parameters
    IMYTStrategy.StrategyParams public aaveUSDCParams = IMYTStrategy.StrategyParams({
        owner: deployer,
        name: "AaveV3 OP USDC",
        protocol: "AaveV3",
        riskClass: IMYTStrategy.RiskClass.LOW,
        cap: 1000 * 1e6,
        globalCap: 0.5e18, // 50% relative cap
        estimatedYield: 500, // 5% annual yield
        additionalIncentives: false,
        slippageBPS: 50
    });

    IMYTStrategy.StrategyParams public velodromeUSDCParams = IMYTStrategy.StrategyParams({
        owner: deployer,
        name: "Velodrome OP USDC/USDT LP",
        protocol: "Velodrome",
        riskClass: IMYTStrategy.RiskClass.MEDIUM,
        cap: 0,
        globalCap: 0.3e18, // 30% relative cap
        estimatedYield: 800, // 8% annual yield
        additionalIncentives: false,
        slippageBPS: 50
    });

    IMYTStrategy.StrategyParams public moonwellUSDCParams = IMYTStrategy.StrategyParams({
        owner: deployer,
        name: "Moonwell OP USDC",
        protocol: "Moonwell",
        riskClass: IMYTStrategy.RiskClass.LOW,
        cap: 0,
        globalCap: 0.5e18, // 50% relative cap
        estimatedYield: 450, // 4.5% annual yield
        additionalIncentives: false,
        slippageBPS: 50
    });

    IMYTStrategy.StrategyParams public moonwellWETHParams = IMYTStrategy.StrategyParams({
        owner: deployer,
        name: "Moonwell OP WETH",
        protocol: "Moonwell",
        riskClass: IMYTStrategy.RiskClass.LOW,
        cap: 0,
        globalCap: 0.5e18, // 50% relative cap
        estimatedYield: 600, // 6% annual yield
        additionalIncentives: false,
        slippageBPS: 50
    });

    IMYTStrategy.StrategyParams public velodromeWETHParams = IMYTStrategy.StrategyParams({
        owner: deployer,
        name: "Velodrome OP wstETH/WETH LP",
        protocol: "Velodrome",
        riskClass: IMYTStrategy.RiskClass.MEDIUM,
        cap: 0,
        globalCap: 0.3e18, // 30% relative cap
        estimatedYield: 700, // 7% annual yield
        additionalIncentives: false,
        slippageBPS: 50
    });

    constructor() {
        self = address(this);
    }

    function setUp() public {
    }

    function deployAaveV3OPUSDCStrategy(address myt) internal returns (AaveV3OPUSDCStrategy) {
        // Create the strategy
        AaveV3OPUSDCStrategy aaveUSDCStrategy = new AaveV3OPUSDCStrategy(
            myt,
            aaveUSDCParams,
            USDC,
            aUSDC,
            aavePoolProvider
        );
    
        // Register strategy with curator
        curator.submitSetStrategy(address(aaveUSDCStrategy), address(myt));
        curator.setStrategy(address(aaveUSDCStrategy), address(myt));
        // Configure the cap through AlchemistCurator
        bytes memory idData = aaveUSDCStrategy.getIdData();
        curator.submitIncreaseAbsoluteCap(address(aaveUSDCStrategy), aaveUSDCParams.cap);
        curator.increaseAbsoluteCap(address(aaveUSDCStrategy), aaveUSDCParams.cap);
        curator.submitIncreaseRelativeCap(address(aaveUSDCStrategy), aaveUSDCParams.globalCap);
        curator.increaseRelativeCap(address(aaveUSDCStrategy), aaveUSDCParams.globalCap);

        aaveUSDCStrategy.setKillSwitch(true);
        aaveUSDCStrategy.transferOwnership(newOwner);
        require(aaveUSDCStrategy.owner() == newOwner);

        return aaveUSDCStrategy;
    }


    function deployMoonwellUSDCStrategy(address myt) internal returns (MoonwellUSDCStrategy) {
        // Create the strategy
        MoonwellUSDCStrategy moonwellUSDCStrategy = new MoonwellUSDCStrategy(
            myt,
            moonwellUSDCParams,
            moonwellMUSDC,
            USDC
        );
    
        // Register strategy with curator
        curator.submitSetStrategy(address(moonwellUSDCStrategy), address(myt));
        curator.setStrategy(address(moonwellUSDCStrategy), address(myt));
        
        // Configure the cap through AlchemistCurator
        bytes memory idData = moonwellUSDCStrategy.getIdData();
        curator.submitIncreaseAbsoluteCap(address(moonwellUSDCStrategy), moonwellUSDCParams.cap);
        curator.increaseAbsoluteCap(address(moonwellUSDCStrategy), moonwellUSDCParams.cap);
        curator.submitIncreaseRelativeCap(address(moonwellUSDCStrategy), moonwellUSDCParams.globalCap);
        curator.increaseRelativeCap(address(moonwellUSDCStrategy), moonwellUSDCParams.globalCap);

        moonwellUSDCStrategy.setKillSwitch(true);
        moonwellUSDCStrategy.transferOwnership(newOwner);
        require(moonwellUSDCStrategy.owner() == newOwner);

        return moonwellUSDCStrategy;
    }

    function deployMoonwellWETHStrategy(address myt) internal returns (MoonwellWETHStrategy) {
        // Create the strategy
        MoonwellWETHStrategy moonwellWETHStrategy = new MoonwellWETHStrategy(
            myt,
            moonwellWETHParams,
            moonwellMWETH,
            wethOP
        );
    
        // Register strategy with curator
        curator.submitSetStrategy(address(moonwellWETHStrategy), address(myt));
        curator.setStrategy(address(moonwellWETHStrategy), address(myt));
        
        // Configure the cap through AlchemistCurator
        bytes memory idData = moonwellWETHStrategy.getIdData();
        curator.submitIncreaseAbsoluteCap(address(moonwellWETHStrategy), moonwellWETHParams.cap);
        curator.increaseAbsoluteCap(address(moonwellWETHStrategy), moonwellWETHParams.cap);
        curator.submitIncreaseRelativeCap(address(moonwellWETHStrategy), moonwellWETHParams.globalCap);
        curator.increaseRelativeCap(address(moonwellWETHStrategy), moonwellWETHParams.globalCap);

        moonwellWETHStrategy.setKillSwitch(true);
        moonwellWETHStrategy.transferOwnership(newOwner);
        require(moonwellWETHStrategy.owner() == newOwner);

        return moonwellWETHStrategy;
    }

    function deployUSDCStrategies(address myt) public {
        // Deploy Optimism USDC Strategies
        AaveV3OPUSDCStrategy aaveUSDCStrategy = deployAaveV3OPUSDCStrategy(myt);
        MoonwellUSDCStrategy moonwellUSDCStrategy = deployMoonwellUSDCStrategy(myt);

        console.log("AaveV3 OP USDC Strategy deployed at:", address(aaveUSDCStrategy));
        //console.log("Velodrome OP USDC/USDT LP Strategy deployed at:", address(velodromeUSDCStrategy));
        console.log("Moonwell OP USDC Strategy deployed at:", address(moonwellUSDCStrategy));
    }

    function deployETHStrategies(address myt) public {
        // Deploy Optimism USDC Strategies
        MoonwellWETHStrategy moonwellWETHStrategy = deployMoonwellWETHStrategy(myt);
        console.log("Moonwell OP WETH Strategy deployed at:", address(moonwellWETHStrategy));
    }

    function deployAlAsset(string memory name, string memory ticker) public returns (address) {
        CrossChainCanonicalAlchemicTokenV3 alAssetImpl = new CrossChainCanonicalAlchemicTokenV3();
        bytes memory alAssetParams = abi.encodeWithSelector(CrossChainCanonicalAlchemicTokenV3.initialize.selector, name, ticker);
        CrossChainCanonicalAlchemicTokenV3 alAssetProxy = CrossChainCanonicalAlchemicTokenV3(address(new TransparentUpgradeableProxy(
            address(alAssetImpl),
            newOwner,
            alAssetParams
        )));
        alAssetProxy.setWhitelist(deployer, true);
        alAssetProxy.setWhitelist(newOwner, true);
        alAssetProxy.mint(newOwner, 1e9 * 1e18);
        alAssetProxy.transferOwnership(newOwner);
        return address(alAssetProxy);
    }

    function deployTransmuter(address alAsset) public returns (Transmuter) {
        // Deploy Transmuter
        ITransmuter.TransmuterInitializationParams memory transmuterParams = ITransmuter.TransmuterInitializationParams({
            syntheticToken: alAsset,
            feeReceiver: protocolFeeReceiver,
            timeToTransmute: 365 * 2 days,
            transmutationFee: 100, // 1%
            exitFee: 50, // 0.5%
            graphSize: 365 days
        });

        Transmuter deployedTransmuter = new Transmuter(transmuterParams);
        deployedTransmuter.setDepositCap(0);
        deployedTransmuter.setExitFee(50); // 0.5%
        return deployedTransmuter;
    }

    function deployAlchemist(address alAsset, address underlying, address vault, address transmuter, uint256 cap) public returns (AlchemistV3) {
        // Deploy Alchemist logic contract
        AlchemistV3 alchemistLogic = new AlchemistV3();

        AlchemistInitializationParams memory params = AlchemistInitializationParams({
            admin: deployer,
            debtToken: alAsset,
            underlyingToken: underlying,
            depositCap: 0,
            minimumCollateralization: 1_111_111_111_111_111_111, // 1.1x collateralization
            collateralizationLowerBound: 1_052_631_578_950_000_000, // 1.05 collateralization
            globalMinimumCollateralization: 1_111_111_111_111_111_111, // 1.1
            liquidationTargetCollateralization: liquidationTargetCollateralization,
            transmuter: transmuter,
            protocolFee: 50, // 10000 bps -> 0.5%
            protocolFeeReceiver: protocolFeeReceiver,
            liquidatorFee: 300, // 3% = 300 BPS
            repaymentFee: 100, // 1% = 100 BPS
            myt: vault
        });

        // Deploy proxy with initialization
        bytes memory alchemParams = abi.encodeWithSelector(AlchemistV3.initialize.selector, params);
        return AlchemistV3(address(new TransparentUpgradeableProxy(
            address(alchemistLogic),
            newOwner,
            alchemParams
        )));
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddr = vm.addr(deployerPrivateKey);
        vm.startBroadcast(deployerPrivateKey);
        // ====== MOCK ONLY ======
        // Deploy alAssets
        alUSD = deployAlAsset("thatsmy", "kungfu");
        alETH = deployAlAsset("ethkungfu", "ekungfu");
        // ========= END MOCK ==============
        // Deploy Morpho Vault
        vaultFactory = new VaultV2Factory();
        usdcVault = VaultV2(vaultFactory.createVaultV2(deployerAddr, USDC, bytes32(0)));
        ethVault = VaultV2(vaultFactory.createVaultV2(deployerAddr, wethOP, bytes32(0)));

        // Deploy AlchemistCurator
        curator = new AlchemistCurator(deployerAddr, deployerAddr);

        // Deploy AlchemistStrategyClassifier
        classifier = new AlchemistStrategyClassifier(newOwner);

        // Set vault curator immediately so submit calls work
        usdcVault.setCurator(address(curator));
        ethVault.setCurator(address(curator));

        // Deploy AlchemistAllocator
        usdcAllocator = new AlchemistAllocator(address(usdcVault), deployerAddr, vaultAdmin, address(classifier));
        ethAllocator = new AlchemistAllocator(address(ethVault), deployerAddr, vaultAdmin, address(classifier));

        usdcTransmuter = deployTransmuter(alUSD);
        ethTransmuter = deployTransmuter(alETH);

        usdcAlchemist = deployAlchemist(alUSD, USDC, address(usdcVault), address(usdcTransmuter), 0);
        ethAlchemist = deployAlchemist(alETH, wethOP, address(ethVault), address(ethTransmuter), 0); // 0.3ETH ~ $1000


        AlchemistTokenVault ethFeeVault = new AlchemistTokenVault(address(ethVault.asset()), address(ethAlchemist), deployerAddr);
        AlchemistTokenVault usdcFeeVault = new AlchemistTokenVault(address(usdcVault.asset()), address(usdcAlchemist), deployerAddr);
        ethFeeVault.setAuthorization(address(ethAlchemist), true);
        usdcFeeVault.setAuthorization(address(usdcAlchemist), true);
        ethAlchemist.setAlchemistFeeVault(address(ethFeeVault));
        usdcAlchemist.setAlchemistFeeVault(address(usdcFeeVault));

        usdcTransmuter.setAlchemist(address(usdcAlchemist));
        ethTransmuter.setAlchemist(address(ethAlchemist));

        AlchemistV3Position ethNft = new AlchemistV3Position(address(ethAlchemist), newOwner);
        AlchemistV3Position usdcNft = new AlchemistV3Position(address(usdcAlchemist), newOwner);
        ethAlchemist.setAlchemistPositionNFT(address(ethNft));
        usdcAlchemist.setAlchemistPositionNFT(address(usdcNft));

        // Whitelist alchemist proxy for minting tokens
        AlAsset(alUSD).setWhitelist(address(usdcAlchemist), true);
        AlAsset(alETH).setWhitelist(address(ethAlchemist), true);

        // Deploy and link strategies (now that curator is set)
        deployUSDCStrategies(address(usdcVault));
        deployETHStrategies(address(ethVault));

        // Set allocator on vault
       // curator.submitSetAllocator(address(usdcVault), address(usdcAllocator), true);
        usdcVault.setOwner(newOwner);

        //curator.submitSetAllocator(address(ethVault), address(ethAllocator), true);
        ethVault.setOwner(newOwner);

        // Transfer curator ownership after all strategy operations are complete
        curator.transferAdminOwnerShip(newOwner);

        usdcAllocator.transferAdminOwnerShip(newOwner);
        ethAllocator.transferAdminOwnerShip(newOwner);

        usdcTransmuter.setPendingAdmin(newOwner);
        ethTransmuter.setPendingAdmin(newOwner);

        ethAlchemist.setPendingAdmin(newOwner);
        usdcAlchemist.setPendingAdmin(newOwner);

        vm.stopBroadcast();
        // Output deployment addresses
        console.log("mock alUSD deployed at", address(alUSD));
        console.log("mock alETH deployed at", address(alETH));

        console.log("VaultFactory deployed at:", address(vaultFactory));
        console.log("alUSD Transmuter deployed at:", address(usdcTransmuter));
        console.log("alUSD Alchemist deployed at:", address(usdcAlchemist));
        console.log("USDC MYT Vault deployed at:", address(usdcVault));

        console.log("alETH Transmuter deployed at:", address(ethTransmuter));
        console.log("alETH Alchemist deployed at:", address(ethAlchemist));
        console.log("WETH MYT Vault deployed at:", address(ethVault));

        console.log("alETH position nft deployed at:", address(ethNft));
        console.log("alUSD position nft deployed at:", address(usdcNft));
        console.log("alETH fee vault deployed at:", address(ethFeeVault));
        console.log("alUSD fee vault deployed at:", address(usdcFeeVault));

        require(usdcAlchemist.pendingAdmin() == newOwner);
        require(usdcTransmuter.pendingAdmin() == newOwner);
        require(ethAlchemist.pendingAdmin() == newOwner);
        require(ethTransmuter.pendingAdmin() == newOwner);
        require(curator.pendingAdmin() == newOwner);
        require(usdcAllocator.pendingAdmin() == newOwner);
        require(ethAllocator.pendingAdmin() == newOwner);
    }
}
