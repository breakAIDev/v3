// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {AlchemistV3} from "../src/AlchemistV3.sol";
import {Transmuter} from "../src/Transmuter.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {AlchemistInitializationParams} from "..//src/interfaces/IAlchemistV3.sol";
import {ITransmuter} from "../src/interfaces/ITransmuter.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AlchemistCurator} from "../src/AlchemistCurator.sol";
import {AlchemistAllocator} from "../src/AlchemistAllocator.sol";
import {AlchemistStrategyClassifier} from "../src/AlchemistStrategyClassifier.sol";
import {TransparentUpgradeableProxy} from "../lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {VaultV2Factory} from "../lib/vault-v2/src/VaultV2Factory.sol";
import {VaultV2, IVaultV2} from "../lib/vault-v2/src/VaultV2.sol";

import {AaveStrategy} from "../src/strategies/AaveStrategy.sol";
import {MoonwellStrategy} from "../src/strategies/MoonwellStrategy.sol";

// AlAsset
//import {CrossChainCanonicalAlchemicTokenV2} from "../lib/v2-foundry/src/CrossChainCanonicalAlchemicTokenV2.sol";
import {CrossChainCanonicalAlchemicTokenV3} from "../src/AlTokenV3.sol";

interface AlAsset {
    function setWhitelist(address a, bool v) external;
}

contract DeployV3OptimismScript is Script {
    address self = address(this);
    address deployerAddr = 0x1c9387747baA55C26197732Bda132955E1F56b80;
    // Asset addresses
    address public aUSDC = 0x38d693cE1dF5AaDF7bC62595A37D667aD57922e5;
    address public wethOP = 0x4200000000000000000000000000000000000006;
    address public alUSD = 0xb2c22A9fb4FC02eb9D1d337655Ce079a04a526C7;
    address public alETH = 0x3E29D3A9316dAB217754d13b28646B76607c5f04;
    address public USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

    // Price feed addresses
    address public ETH_USD_PRICE_FEED_MAINNET = 0x13e3Ee699D1909E989722E753853AE30b17e08c5;
    uint256 public ETH_USD_UPDATE_TIME_MAINNET = 3600 seconds;

    address public receiver = 0xC224bf25Dcc99236F00843c7D8C4194abE8AA94a;
    address public protocolFeeReceiver = 0xC224bf25Dcc99236F00843c7D8C4194abE8AA94a;

    // Contract addresses
    //address public vaultAdmin = 0xC224bf25Dcc99236F00843c7D8C4194abE8AA94a;
    //address public newOwner = 0xC224bf25Dcc99236F00843c7D8C4194abE8AA94a;
    address public vaultAdmin = deployerAddr; // FIXME
    address public newOwner = deployerAddr; // FIXME
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
    // Aave V3
    address public aavePoolProvider = 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb; // FIXME: verify PoolAddressProvider on Optimism
    address public aaveRewardsController_OP = 0x929EC64c34a17401F460460D4B9390518E5B473e; // Aave RewardsController on Optimism
    address public aaveRewardToken_OP = 0x4200000000000000000000000000000000000042; // OP token on Optimism

    // Moonwell
    address public moonwellMUSDC = 0x8E08617b0d66359D73Aa11E11017834C29155525;
    address public moonwellMWETH = 0xb4104C02BBf4E9be85AAa41a62974E4e28D59A33;
    address public moonwellComptroller = 0xCa889f40aae37FFf165BccF69aeF1E82b5C511B9; // Moonwell Comptroller on Optimism
    address public moonwellRewardToken = 0xA88594D404727625A9437C3f886C7643872296AE; // WELL token on Optimism

    // Strategy parameters
    IMYTStrategy.StrategyParams public aaveUSDCParams = IMYTStrategy.StrategyParams({
        owner: newOwner,
        name: "AaveV3 OP USDC",
        protocol: "AaveV3",
        riskClass: IMYTStrategy.RiskClass.LOW,
        cap: 1000000 * 1e18,
        globalCap: 0.5e18, // 50% relative cap
        estimatedYield: 500, // 5% annual yield
        additionalIncentives: false,
        slippageBPS: 50
    });

    IMYTStrategy.StrategyParams public moonwellUSDCParams = IMYTStrategy.StrategyParams({
        owner: newOwner,
        name: "Moonwell OP USDC",
        protocol: "Moonwell",
        riskClass: IMYTStrategy.RiskClass.LOW,
        cap: 1000000 * 1e18,
        globalCap: 0.5e18, // 50% relative cap
        estimatedYield: 450, // 4.5% annual yield
        additionalIncentives: false,
        slippageBPS: 50
    });

    IMYTStrategy.StrategyParams public moonwellWETHParams = IMYTStrategy.StrategyParams({
        owner: newOwner,
        name: "Moonwell OP WETH",
        protocol: "Moonwell",
        riskClass: IMYTStrategy.RiskClass.LOW,
        cap: 1000000 * 1e18,
        globalCap: 0.5e18, // 50% relative cap
        estimatedYield: 600, // 6% annual yield
        additionalIncentives: false,
        slippageBPS: 50
    });

    function setUp() public {}

    function deployAaveV3OPUSDCStrategy(address myt) internal returns (AaveStrategy) {
        AaveStrategy aaveUSDCStrategy = new AaveStrategy(
            myt,
            aaveUSDCParams,
            USDC,
            aUSDC,
            aavePoolProvider,
            aaveRewardsController_OP,
            aaveRewardToken_OP
        );
    
        curator.submitSetStrategy(address(aaveUSDCStrategy), address(myt));
        curator.setStrategy(address(aaveUSDCStrategy), address(myt));
        bytes memory idData = aaveUSDCStrategy.getIdData();
        curator.submitIncreaseAbsoluteCap(address(aaveUSDCStrategy), aaveUSDCParams.cap);
        curator.increaseAbsoluteCap(address(aaveUSDCStrategy), aaveUSDCParams.cap);
        curator.submitIncreaseRelativeCap(address(aaveUSDCStrategy), aaveUSDCParams.globalCap);
        curator.increaseRelativeCap(address(aaveUSDCStrategy), aaveUSDCParams.globalCap);

        return aaveUSDCStrategy;
    }

    function deployMoonwellUSDCStrategy(address myt) internal returns (MoonwellStrategy) {
        MoonwellStrategy moonwellUSDCStrategy = new MoonwellStrategy(
            myt,
            moonwellUSDCParams,
            USDC,
            moonwellMUSDC,
            moonwellComptroller,
            moonwellRewardToken,
            false
        );
    
        curator.submitSetStrategy(address(moonwellUSDCStrategy), address(myt));
        curator.setStrategy(address(moonwellUSDCStrategy), address(myt));
        
        bytes memory idData = moonwellUSDCStrategy.getIdData();
        curator.submitIncreaseAbsoluteCap(address(moonwellUSDCStrategy), moonwellUSDCParams.cap);
        curator.increaseAbsoluteCap(address(moonwellUSDCStrategy), moonwellUSDCParams.cap);
        curator.submitIncreaseRelativeCap(address(moonwellUSDCStrategy), moonwellUSDCParams.globalCap);
        curator.increaseRelativeCap(address(moonwellUSDCStrategy), moonwellUSDCParams.globalCap);

        return moonwellUSDCStrategy;
    }

    function deployMoonwellWETHStrategy(address myt) internal returns (MoonwellStrategy) {
        MoonwellStrategy moonwellWETHStrategy = new MoonwellStrategy(
            myt,
            moonwellWETHParams,
            wethOP,
            moonwellMWETH,
            moonwellComptroller,
            moonwellRewardToken,
            true
        );
    
        curator.submitSetStrategy(address(moonwellWETHStrategy), address(myt));
        curator.setStrategy(address(moonwellWETHStrategy), address(myt));
        
        bytes memory idData = moonwellWETHStrategy.getIdData();
        curator.submitIncreaseAbsoluteCap(address(moonwellWETHStrategy), moonwellWETHParams.cap);
        curator.increaseAbsoluteCap(address(moonwellWETHStrategy), moonwellWETHParams.cap);
        curator.submitIncreaseRelativeCap(address(moonwellWETHStrategy), moonwellWETHParams.globalCap);
        curator.increaseRelativeCap(address(moonwellWETHStrategy), moonwellWETHParams.globalCap);

        return moonwellWETHStrategy;
    }

    function deployUSDCStrategies(address myt) public {
        AaveStrategy aaveUSDCStrategy = deployAaveV3OPUSDCStrategy(myt);
        MoonwellStrategy moonwellUSDCStrategy = deployMoonwellUSDCStrategy(myt);

        console.log("AaveV3 OP USDC Strategy deployed at:", address(aaveUSDCStrategy));
        console.log("Moonwell OP USDC Strategy deployed at:", address(moonwellUSDCStrategy));
    }

    function deployETHStrategies(address myt) public {
        MoonwellStrategy moonwellWETHStrategy = deployMoonwellWETHStrategy(myt);

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
        alAssetProxy.transferOwnership(newOwner);
        alAssetProxy.setWhitelist(self, true);
        alAssetProxy.setWhitelist(newOwner, true);
        alAssetProxy.mint(newOwner, 1e9 * 1e18);
        return address(alAssetProxy);
    }

    function deployTransmuter(address alAsset) public returns (Transmuter) {
        ITransmuter.TransmuterInitializationParams memory transmuterParams = ITransmuter.TransmuterInitializationParams({
            syntheticToken: alAsset,
            feeReceiver: protocolFeeReceiver,
            timeToTransmute: 3 days, // TODO
            transmutationFee: 0,
            exitFee: 100,
            graphSize: 365 days
        });

        Transmuter deployedTransmuter = new Transmuter(transmuterParams);
        deployedTransmuter.setDepositCap(500); // FIXME migratedDebt * 0.25

        require(deployedTransmuter.transmutationFee() == 0);
        require(deployedTransmuter.exitFee() == 100);
        return deployedTransmuter;
    }

    function deployAlchemist(address alAsset, address underlying, address vault, address transmuter, uint256 cap) public returns (AlchemistV3) {
        AlchemistV3 alchemistLogic = new AlchemistV3();

        AlchemistInitializationParams memory params = AlchemistInitializationParams({
            admin: newOwner,
            debtToken: alAsset,
            underlyingToken: underlying,
            depositCap: cap, // FIXME migratedDeposits*1.5
            minimumCollateralization: 1_111_111_111_111_111_111, // 1.1x collateralization
            collateralizationLowerBound: 1_052_631_578_950_000_000, // 1.05 collateralization
            liquidationTargetCollateralization: 1_111_111_111_111_111_111, // 1.1
            globalMinimumCollateralization: 1_052_631_578_950_000_000, // 20/19
            transmuter: transmuter,
            protocolFee: 25, // 10000 bps -> 0.25%
            protocolFeeReceiver: protocolFeeReceiver,
            liquidatorFee: 300, // 3% = 300 BPS
            repaymentFee: 0,
            myt: vault
        });

        bytes memory alchemParams = abi.encodeWithSelector(AlchemistV3.initialize.selector, params);
        AlchemistV3 deployedAlchemist = AlchemistV3(address(new TransparentUpgradeableProxy(
            address(alchemistLogic),
            newOwner,
            alchemParams
        )));

        require(deployedAlchemist.protocolFee() == 25);
        require(deployedAlchemist.liquidatorFee() == 300);
        require(deployedAlchemist.repaymentFee() == 0);
        return deployedAlchemist;
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployerAddr = vm.addr(deployerPrivateKey);
        require(deployerAddr == 0x1c9387747baA55C26197732Bda132955E1F56b80, "deployer");
        vm.startBroadcast(deployerPrivateKey);
        // ====== MOCK ONLY ======
        // Deploy alAssets
        //alUSD = deployAlAsset("thatsmy", "kungfu");
        //alETH = deployAlAsset("ethkungfu", "ekungfu");
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

        usdcAlchemist = deployAlchemist(alUSD, USDC, address(usdcVault), address(usdcTransmuter), 1000 * 1e6); // FIXME
        ethAlchemist = deployAlchemist(alETH, wethOP, address(ethVault), address(ethTransmuter), 3 * 1e17); // 0.3ETH ~ $1000

        // Whitelist alchemist proxy for minting tokens
        // TODO we dont have admin access
        // AlAsset(alUSD).setWhitelist(address(alchemist), true);

        // Deploy and link strategies (now that curator is set)
        deployUSDCStrategies(address(usdcVault));
        deployETHStrategies(address(ethVault));

        // Set allocator on vault
        curator.submitSetAllocator(address(usdcVault), address(usdcAllocator), true);
        //usdcVault.setIsAllocator(address(usdcAllocator), true);
        usdcVault.setOwner(newOwner);

        curator.submitSetAllocator(address(ethVault), address(ethAllocator), true);
        //ethVault.setIsAllocator(address(ethVault), true);
        ethVault.setOwner(newOwner);

        // Transfer curator ownership after all strategy operations are complete
        curator.transferAdminOwnerShip(newOwner);

        usdcAllocator.transferAdminOwnerShip(newOwner);
        ethAllocator.transferAdminOwnerShip(newOwner);

        usdcTransmuter.setPendingAdmin(newOwner);
        ethTransmuter.setPendingAdmin(newOwner);
        
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

        console.log("Curator deployed at:", address(curator));
        console.log("USDC Allocator deployed at:", address(usdcAllocator));
        console.log("ETH Allocator deployed at:", address(ethAllocator));

        console.log("----------- IMPORTANT -----------");
        console.log("- Run $vault.setIsAllocator(allocator,true) on each MYT vault now!");
        console.log("- Add the new alchemists to the alAsset whitelist!");
        
        require(usdcAlchemist.admin() == newOwner);
        require(usdcTransmuter.pendingAdmin() == newOwner);
        require(ethAlchemist.admin() == newOwner);
        require(ethTransmuter.pendingAdmin() == newOwner);
        require(curator.pendingAdmin() == newOwner);
        require(usdcAllocator.pendingAdmin() == newOwner);
        require(ethAllocator.pendingAdmin() == newOwner);
    }
}
