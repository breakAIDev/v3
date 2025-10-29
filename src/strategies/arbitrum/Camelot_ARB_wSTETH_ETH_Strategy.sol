pragma solidity ^0.8.21;

import {IERC4626} from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";

/**
 * TODO: Implement this strategy
 * @title Camelot_ARB_WSTETH_AND_ETH_Strategy
 * @notice This strategy is used to allocate and deallocate WETH, WSTETH, and ETH to the Camelot pool
 * @dev This strategy is used to allocate and deallocate WETH, WSTETH, and ETH to the Camelot pool
 * @dev This strategy is used to allocate and deallocate WETH, WSTETH, and ETH to the Camelot pool
 */
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface INonfungiblePositionManager {}

contract CAMELOT_ARB_wSTETH_ETH_STRATEGY is MYTStrategy {
    IERC20 public immutable weth; // 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1
    IERC20 public immutable wsteth; // 0x5979d7b546e38e414f7e9822514be443a4800529
    INonfungiblePositionManager public immutable nonFungiblePositionManager; // 0x00c7f3082833e796a5b3e4bd59f6642ff44dcd15

    constructor(address _myt, StrategyParams memory _params, address _weth, address _wsteth, address _nonFungiblePositionManager, address _permit2Address)
        MYTStrategy(_myt, _params, _permit2Address, _weth)
    {
        weth = IERC20(_weth);
        wsteth = IERC20(_wsteth);
        nonFungiblePositionManager = INonfungiblePositionManager(_nonFungiblePositionManager);
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
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
