// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {AlchemistV3} from "../src/AlchemistV3.sol";
import {Transmuter} from "../src/Transmuter.sol";
import {IMYTStrategy} from "../src/interfaces/IMYTStrategy.sol";
import {AlchemistInitializationParams} from "../src/interfaces/IAlchemistV3.sol";
import {ITransmuter} from "../src/interfaces/ITransmuter.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AlchemistCurator} from "../src/AlchemistCurator.sol";
import {AlchemistAllocator} from "../src/AlchemistAllocator.sol";
import {AlchemistStrategyClassifier} from "../src/AlchemistStrategyClassifier.sol";
import {TransparentUpgradeableProxy} from "../lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {VaultV2Factory} from "../lib/vault-v2/src/VaultV2Factory.sol";
import {VaultV2, IVaultV2} from "../lib/vault-v2/src/VaultV2.sol";

import {ERC4626Strategy} from "../src/strategies/ERC4626Strategy.sol";
import {TokeAutoStrategy} from "../src/strategies/TokeAutoStrategy.sol";

// AlAsset
import {CrossChainCanonicalAlchemicTokenV3} from "../src/AlTokenV3.sol";

contract DeployV3ETHScript is Script {
    address self = address(this);
    address deployerAddr = 0x1c9387747baA55C26197732Bda132955E1F56b80;
            
    address public wethETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public alUSD = 0xBC6DA0FE9aD5f3b0d58160288917AA56653660E9;
    address public alETH = 0x0100546F2cD4C9D97f798fFC9755E47865FF7Ee6;
    address public USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address public ETH_USD_PRICE_FEED_MAINNET = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    uint256 public ETH_USD_UPDATE_TIME_MAINNET = 3600 seconds;

    // Fee and receiver addresses
    address public receiver = 0x9e2b6378ee8ad2A4A95Fe481d63CAba8FB0EBBF9;
    address public protocolFeeReceiver = 0x9e2b6378ee8ad2A4A95Fe481d63CAba8FB0EBBF9;

    // Contract addresses
    // address public vaultAdmin = 0x9e2b6378ee8ad2A4A95Fe481d63CAba8FB0EBBF9; FIXME
    // address public newOwner = 0x9e2b6378ee8ad2A4A95Fe481d63CAba8FB0EBBF9; FIXME
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
    address public eulerVaultUSDC = 0xe0a80d35bB6618CBA260120b279d357978c42BCE;
    address public eulerVaultWETH = 0xD8b27CF359b7D15710a5BE299AF6e7Bf904984C2;
    address public peapodsEthVault = 0x9a42e1bEA03154c758BeC4866ec5AD214D4F2191;
    address public peapodsUsdcVault = 0x3717e340140D30F3A077Dd21fAc39A86ACe873AA;
    address public tokeAutoEth = 0x0A2b94F6871c1D7A32Fe58E1ab5e6deA2f114E56;
    address public tokeAutoRewarder = 0x60882D6f70857606Cdd37729ccCe882015d1755E;
    address public tokeRewardsToken = 0x2e9d63788249371f1DFC918a52f8d799F4a38C94; // TOKE token on Mainnet
    address public tokeAutoUsd = 0xa7569A44f348d3D70d8ad5889e50F78E33d80D35;
    address public tokeAutoUsdRewarder = 0x726104CfBd7ece2d1f5b3654a19109A9e2b6c27B;

    // Strategy parameters
    IMYTStrategy.StrategyParams public eulerUSDCParams = IMYTStrategy.StrategyParams({
        owner: newOwner,
        name: "Euler Mainnet USDC",
        protocol: "Euler",
        riskClass: IMYTStrategy.RiskClass.LOW,
        cap: 1000000 * 1e18,
        globalCap: 0.5e18, // 50% relative cap
        estimatedYield: 500, // 5% annual yield
        additionalIncentives: false,
        slippageBPS: 50
    });

    IMYTStrategy.StrategyParams public eulerWETHParams = IMYTStrategy.StrategyParams({
        owner: newOwner,
        name: "Euler Mainnet WETH",
        protocol: "Euler",
        riskClass: IMYTStrategy.RiskClass.LOW,
        cap: 0.7 * 1e18,
        globalCap: 0.3e18, // 30% relative cap
        estimatedYield: 600, // 6% annual yield
        additionalIncentives: false,
        slippageBPS: 50
    });

    IMYTStrategy.StrategyParams public peapodsETHParams = IMYTStrategy.StrategyParams({
        owner: newOwner,
        name: "Peapods Mainnet ETH",
        protocol: "Peapods",
        riskClass: IMYTStrategy.RiskClass.HIGH,
        cap: 0.7 * 1e18,
        globalCap: 0.2e18, // 20% relative cap
        estimatedYield: 700, // 7% annual yield
        additionalIncentives: false,
        slippageBPS: 50
    });

    IMYTStrategy.StrategyParams public peapodsUSDCParams = IMYTStrategy.StrategyParams({
        owner: newOwner,
        name: "Peapods Mainnet USDC",
        protocol: "Peapods",
        riskClass: IMYTStrategy.RiskClass.HIGH,
        cap: 0.7 * 1e18,
        globalCap: 0.2e18, // 20% relative cap
        estimatedYield: 550, // 5.5% annual yield
        additionalIncentives: false,
        slippageBPS: 50
    });

    IMYTStrategy.StrategyParams public tokeAutoEthParams = IMYTStrategy.StrategyParams({
        owner: newOwner,
        name: "TokeAutoEth Mainnet",
        protocol: "TokeAuto",
        riskClass: IMYTStrategy.RiskClass.MEDIUM,
        cap: 0.7 * 1e18,
        globalCap: 0.3e18, // 30% relative cap
        estimatedYield: 800, // 8% annual yield
        additionalIncentives: false,
        slippageBPS: 50
    });

    IMYTStrategy.StrategyParams public tokeAutoUSDParams = IMYTStrategy.StrategyParams({
        owner: newOwner,
        name: "TokeAutoUSD Mainnet",
        protocol: "TokeAuto",
        riskClass: IMYTStrategy.RiskClass.MEDIUM,
        cap: 1000000 * 1e18,
        globalCap: 0.3e18, // 30% relative cap
        estimatedYield: 750, // 7.5% annual yield
        additionalIncentives: false,
        slippageBPS: 50
    });

    function setUp() public {}

    function deployEulerUSDCStrategy(address myt) internal returns (ERC4626Strategy) {
        ERC4626Strategy strategy = new ERC4626Strategy(
            myt,
            eulerUSDCParams,
            eulerVaultUSDC
        );
        
        curator.submitSetStrategy(address(strategy), address(myt));
        curator.setStrategy(address(strategy), address(myt));
        bytes memory idData = strategy.getIdData();
        curator.submitIncreaseAbsoluteCap(address(strategy), eulerUSDCParams.cap);
        curator.increaseAbsoluteCap(address(strategy), eulerUSDCParams.cap);
        curator.submitIncreaseRelativeCap(address(strategy), eulerUSDCParams.globalCap);
        curator.increaseRelativeCap(address(strategy), eulerUSDCParams.globalCap);

        return strategy;
    }

    function deployEulerWETHStrategy(address myt) internal returns (ERC4626Strategy) {
        ERC4626Strategy strategy = new ERC4626Strategy(
            myt,
            eulerWETHParams,
            eulerVaultWETH
        );
        
        curator.submitSetStrategy(address(strategy), address(myt));
        curator.setStrategy(address(strategy), address(myt));
        bytes memory idData = strategy.getIdData();
        curator.submitIncreaseAbsoluteCap(address(strategy), eulerWETHParams.cap);
        curator.increaseAbsoluteCap(address(strategy), eulerWETHParams.cap);
        curator.submitIncreaseRelativeCap(address(strategy), eulerWETHParams.globalCap);
        curator.increaseRelativeCap(address(strategy), eulerWETHParams.globalCap);

        return strategy;
    }

    function deployPeapodsETHStrategy(address myt) internal returns (ERC4626Strategy) {
        ERC4626Strategy strategy = new ERC4626Strategy(
            myt,
            peapodsETHParams,
            peapodsEthVault
        );
        
        curator.submitSetStrategy(address(strategy), address(myt));
        curator.setStrategy(address(strategy), address(myt));
        bytes memory idData = strategy.getIdData();
        curator.submitIncreaseAbsoluteCap(address(strategy), peapodsETHParams.cap);
        curator.increaseAbsoluteCap(address(strategy), peapodsETHParams.cap);
        curator.submitIncreaseRelativeCap(address(strategy), peapodsETHParams.globalCap);
        curator.increaseRelativeCap(address(strategy), peapodsETHParams.globalCap);

        return strategy;
    }

    function deployPeapodsUSDCStrategy(address myt) internal returns (ERC4626Strategy) {
        ERC4626Strategy strategy = new ERC4626Strategy(
            myt,
            peapodsUSDCParams,
            peapodsUsdcVault
        );
        
        curator.submitSetStrategy(address(strategy), address(myt));
        curator.setStrategy(address(strategy), address(myt));
        bytes memory idData = strategy.getIdData();
        curator.submitIncreaseAbsoluteCap(address(strategy), peapodsUSDCParams.cap);
        curator.increaseAbsoluteCap(address(strategy), peapodsUSDCParams.cap);
        curator.submitIncreaseRelativeCap(address(strategy), peapodsUSDCParams.globalCap);
        curator.increaseRelativeCap(address(strategy), peapodsUSDCParams.globalCap);

        return strategy;
    }

    function deployTokeAutoEthStrategy(address myt) internal returns (TokeAutoStrategy) {
        TokeAutoStrategy strategy = new TokeAutoStrategy(
            myt,
            tokeAutoEthParams,
            wethETH,
            tokeAutoEth,
            tokeAutoRewarder,
            tokeRewardsToken
        );
        
        curator.submitSetStrategy(address(strategy), address(myt));
        curator.setStrategy(address(strategy), address(myt));
        bytes memory idData = strategy.getIdData();
        curator.submitIncreaseAbsoluteCap(address(strategy), tokeAutoEthParams.cap);
        curator.increaseAbsoluteCap(address(strategy), tokeAutoEthParams.cap);
        curator.submitIncreaseRelativeCap(address(strategy), tokeAutoEthParams.globalCap);
        curator.increaseRelativeCap(address(strategy), tokeAutoEthParams.globalCap);

        return strategy;
    }

    function deployTokeAutoUSDStrategy(address myt) internal returns (TokeAutoStrategy) {
        TokeAutoStrategy strategy = new TokeAutoStrategy(
            myt,
            tokeAutoUSDParams,
            USDC,
            tokeAutoUsd,
            tokeAutoUsdRewarder,
            tokeRewardsToken
        );
        
        curator.submitSetStrategy(address(strategy), address(myt));
        curator.setStrategy(address(strategy), address(myt));
        bytes memory idData = strategy.getIdData();
        curator.submitIncreaseAbsoluteCap(address(strategy), tokeAutoUSDParams.cap);
        curator.increaseAbsoluteCap(address(strategy), tokeAutoUSDParams.cap);
        curator.submitIncreaseRelativeCap(address(strategy), tokeAutoUSDParams.globalCap);
        curator.increaseRelativeCap(address(strategy), tokeAutoUSDParams.globalCap);

        return strategy;
    }

    function deployUSDCStrategies(address myt) public {
        ERC4626Strategy eulerUSDCStrategy = deployEulerUSDCStrategy(myt);
        ERC4626Strategy peapodsUSDCStrategy = deployPeapodsUSDCStrategy(myt);
        TokeAutoStrategy tokeAutoUSDStrategy = deployTokeAutoUSDStrategy(myt);

        console.log("Euler Mainnet USDC Strategy deployed at:", address(eulerUSDCStrategy));
        console.log("Peapods Mainnet USDC Strategy deployed at:", address(peapodsUSDCStrategy));
        console.log("TokeAutoUSD Mainnet Strategy deployed at:", address(tokeAutoUSDStrategy));
    }

    function deployETHStrategies(address myt) public {
        ERC4626Strategy eulerWETHStrategy = deployEulerWETHStrategy(myt);
        ERC4626Strategy peapodsETHStrategy = deployPeapodsETHStrategy(myt);
        TokeAutoStrategy tokeAutoEthStrategy = deployTokeAutoEthStrategy(myt);

        console.log("Euler Mainnet WETH Strategy deployed at:", address(eulerWETHStrategy));
        console.log("Peapods Mainnet ETH Strategy deployed at:", address(peapodsETHStrategy));
        console.log("TokeAutoEth Mainnet Strategy deployed at:", address(tokeAutoEthStrategy));
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
            timeToTransmute: 12 weeks,
            transmutationFee: 0,
            exitFee: 50, // 0.5%
            graphSize: 365 days
        });

        Transmuter deployedTransmuter = new Transmuter(transmuterParams);
        deployedTransmuter.setDepositCap(500); // FIXME migratedDebt * 0.25
        deployedTransmuter.setExitFee(50); // 0.5%
        return deployedTransmuter;
    }

    function deployAlchemist(address alAsset, address underlying, address vault, address transmuter, uint256 cap) public returns (AlchemistV3) {
        AlchemistV3 alchemistLogic = new AlchemistV3();

        AlchemistInitializationParams memory params = AlchemistInitializationParams({
            admin: newOwner,
            debtToken: alAsset,
            underlyingToken: underlying,
            depositCap: cap, // FIXME migratedDeposits*1.5
            minimumCollateralization: 1_111_111_111_111_111_111,
            collateralizationLowerBound: 1_052_631_578_950_000_000,
            liquidationTargetCollateralization: 1_111_111_111_111_111_111,
            globalMinimumCollateralization: 1_111_111_111_111_111_111,
            transmuter: transmuter,
            protocolFee: 50, // 10000 bps -> 0.5%
            protocolFeeReceiver: protocolFeeReceiver,
            liquidatorFee: 300,
            repaymentFee: 100,
            myt: vault
        });

        bytes memory alchemParams = abi.encodeWithSelector(AlchemistV3.initialize.selector, params);
        return AlchemistV3(address(new TransparentUpgradeableProxy(
            address(alchemistLogic),
            newOwner,
            alchemParams
        )));
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployerAddr = vm.addr(deployerPrivateKey);
        require(deployerAddr == 0x1c9387747baA55C26197732Bda132955E1F56b80, "deployer");
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy alAssets
        //alUSD = deployAlAsset("Alchemic USD", "alUSD");
        //alETH = deployAlAsset("Alchemic ETH", "alETH");

        // Deploy Vault Factory and Vaults
        vaultFactory = new VaultV2Factory();
        usdcVault = VaultV2(vaultFactory.createVaultV2(deployerAddr, USDC, bytes32(0)));
        ethVault = VaultV2(vaultFactory.createVaultV2(deployerAddr, wethETH, bytes32(0)));

        // Deploy AlchemistCurator
        curator = new AlchemistCurator(deployerAddr, deployerAddr);

        // Deploy AlchemistStrategyClassifier
        classifier = new AlchemistStrategyClassifier(newOwner);

        // Set vault curator immediately
        usdcVault.setCurator(address(curator));
        ethVault.setCurator(address(curator));

        // Deploy AlchemistAllocator
        usdcAllocator = new AlchemistAllocator(address(usdcVault), deployerAddr, vaultAdmin, address(classifier));
        ethAllocator = new AlchemistAllocator(address(ethVault), deployerAddr, vaultAdmin, address(classifier));

        // Deploy Transmuters
        usdcTransmuter = deployTransmuter(alUSD);
        ethTransmuter = deployTransmuter(alETH);

        // Deploy Alchemists
        usdcAlchemist = deployAlchemist(alUSD, USDC, address(usdcVault), address(usdcTransmuter), 1000 * 1e6); // FIXME
        ethAlchemist = deployAlchemist(alETH, wethETH, address(ethVault), address(ethTransmuter), 3 * 1e17); // FIXME

        // Deploy and link strategies
        deployUSDCStrategies(address(usdcVault));
        deployETHStrategies(address(ethVault));

        // Set allocator on vault
        curator.submitSetAllocator(address(usdcVault), address(usdcAllocator), true);
        usdcVault.setIsAllocator(address(usdcAllocator), true);
        usdcVault.setOwner(newOwner);

        curator.submitSetAllocator(address(ethVault), address(ethAllocator), true);
        ethVault.setIsAllocator(address(ethAllocator), true);
        ethVault.setOwner(newOwner);

        // Transfer curator ownership
        curator.transferAdminOwnerShip(newOwner);

        // transfer allocator ownership
        usdcAllocator.transferAdminOwnerShip(newOwner);
        ethAllocator.transferAdminOwnerShip(newOwner);

        usdcTransmuter.setPendingAdmin(newOwner);
        ethTransmuter.setPendingAdmin(newOwner);
        
        vm.stopBroadcast();

        
        // Output deployment addresses
        console.log("alUSD deployed at:", address(alUSD));
        console.log("alETH deployed at:", address(alETH));
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
        console.log("- Add the new alchemists to the alAsset whitelist!");

        require(usdcAlchemist.admin() == newOwner);
        require(usdcTransmuter.pendingAdmin() == newOwner);
        require(ethAlchemist.admin() == newOwner);
        require(ethTransmuter.pendingAdmin() == newOwner);
        require(curator.pendingAdmin() == newOwner);
        require(usdcAllocator.pendingAdmin() == newOwner);
        require(ethAllocator.pendingAdmin() == newOwner);
        //require(ethAllocator.admin() == newOwner);
        //require(usdcAllocator.admin() == newOwner);
        //require(IERC20(alUSD).balanceOf(newOwner) == 1e27);
        //require(IERC20(alETH).balanceOf(newOwner) == 1e27);
    }
}
