// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {MYTStrategy} from "../../MYTStrategy.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";

/**
 * TODO: Implement this strategy
 * @title VelodromeUSDC_To_USDT0_USDT_LP_Strategy
 * @notice This strategy is used to allocate and deallocate usdc to the Velodrome USDT0/USDT LP pool
 */
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IVelodromeRouterV2 {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function getAmountsOut(uint256 amountIn, Route[] calldata routes) external view returns (uint256[] memory amounts);

    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, Route[] calldata routes, address to, uint256 deadline)
        external
        returns (uint256[] memory amounts);

    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
}

interface IVeloPoolFactory {
    function getPool(address tokenA, address tokenB, bool stable) external view returns (address);
}

interface IVeloPair { /* ERC20 LP */
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint256 reserve0, uint256 reserve1, uint256 blockTimestampLast);
}

/*
   Velodrome v2 USDT0<>USDT LP Adapter (USDC-only parent)
   Network: Optimism
   - Parent vault sends USDC in, receives USDC out.
   - Uses concrete single-hop stable routes via PoolFactory V2.
 */

// Velodrome v2 USDT0<>USDT LP Adapter (USDC in/out only)
contract VelodromeUSDC_ToUSDT0_USDT_LP_Strategy is MYTStrategy {
    /* ----- Canonical OP addresses (verify in deployment env) ----- */
    address public constant ROUTER_V2 = 0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858;
    address public constant FACTORY_V2 = 0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a;
    address public constant USDC_OP = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address public constant USDT0_OP = 0x01bFF41798a0BcF287b996046Ca68b395DbC1071;
    address public constant USDT_OP = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;
    bool public constant STABLE = true;

    /* ----- State ----- */
    IERC20 public immutable USDC; // vault asset (USDC)
    IERC20 public immutable USDT0; // pool token
    IERC20 public immutable USDT; // pool token
    IVelodromeRouterV2 public immutable router;
    IVeloPoolFactory public immutable factory;
    address public immutable parentVault;

    address public immutable pool; // USDT0/USDT LP token
    uint256 public txDeadline; // seconds to add to block.timestamp for router calls

    constructor(
        address _myt,
        StrategyParams memory _params,
        address _usdc,
        address _usdt,
        address _usdt0,
        address _router,
        address _factory,
        uint256 _txDeadline, // e.g., 600 (10 min)
        address _permit2Address
    ) MYTStrategy(_myt, _params, _permit2Address, _usdc) {
        USDC = IERC20(_usdc);
        USDT = IERC20(_usdt);
        USDT0 = IERC20(_usdt0);
        router = IVelodromeRouterV2(_router);
        factory = IVeloPoolFactory(_factory);
        txDeadline = _txDeadline;
        address _pool = factory.getPool(_usdt0, _usdt, STABLE);
        require(_pool != address(0), "pool not found");
        pool = _pool;
    }

    // amount in USDC in, Lp Tokens out
    function _allocate(uint256 amount) internal override returns (uint256) {
        require(TokenUtils.safeBalanceOf(address(USDC), address(this)) >= amount, "Strategy balance is less than the amount needed");
        return _doSwapToLP(amount);
    }

    // amount in USDC needed, Lp Tokens in, USDC out
    function _deallocate(uint256 amount) internal override returns (uint256) {
        return _doSwapFromLP(amount);
    }

    function _doSwapToLP(uint256 amount) internal returns (uint256) {
        // TODO: Implement
        return amount;
    }

    function _doSwapFromLP(uint256 amount) internal returns (uint256) {
        // TODO: Implement
        return amount;
    }

    function realAssets() external view override returns (uint256) {
        // TODO: Implement
        return 0;
    }
}
