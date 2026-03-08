// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVaultV2} from "vault-v2/interfaces/IVaultV2.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IMYTStrategy} from "./interfaces/IMYTStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IERC721Tiny {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/**
 * @title MYTStrategy
 * @notice The MYT is a Morpho V2 Vault, and each strategy is just a vault adapter which interfaces with a third party protocol
 * @notice This contract should be inherited by all strategies
 */
contract MYTStrategy is IMYTStrategy, Ownable {
    IVaultV2 public immutable MYT;
   // address public immutable receiptToken;
    address public allowanceHolder; // 0x Allowance holder
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant FIXED_POINT_SCALAR = 1e18;
    uint256 public constant MIN_SNAPSHOT_INTERVAL = 1 days;
    bytes4 public constant FORCE_DEALLOCATE_SELECTOR = 0xe4d38cd8;
    
    IMYTStrategy.StrategyParams public params;
    bytes32 public immutable adapterId;
    uint256 public lastSnapshotTime;
    uint256 public lastIndex;
    uint256 public estApr;
    uint256 public estApy;

    /// @notice This value is true when the underlying protocol is known to
    /// experience issues or security incidents. In this case the allocation step is simply
    /// bypassed without reverts (to keep external allocators from reverting).
    bool public killSwitch;

    mapping(address => bool) public whitelistedAllocators;

    /// @notice Modifier to restrict access to the vault **managed** by the MYT contract
    modifier onlyVault() {
        require(msg.sender == address(MYT), "PD");
        _;
    }

    /**
     * @notice Constructor for the MYTStrategy contract
     * @param _myt The address of the MYT vault
     * @param _params The parameters for the strategy
     */
    constructor(address _myt, StrategyParams memory _params) Ownable(_params.owner) {
        require(_params.owner != address(0));
        require(_myt != address(0));
        require(_params.slippageBPS < 1000);
        MYT = IVaultV2(_myt);
        params = _params;
        adapterId = keccak256(abi.encode("this", address(this)));
        allowanceHolder = 0x0000000000001fF3684f28c67538d4D072C22734;
    }
    
    /// @notice See Morpho V2 vault spec
    function allocate(bytes memory data, uint256 assets, bytes4 selector, address sender)
        external
        onlyVault
        returns (bytes32[] memory strategyIds, int256 change)
    {
        require(!killSwitch, StrategyAllocationPaused(address(this)));
        require(assets > 0, "Zero amount");
        uint256 amountAllocated;        

        VaultAdapterParams memory adapterParams = abi.decode(data, (VaultAdapterParams));
        ActionType action = adapterParams.action;
        if (action == ActionType.direct) {
            // Direct allocation (e.g., wrap WETH)
            amountAllocated = _allocate(assets);
        } else if (action == ActionType.swap) {
            // Direct swap (e.g., token -> swap -> WETH)
            amountAllocated = _allocate(assets, adapterParams.swapParams.txData);
        } else {
            revert("Invalid action");
        }
        
        uint256 oldAllocation = allocation();
        uint256 newAllocation = _totalValue();
        emit Allocate(amountAllocated, address(this));
        return (ids(), int256(newAllocation) - int256(oldAllocation));
    }

    /// @notice See Morpho V2 vault spec
    function deallocate(bytes memory data, uint256 assets, bytes4 selector, address sender)
        external
        onlyVault
        returns (bytes32[] memory strategyIds, int256 change)
    {
        require(assets > 0, "Zero amount");
        uint256 amountDeallocated;
        VaultAdapterParams memory adapterParams = abi.decode(data, (VaultAdapterParams));
        ActionType action = adapterParams.action;
        if (action == ActionType.direct) {
            amountDeallocated = _deallocate(assets);
        } else if (action == ActionType.swap && selector != FORCE_DEALLOCATE_SELECTOR) {
            // Direct swap (e.g., token → swap → WETH)
            amountDeallocated = _deallocate(assets, adapterParams.swapParams.txData);
        } else if (action == ActionType.unwrapAndSwap && selector != FORCE_DEALLOCATE_SELECTOR) {
            // Has intermediate step (e.g., unwrap wstETH → stETH → swap → WETH)
            amountDeallocated = _deallocate(assets, adapterParams.swapParams.txData, adapterParams.swapParams.minIntermediateOut);
        } else {
            revert("Invalid action");
        }
        uint256 oldAllocation = allocation();
        uint256 newAllocation = _totalValue();
        emit Deallocate(amountDeallocated, address(this));
        return (ids(), int256(newAllocation) - int256(oldAllocation));
    }

    function dexSwap(address to, address from, uint256 amount, uint256 minAmountOut, bytes memory callData) internal returns (uint256) {
        IERC20(from).approve(allowanceHolder, amount);
        uint256 targetBalanceBefore = IERC20(to).balanceOf(address(this));
        (bool success, ) = allowanceHolder.call(callData);
        require(success, "0x exception");
        uint256 targetBalanceAfter = IERC20(to).balanceOf(address(this));
        IERC20(from).approve(allowanceHolder, 0);
        uint256 amountReceived = targetBalanceAfter > targetBalanceBefore ? targetBalanceAfter - targetBalanceBefore : 0;
        if (amountReceived < minAmountOut) revert InvalidAmount(minAmountOut, amountReceived);
        return amountReceived;
    }

    /// @notice helper function to estimate the correct amount that can be fully
    /// withdrawn from a strategy, accounting for losses
    /// due to slippage, protocol fees, and rounding differences
    function previewAdjustedWithdraw(uint256 amount) external view returns (uint256) {
        require(amount > 0, "Zero amount");
        return _previewAdjustedWithdraw(amount);
    }

    /// @notice call this function to handle strategies with withdrawal queue NFT
    function claimWithdrawalQueue(uint256 positionId) public virtual returns (uint256 ret) {
        require(whitelistedAllocators[msg.sender], "PD");
        return _claimWithdrawalQueue(positionId);
    }

    /// @notice call this function to claim all available rewards from the respective
    /// protocol of this strategy
    function claimRewards(address token, bytes memory quote, uint256 minAmountOut) public onlyOwner virtual returns (uint256) {
        require(!killSwitch, "emergency");
        return _claimRewards(token, quote, minAmountOut);
    }

    /// @notice withdraw any leftover assets back to the vault
    function withdrawToVault() public virtual onlyOwner returns (uint256) {
        //Withdraw any leftover assets back to the vault
        uint256 leftover = IERC20(MYT.asset()).balanceOf(address(this));
        IERC20(MYT.asset()).transfer(address(MYT), leftover);
        emit WithdrawToVault(leftover);
        return leftover;
    }

    /// @notice Rescue arbitrary ERC20 tokens sent to this contract by mistake
    /// @param token The token to rescue
    /// @param to The recipient address
    /// @param amount The amount to rescue
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        require(!_isProtectedToken(token), "Protected token");
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(amount <= balance, "Insufficient balance");
        IERC20(token).transfer(to, amount);
        emit TokensRescued(token, to, amount);
    }

    /// @dev Check if a token is protected and cannot be rescued.
    /// Override this function in child contracts to add protocol-specific protected tokens
    /// (e.g., receipt tokens, aTokens, mTokens, staking tokens).
    /// @param token The token to check
    /// @return True if the token is protected
    function _isProtectedToken(address token) internal view virtual returns (bool) {
        return token == MYT.asset();
    }

    /// @dev override this function to handle wrapping/allocation/moving funds to
    /// the respective protocol of this strategy
    /// @notice uint56 amount returned should be equal to the amount parameter passed in
    /// @notice should attempt to log any loss due to rounding
    function _allocate(uint256 amount) internal virtual returns (uint256) {
        revert ActionNotSupported();
    }

    /// @dev override this function to handle wrapping/allocation/moving funds to
    /// the respective protocol of this strategy
    /// @notice uint56 amount returned should be equal to the amount parameter passed in
    /// @notice should attempt to log any loss due to rounding
    function _allocate(uint256 amount, bytes memory callData) internal virtual returns (uint256) {
        revert ActionNotSupported();
    }

    /// @dev override this function to handle unwrapping/deallocation/moving funds from
    /// the respective protocol of this strategy
    /// @notice uint56 amount returned must be equal to the amount parameter passed in
    /// @notice due to how MorphoVaultV2 internally handles deallocations,
    /// strategies must have atleast >= amount available at the end of this function call
    /// if not, the strategy will revert
    /// @notice amount of asset must be approved to the vault (i.e. msg.sender)
    function _deallocate(uint256 amount) internal virtual returns (uint256) {
        revert ActionNotSupported();
    }


    /// @dev override this function to handle unwrapping/deallocation/moving funds from
    /// the respective protocol of this strategy
    /// @notice uint56 amount returned must be equal to the amount parameter passed in
    /// @notice due to how MorphoVaultV2 internally handles deallocations,
    /// strategies must have atleast >= amount available at the end of this function call
    /// if not, the strategy will revert
    /// @notice amount of asset must be approved to the vault (i.e. msg.sender)
    function _deallocate(uint256 amount, bytes memory callData) internal virtual returns (uint256) {
        revert ActionNotSupported();
    }

    /// @dev override this function to handle unwrapping/deallocation/moving funds from
    /// the strategy to the vault using a swap with specified in calldata 
    /// @param amount the WETH amount expected to be returned to the vault
    /// @param callData the 0x swap calldata
    /// @param minIntermediateOutAmount the minimum amount of intermediate token expected to be received from the unwrap
    function _deallocate(uint256 amount, bytes memory callData, uint256 minIntermediateOutAmount) internal virtual returns (uint256) {
        revert ActionNotSupported();
    }

    /// @dev override this function to handle preview withdraw with slippage
    /// @notice this function should be used to estimate the correct amount that can be fully withdrawn, accounting for losses
    /// due to slippage, protocol fees, and rounding differences
    function _previewAdjustedWithdraw(uint256 amount) internal view virtual returns (uint256) {}

    /// @dev override this function to handle strategies with withdrawal queue NFT
    function _claimWithdrawalQueue(uint256 positionId) internal virtual returns (uint256) {}

    /// @dev override this function to claim all available rewards from the respective
    /// protocol of this strategy in the form of a specific token
    /// this ERC20 reward must then be converted to the MYT's asset
    function _claimRewards(address token, bytes memory quote, uint256 minAmountOut) internal virtual returns (uint256) {}

    // Helper for yield snapshot calculation
    function _approxAPY(uint256 ratePerSecWad) internal pure returns (uint256) {
        uint256 apr = ratePerSecWad * SECONDS_PER_YEAR;
        uint256 aprSq = apr * apr / FIXED_POINT_SCALAR;
        return apr + aprSq / 2;
    }

    // Helper for yield snapshot calculation
    function _lerp(uint256 oldVal, uint256 newVal, uint256 alpha) internal pure returns (uint256) {
        return alpha * oldVal / FIXED_POINT_SCALAR + (FIXED_POINT_SCALAR - alpha) * newVal / FIXED_POINT_SCALAR;
    }

    /// @notice recategorize this strategy to a different risk class
    function setRiskClass(RiskClass newClass) public onlyOwner {
        params.riskClass = newClass;
        emit RiskClassUpdated(newClass);
    }

    /// @dev some protocols may pay yield in baby tokens
    /// so we need to manually collect them
    function setAdditionalIncentives(bool newValue) public onlyOwner {
        params.additionalIncentives = newValue;
        emit IncentivesUpdated(newValue);
    }

    function setWhitelistedAllocator(address to, bool val) public onlyOwner {
        require(to != address(0));
        whitelistedAllocators[to] = val;
    }

    /// @notice enter/exit emergency mode for this strategy
    function setKillSwitch(bool val) public onlyOwner {
        killSwitch = val;
        emit Emergency(val);
    }

    function setAllowanceHolder(address _new) public onlyOwner {
        require(_new != address(0));
        allowanceHolder = _new;
    }

    /// @notice Update the slippage tolerance for this strategy
    function setSlippageBPS(uint256 newSlippageBPS) public onlyOwner {
        require(newSlippageBPS < 1000, "Slippage too high");
        params.slippageBPS = newSlippageBPS;
        emit SlippageBPSUpdated(newSlippageBPS);
    }
    /// @notice get the current snapshotted estimated yield for this strategy.
    /// This call does not guarantee the latest up-to-date yield and there might
    /// be discrepancies from the respective protocols numbers.
    function getEstimatedYield() public view returns (uint256) {
        return params.estimatedYield;
    }

    function getCap() external view returns (uint256) {
        return params.cap;
    }

    function getGlobalCap() external view returns (uint256) {
        return params.globalCap;
    }

    function ids() public view returns (bytes32[] memory) {
        bytes32[] memory ids_ = new bytes32[](1);
        ids_[0] = adapterId;
        return ids_;
    }

    /// @notice Returns the vault's current allocation tracking for this adapter
    function allocation() public view returns (uint256) {
        return MYT.allocation(adapterId);
    }

    function getIdData() external view returns (bytes memory) {
        return abi.encode("this", address(this));
    }

    /// @dev override this function to return the total underlying value of the strategy
    /// @dev must return the total underling value of the strategy's position (i.e. in vault asset e.g. USDC or WETH)
    function _totalValue() internal view virtual returns (uint256) {}

    /// @notice External function per IAdapter spec - returns total underlying value
    function realAssets() external view virtual returns (uint256) {
        return _totalValue();
    }

}
