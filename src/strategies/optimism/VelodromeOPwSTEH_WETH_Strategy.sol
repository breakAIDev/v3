// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {MYTStrategy} from "../../MYTStrategy.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";

/**
 * TODO: Implement this strategy
 * @title VelodromeOPwSTEH_WETH_Strategy
 * @notice This strategy is used to allocate and deallocate weth to the Velodrome OP wSTEH/WETH LP pool
 */
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IVeloRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    struct Zap {
        address tokenA;
        address tokenB;
        bool stable;
        address factory;
        uint256 amountOutMinA;
        uint256 amountOutMinB;
        uint256 amountAMin;
        uint256 amountBMin;
    }

    function zapIn(
        address tokenIn,
        uint256 amountInA,
        uint256 amountInB,
        Zap calldata zapInPool,
        Route[] calldata routesA,
        Route[] calldata routesB,
        address to,
        bool stake
    ) external payable returns (uint256 liquidity);

    function zapOut(address tokenOut, uint256 liquidity, Zap calldata zapOutPool, Route[] calldata routesA, Route[] calldata routesB) external;

    function quoteRemoveLiquidity(address tokenA, address tokenB, bool stable, address factory, uint256 liq)
        external
        view
        returns (uint256 amountA, uint256 amountB);
}

interface IPoolLike is IERC20 {} // the LP token itself (pool contract is ERC20)

interface IWstETH {
    function stEthPerToken() external view returns (uint256);
}

contract VelodromeOPwSTEH_WETH_Strategy is MYTStrategy {
    IERC20 public immutable weth; // 0x4200...0006 on OP
    IWstETH public immutable wstETH; // 0x1f32...4a194ebb on OP
    IVeloRouter public immutable router;
    IPoolLike public immutable lp;
    address public immutable factory; // approved v2 factory
    bool public constant STABLE = false;

    constructor(
        address _myt,
        StrategyParams memory _params,
        address _weth,
        address _wstETH,
        address _router,
        address _factory,
        address _pool,
        address _permit2Address
    ) MYTStrategy(_myt, _params, _permit2Address, _weth) {
        weth = IERC20(_weth);
        wstETH = IWstETH(_wstETH);
        router = IVeloRouter(_router);
        factory = _factory;
        lp = IPoolLike(_pool);
    }

    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
        return amount;
    }

    function _deallocate(uint256 amount) internal override returns (uint256 withdrawReturn) {
        return amount;
    }

    function realAssets() external view override returns (uint256) {
        return 0;
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        // Apply slippage to account for LP removal and conversion losses
        return amount - (amount * slippageBPS / 10_000);
    }
}
