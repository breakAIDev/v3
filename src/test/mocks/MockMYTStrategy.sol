// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {IMockYieldToken} from "./MockYieldToken.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";

contract MockMYTStrategy is MYTStrategy {
    IMockYieldToken public immutable token;

    constructor(address _myt, address _token, IMYTStrategy.StrategyParams memory _params)
        MYTStrategy(_myt, _params)
    {
        token = IMockYieldToken(_token);
    }

    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
        // if native eth used, most strats will have their own function to wrap eth to weth
        // so will assume that all token deposits are done with weth
        TokenUtils.safeApprove(token.underlyingToken(), address(token), 2 * amount);
        depositReturn = token.deposit(amount);
        require(depositReturn == amount);
    }

    function _deallocate(uint256 assets) internal override returns (uint256 amountReturned) {
        // `assets` is in underlying units requested by the vault.
        uint256 price = token.price(); // WAD, underlying value of 10**dec shares
        uint8 dec = token.decimals();

        // sharesToBurn = assets * 10**dec / price
        uint256 sharesToBurn = (assets * (10 ** uint256(dec))) / price;

        uint256 shareBal = token.balanceOf(address(this));
        require(sharesToBurn <= shareBal, "insufficient shares");

        // Burn shares and receive underlying back to this strategy.
        amountReturned = token.requestWithdraw(address(this), sharesToBurn);

        // Approve the actual amount of underlying returned for the vault to pull.
        TokenUtils.safeApprove(token.underlyingToken(), msg.sender, amountReturned);
        require(amountReturned != 0, "zero withdraw");
    }

    function realAssets() external view override returns (uint256) {
        return _totalValue();
    }

    function _totalValue() internal view override returns (uint256) {
        return (token.balanceOf(address(this)) * token.price()) / 10 ** token.decimals();
    }

    function mockUpdateWhitelistedAllocators(address allocator, bool value) public {}
}
