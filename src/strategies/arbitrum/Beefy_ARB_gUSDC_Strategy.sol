pragma solidity ^0.8.21;

import {IERC4626} from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";

/**
 * TODO: Implement this strategy
 * @title Beefy_ARB_gUSDC_Strategy
 * @notice This strategy is used to allocate and deallocate usdc to the Beefy gUSDC pool
 * @dev This strategy is used to allocate and deallocate usdc to the Beefy gUSDC pool
 * @dev This strategy is used to allocate and deallocate usdc to the Beefy gUSDC pool
 */
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract Beefy_ARB_gUSDC_Strategy is MYTStrategy {
    IERC20 public immutable USDC;
    IERC20 public immutable gUSDC;

    constructor(address _myt, StrategyParams memory _params, address _usdc, address _gUSDC, address _permit2Address)
        MYTStrategy(_myt, _params, _permit2Address, _gUSDC)
    {
        USDC = IERC20(_usdc);
        gUSDC = IERC20(_gUSDC);
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        require(TokenUtils.safeBalanceOf(address(USDC), address(this)) >= amount, "Strategy balance is less than the amount needed");
        return _doSwapToLP(amount);
    }

    function _doSwapToLP(uint256 amount) internal returns (uint256) {
        return amount;
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        return _doSwapFromLP(amount);
    }

    function _doSwapFromLP(uint256 amount) internal returns (uint256) {
        return amount;
    }

    function realAssets() external view override returns (uint256) {
        return 0;
    }

    function _previewAdjustedWithdraw(uint256 amount) internal view override returns (uint256) {
        return amount - (amount * slippageBPS / 10_000);
    }
}
