// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./interfaces/IAlchemistV3.sol";
import {ITokenAdapter} from "./interfaces/ITokenAdapter.sol";
import {ITransmuter} from "./interfaces/ITransmuter.sol";
import {IAlchemistV3Position} from "./interfaces/IAlchemistV3Position.sol";
import {IFeeVault} from "./interfaces/IFeeVault.sol";
import "./libraries/PositionDecay.sol";
import {TokenUtils} from "./libraries/TokenUtils.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {Initializable} from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Unauthorized, IllegalArgument, IllegalState, MissingInputData} from "./base/Errors.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IAlchemistTokenVault} from "./interfaces/IAlchemistTokenVault.sol";
import {IVaultV2} from "../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {FixedPointMath} from "./libraries/FixedPointMath.sol";

/// @title  AlchemistV3
/// @author Alchemix Finance
contract AlchemistV3 is IAlchemistV3, Initializable {
    using SafeCast for int256;
    using SafeCast for uint256;
    using SafeCast for int128;
    using SafeCast for uint128;

    uint256 public constant BPS = 10_000;
    uint256 public constant FIXED_POINT_SCALAR = 1e18;

    uint256 public constant ONE_Q128 = uint256(1) << 128;

    /// @inheritdoc IAlchemistV3Immutables
    string public constant version = "3.0.0";

    /// @inheritdoc IAlchemistV3State
    address public admin;

    /// @inheritdoc IAlchemistV3State
    address public alchemistFeeVault;

    /// @inheritdoc IAlchemistV3Immutables
    address public debtToken;

    /// @inheritdoc IAlchemistV3State
    address public myt;

    /// @inheritdoc IAlchemistV3State
    uint256 public underlyingConversionFactor;

    /// @inheritdoc IAlchemistV3State
    uint256 public cumulativeEarmarked;

    /// @inheritdoc IAlchemistV3State
    uint256 public depositCap;

    /// @inheritdoc IAlchemistV3State
    uint256 public lastEarmarkBlock;

    /// @inheritdoc IAlchemistV3State
    uint256 public lastRedemptionBlock;

    /// @inheritdoc IAlchemistV3State
    uint256 public lastTransmuterTokenBalance;

    /// @inheritdoc IAlchemistV3State
    uint256 public minimumCollateralization;

    /// @inheritdoc IAlchemistV3State
    uint256 public collateralizationLowerBound;

    /// @inheritdoc IAlchemistV3State
    uint256 public globalMinimumCollateralization;

    /// @inheritdoc IAlchemistV3State
    uint256 public totalDebt;

    /// @inheritdoc IAlchemistV3State
    uint256 public totalSyntheticsIssued;

    /// @inheritdoc IAlchemistV3State
    uint256 public protocolFee;

    /// @inheritdoc IAlchemistV3State
    uint256 public liquidatorFee;

    /// @inheritdoc IAlchemistV3State
    uint256 public repaymentFee;

    /// @inheritdoc IAlchemistV3State
    address public alchemistPositionNFT;

    /// @inheritdoc IAlchemistV3State
    address public protocolFeeReceiver;

    /// @inheritdoc IAlchemistV3State
    address public underlyingToken;

    /// @inheritdoc IAlchemistV3State
    address public tokenAdapter;

    /// @inheritdoc IAlchemistV3State
    address public transmuter;

    /// @inheritdoc IAlchemistV3State
    address public pendingAdmin;

    /// @inheritdoc IAlchemistV3State
    bool public depositsPaused;

    /// @inheritdoc IAlchemistV3State
    bool public loansPaused;

    /// @inheritdoc IAlchemistV3State
    mapping(address => bool) public guardians;

    /// @dev Total debt redeemed via Transmuter redemptions
    uint256 private _totalRedeemedDebt;

    /// @dev Total MYT shares paid out for redemptions (collRedeemed + feeCollateral)
    uint256 private _totalRedeemedSharesOut;

    /// @dev Weight of earmarked amount / total unearmarked debt
    uint256 private _earmarkWeight;

    /// @dev Weight of redemption amount / total earmarked debt
    uint256 private _redemptionWeight;

    /// @dev Earmarked scaled by survival
    uint256 private _survivalAccumulator;

    /// @dev Total yield tokens deposited
    /// This is used to differentiate between tokens deposited into a CDP and balance of the contract
    uint256 private _mytSharesDeposited;

    /// @dev MYT shares of transmuter balance increase not yet applied as cover in _earmark()
    uint256 private _pendingCoverShares;

    /// @dev User accounts
    mapping(uint256 => Account) private _accounts;

    /// @dev Historic redemptions
    mapping(uint256 => RedemptionInfo) private _redemptions;

    modifier onlyAdmin() {
        if (msg.sender != admin) {
            revert Unauthorized();
        }
        _;
    }

    modifier onlyAdminOrGuardian() {
        if (msg.sender != admin && !guardians[msg.sender]) {
            revert Unauthorized();
        }
        _;
    }

    modifier onlyTransmuter() {
        if (msg.sender != transmuter) {
            revert Unauthorized();
        }
        _;
    }

    constructor() initializer {}

    function initialize(AlchemistInitializationParams memory params) external initializer {
        _checkArgument(params.protocolFee <= BPS);
        _checkArgument(params.liquidatorFee <= BPS);
        _checkArgument(params.repaymentFee <= BPS);

        debtToken = params.debtToken;
        underlyingToken = params.underlyingToken;
        underlyingConversionFactor = 10 ** (TokenUtils.expectDecimals(params.debtToken) - TokenUtils.expectDecimals(params.underlyingToken));
        depositCap = params.depositCap;
        minimumCollateralization = params.minimumCollateralization;
        globalMinimumCollateralization = params.globalMinimumCollateralization;
        collateralizationLowerBound = params.collateralizationLowerBound;
        admin = params.admin;
        transmuter = params.transmuter;
        protocolFee = params.protocolFee;
        protocolFeeReceiver = params.protocolFeeReceiver;
        liquidatorFee = params.liquidatorFee;
        repaymentFee = params.repaymentFee;
        lastEarmarkBlock = block.number;
        lastRedemptionBlock = block.number;
        myt = params.myt;
    }

    /// @notice Sets the NFT position token, callable by admin.
    function setAlchemistPositionNFT(address nft) external onlyAdmin {
        if (nft == address(0)) {
            revert AlchemistV3NFTZeroAddressError();
        }

        if (alchemistPositionNFT != address(0)) {
            revert AlchemistV3NFTAlreadySetError();
        }

        alchemistPositionNFT = nft;
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setAlchemistFeeVault(address value) external onlyAdmin {
        if (IFeeVault(value).token() != underlyingToken) {
            revert AlchemistVaultTokenMismatchError();
        }
        alchemistFeeVault = value;
        emit AlchemistFeeVaultUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setPendingAdmin(address value) external onlyAdmin {
        pendingAdmin = value;

        emit PendingAdminUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function acceptAdmin() external {
        _checkState(pendingAdmin != address(0));

        if (msg.sender != pendingAdmin) {
            revert Unauthorized();
        }

        admin = pendingAdmin;
        pendingAdmin = address(0);

        emit AdminUpdated(admin);
        emit PendingAdminUpdated(address(0));
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setDepositCap(uint256 value) external onlyAdmin {
        _checkArgument(value >= IERC20(myt).balanceOf(address(this)));

        depositCap = value;
        emit DepositCapUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setProtocolFeeReceiver(address value) external onlyAdmin {
        _checkArgument(value != address(0));

        protocolFeeReceiver = value;
        emit ProtocolFeeReceiverUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setProtocolFee(uint256 fee) external onlyAdmin {
        _checkArgument(fee <= BPS);

        protocolFee = fee;
        emit ProtocolFeeUpdated(fee);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setLiquidatorFee(uint256 fee) external onlyAdmin {
        _checkArgument(fee <= BPS);

        liquidatorFee = fee;
        emit LiquidatorFeeUpdated(fee);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setRepaymentFee(uint256 fee) external onlyAdmin {
        _checkArgument(fee <= BPS);

        repaymentFee = fee;
        emit RepaymentFeeUpdated(fee);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setTokenAdapter(address value) external onlyAdmin {
        _checkArgument(value != address(0));

        tokenAdapter = value;
        emit TokenAdapterUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setGuardian(address guardian, bool isActive) external onlyAdmin {
        _checkArgument(guardian != address(0));

        guardians[guardian] = isActive;
        emit GuardianSet(guardian, isActive);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setMinimumCollateralization(uint256 value) external onlyAdmin {
        _checkArgument(value >= FIXED_POINT_SCALAR);

        // cannot exceed global minimum
        minimumCollateralization = value > globalMinimumCollateralization ? globalMinimumCollateralization : value;

        emit MinimumCollateralizationUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setGlobalMinimumCollateralization(uint256 value) external onlyAdmin {
        _checkArgument(value >= minimumCollateralization);
        globalMinimumCollateralization = value;
        emit GlobalMinimumCollateralizationUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setCollateralizationLowerBound(uint256 value) external onlyAdmin {
        _checkArgument(value <= minimumCollateralization);
        _checkArgument(value >= FIXED_POINT_SCALAR);
        collateralizationLowerBound = value;
        emit CollateralizationLowerBoundUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function pauseDeposits(bool isPaused) external onlyAdminOrGuardian {
        depositsPaused = isPaused;
        emit DepositsPaused(isPaused);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function pauseLoans(bool isPaused) external onlyAdminOrGuardian {
        loansPaused = isPaused;
        emit LoansPaused(isPaused);
    }

    /// @inheritdoc IAlchemistV3State
    function getCDP(uint256 tokenId) external view returns (uint256, uint256, uint256) {
        (uint256 debt, uint256 earmarked, uint256 collateral) = _calculateUnrealizedDebt(tokenId);
        return (collateral, debt, earmarked);
    }

    /// @inheritdoc IAlchemistV3State
    function getTotalDeposited() external view returns (uint256) {
        return _mytSharesDeposited;
    }

    /// @inheritdoc IAlchemistV3State
    function getMaxBorrowable(uint256 tokenId) external view returns (uint256) {
        (uint256 debt,, uint256 collateral) = _calculateUnrealizedDebt(tokenId);
        uint256 debtValueOfCollateral = convertYieldTokensToDebt(collateral);
        uint256 capacity = (debtValueOfCollateral * FIXED_POINT_SCALAR / minimumCollateralization);
        return debt > capacity  ? 0 : capacity - debt;
    }

    /// @inheritdoc IAlchemistV3State
    function getMaxWithdrawable(uint256 tokenId) external view returns (uint256) {
        (uint256 debt,, uint256 collateral) = _calculateUnrealizedDebt(tokenId);

        uint256 lockedCollateral = 0;
        if (debt != 0) {
            lockedCollateral = (convertDebtTokensToYield(debt) * minimumCollateralization) / FIXED_POINT_SCALAR;
        }

        uint256 positionFree = collateral > lockedCollateral ? collateral - lockedCollateral : 0;
        uint256 required = _requiredLockedShares();
        uint256 globalFree = _mytSharesDeposited > required ? _mytSharesDeposited - required : 0;

        return positionFree < globalFree ? positionFree : globalFree;
    }

    /// @inheritdoc IAlchemistV3State
    function mintAllowance(uint256 ownerTokenId, address spender) external view returns (uint256) {
        Account storage account = _accounts[ownerTokenId];
        return account.mintAllowances[account.allowancesVersion][spender];
    }

    /// @inheritdoc IAlchemistV3State
    function getTotalUnderlyingValue() external view returns (uint256) {
        return _getTotalUnderlyingValue();
    }

    
    /// @inheritdoc IAlchemistV3State
    function getTotalLockedUnderlyingValue() external view returns (uint256) {
        return _getTotalLockedUnderlyingValue();
    }

    /// @inheritdoc IAlchemistV3State
    function totalValue(uint256 tokenId) public view returns (uint256) {
        return _totalCollateralValue(tokenId, true);
    }

    /// @inheritdoc IAlchemistV3Actions
    function deposit(uint256 amount, address recipient, uint256 tokenId) external returns (uint256) {
        _checkArgument(recipient != address(0));
        _checkArgument(amount > 0);
        _checkState(!depositsPaused);
        _checkState(_mytSharesDeposited + amount <= depositCap);

        // Only mint a new position if the id is 0
        if (tokenId == 0) {
            tokenId = IAlchemistV3Position(alchemistPositionNFT).mint(recipient);
            emit AlchemistV3PositionNFTMinted(recipient, tokenId);
        } else {
            _checkForValidAccountId(tokenId);
            _earmark();
            _sync(tokenId);
        }

        _accounts[tokenId].collateralBalance += amount;

        // Transfer tokens from msg.sender now that the internal storage updates have been committed.
        TokenUtils.safeTransferFrom(myt, msg.sender, address(this), amount);
        _mytSharesDeposited += amount;

        emit Deposit(amount, tokenId);

        return convertYieldTokensToDebt(amount);
    }

    /// @inheritdoc IAlchemistV3Actions
    function withdraw(uint256 amount, address recipient, uint256 tokenId) external returns (uint256) {
        _checkArgument(recipient != address(0));
        _checkForValidAccountId(tokenId);
        _checkArgument(amount > 0);
        _checkAccountOwnership(IAlchemistV3Position(alchemistPositionNFT).ownerOf(tokenId), msg.sender);
        _earmark();

        _sync(tokenId);

        uint256 lockedCollateral = convertDebtTokensToYield(_accounts[tokenId].debt) * minimumCollateralization / FIXED_POINT_SCALAR;
        _checkArgument(_accounts[tokenId].collateralBalance - lockedCollateral >= amount);
        _subCollateralBalance(amount, tokenId);

        // Assure that the collateralization invariant is still held.
        _validate(tokenId);

        // Transfer the yield tokens to msg.sender
        TokenUtils.safeTransfer(myt, recipient, amount);

        emit Withdraw(amount, tokenId, recipient);

        return amount;
    }

    /// @inheritdoc IAlchemistV3Actions
    function mint(uint256 tokenId, uint256 amount, address recipient) external {
        _checkArgument(recipient != address(0));
        _checkForValidAccountId(tokenId);
        _checkArgument(amount > 0);
        _checkState(!loansPaused);
        _checkAccountOwnership(IAlchemistV3Position(alchemistPositionNFT).ownerOf(tokenId), msg.sender);

        // Query transmuter and earmark global debt
        _earmark();

        // Sync current user debt before more is taken
        _sync(tokenId);

        // Mint tokens to recipient
        _mint(tokenId, amount, recipient);
    }

    /// @inheritdoc IAlchemistV3Actions
    function mintFrom(uint256 tokenId, uint256 amount, address recipient) external {
        _checkArgument(amount > 0);
        _checkForValidAccountId(tokenId);
        _checkArgument(recipient != address(0));
        _checkState(!loansPaused);
        // Preemptively try and decrease the minting allowance. This will save gas when the allowance is not sufficient.
        _decreaseMintAllowance(tokenId, msg.sender, amount);

        // Query transmuter and earmark global debt
        _earmark();

        // Sync current user debt before more is taken
        _sync(tokenId);

        // Mint tokens from the tokenId's account to the recipient.
        _mint(tokenId, amount, recipient);
    }

    /// @inheritdoc IAlchemistV3Actions
    function burn(uint256 amount, uint256 recipientId) external returns (uint256) {
        _checkArgument(amount > 0);
        _checkForValidAccountId(recipientId);
        // Check that the user did not mint in this same block
        // This is used to prevent flash loan repayments
        if (block.number == _accounts[recipientId].lastMintBlock) revert CannotRepayOnMintBlock();

        // Query transmuter and earmark global debt
        _earmark();

        // Sync current user debt before more is taken
        _sync(recipientId);

        uint256 debt;
        // Burning alAssets can only repay unearmarked debt
        _checkState((debt = _accounts[recipientId].debt - _accounts[recipientId].earmarked) > 0);

        uint256 credit = amount > debt ? debt : amount;

        // Must only burn enough tokens that the transmuter positions can still be fulfilled
        if (credit > totalSyntheticsIssued - ITransmuter(transmuter).totalLocked()) {
            revert BurnLimitExceeded(credit, totalSyntheticsIssued - ITransmuter(transmuter).totalLocked());
        }

        // Burn the tokens from the message sender
        TokenUtils.safeBurnFrom(debtToken, msg.sender, credit);

        // Debt is subject to protocol fee similar to redemptions
        _accounts[recipientId].collateralBalance -= convertDebtTokensToYield(credit) * protocolFee / BPS;
        TokenUtils.safeTransfer(myt, protocolFeeReceiver, convertDebtTokensToYield(credit) * protocolFee / BPS);
        _mytSharesDeposited -= convertDebtTokensToYield(credit) * protocolFee / BPS;

        // Update the recipient's debt.
        _subDebt(recipientId, credit);
        _accounts[recipientId].lastRepayBlock = block.number;

        totalSyntheticsIssued -= credit;

        // Assure that the collateralization invariant is still held.
        _validate(recipientId);

        emit Burn(msg.sender, credit, recipientId);

        return credit;
    }

    /// @inheritdoc IAlchemistV3Actions
    function repay(uint256 amount, uint256 recipientTokenId) public returns (uint256) {
        _checkArgument(amount > 0);
        _checkForValidAccountId(recipientTokenId);
        Account storage account = _accounts[recipientTokenId];
        // Check that the user did not mint in this same block
        // This is used to prevent flash loan repayments
        if (block.number == account.lastMintBlock) revert CannotRepayOnMintBlock();

        // Query transmuter and earmark global debt
        _earmark();

        // Sync current user debt before deciding how much is available to be repaid
        _sync(recipientTokenId);

        uint256 debt;

        // Burning yieldTokens will pay off all types of debt
        _checkState((debt = account.debt) > 0);

        uint256 yieldToDebt = convertYieldTokensToDebt(amount);
        uint256 credit = yieldToDebt > debt ? debt : yieldToDebt;

        // Repay debt from earmarked amount of debt first
        _subEarmarkedDebt(credit, recipientTokenId);


        uint256 creditToYield = convertDebtTokensToYield(credit);


        // Debt is subject to protocol fee similar to redemptions
        uint256 feeAmount = creditToYield * protocolFee / BPS;
        if (feeAmount > account.collateralBalance) {
            revert("Not enough collateral to pay for debt fee");
        } else {
            _subCollateralBalance(feeAmount, recipientTokenId);
        }

        _subDebt(recipientTokenId, credit);
        account.lastRepayBlock = block.number;

        // Transfer the repaid tokens to the transmuter.
        TokenUtils.safeTransferFrom(myt, msg.sender, transmuter, creditToYield);
        TokenUtils.safeTransfer(myt, protocolFeeReceiver, creditToYield * protocolFee / BPS);
        emit Repay(msg.sender, amount, recipientTokenId, creditToYield);

        return creditToYield;
    }

    /// @inheritdoc IAlchemistV3Actions
    function liquidate(uint256 accountId) external override returns (uint256 yieldAmount, uint256 feeInYield, uint256 feeInUnderlying) {
        _checkForValidAccountId(accountId);
        (yieldAmount, feeInYield, feeInUnderlying) = _liquidate(accountId);
        if (yieldAmount > 0) {
            return (yieldAmount, feeInYield, feeInUnderlying);
        } else {
            // no liquidation amount returned, so no liquidation happened
            revert LiquidationError();
        }
    }

    /// @inheritdoc IAlchemistV3Actions
    function batchLiquidate(uint256[] memory accountIds)
        external
        returns (uint256 totalAmountLiquidated, uint256 totalFeesInYield, uint256 totalFeesInUnderlying)
    {
        if (accountIds.length == 0) {
            revert MissingInputData();
        }

        for (uint256 i = 0; i < accountIds.length; i++) {
            uint256 accountId = accountIds[i];
            if (accountId == 0 || !_tokenExists(alchemistPositionNFT, accountId)) {
                continue;
            }
            (uint256 underlyingAmount, uint256 feeInYield, uint256 feeInUnderlying) = _liquidate(accountId);
            totalAmountLiquidated += underlyingAmount;
            totalFeesInYield += feeInYield;
            totalFeesInUnderlying += feeInUnderlying;
        }

        if (totalAmountLiquidated > 0) {
            return (totalAmountLiquidated, totalFeesInYield, totalFeesInUnderlying);
        } else {
            // no total liquidation amount returned, so no liquidations happened
            revert LiquidationError();
        }
    }

    /// @inheritdoc IAlchemistV3Actions
    function redeem(uint256 amount) external onlyTransmuter returns (uint256 sharesSent) {
        _earmark();

        uint256 liveEarmarked = cumulativeEarmarked;
        if (amount > liveEarmarked) amount = liveEarmarked;

       // Apply redemption weights/decay to the full amount that left the earmarked bucket
        if (liveEarmarked != 0 && amount != 0) {
            uint256 survival = ((liveEarmarked - amount) << 128) / liveEarmarked;
            _survivalAccumulator = FixedPointMath.mulQ128(_survivalAccumulator, survival);
            _redemptionWeight += PositionDecay.WeightIncrement(amount, cumulativeEarmarked);
        }

        // earmarks are reduced by the full redeemed amount (net + cover)
        cumulativeEarmarked -= amount;

        // global borrower debt falls by the full redeemed amount
        totalDebt -= amount;

        lastRedemptionBlock = block.number;

        // move only the net collateral + fee
        uint256 collRedeemed  = convertDebtTokensToYield(amount);
        uint256 feeCollateral = collRedeemed * protocolFee / BPS;

        _totalRedeemedDebt += amount;
        _totalRedeemedSharesOut += collRedeemed;

        TokenUtils.safeTransfer(myt, transmuter, collRedeemed);
        _mytSharesDeposited -= collRedeemed;

        // If system is insolvent and there are not enough funds to pay fee to protocol then we skip the fee
        if (feeCollateral <= _mytSharesDeposited) {
            TokenUtils.safeTransfer(myt, protocolFeeReceiver, feeCollateral);
            _mytSharesDeposited -= feeCollateral;
            _totalRedeemedSharesOut += feeCollateral;
        }

        emit Redemption(amount);

        return collRedeemed;
    }

    ///@inheritdoc IAlchemistV3Actions
    function reduceSyntheticsIssued(uint256 amount) external onlyTransmuter {
        totalSyntheticsIssued -= amount;
    }

    ///@inheritdoc IAlchemistV3Actions
    function setTransmuterTokenBalance(uint256 amount) external onlyTransmuter {
        uint256 last = lastTransmuterTokenBalance;

        // If balance went down, assume cover could have been spent and reduce it conservatively.
        if (amount < last) {
            uint256 spent = last - amount;
            uint256 cover = _pendingCoverShares;

            if (spent >= cover) {
                _pendingCoverShares = 0;
            } else {
                _pendingCoverShares = cover - spent;
            }
        }

        // Always keep cover <= actual transmuter balance.
        if (_pendingCoverShares > amount) {
            _pendingCoverShares = amount;
        }

        // Update baseline
        lastTransmuterTokenBalance = amount;
    }

    /// @inheritdoc IAlchemistV3Actions
    function poke(uint256 tokenId) external {
        _checkForValidAccountId(tokenId);
        _poke(tokenId);
    }


    /// @dev Pokes the account owned by `tokenId` to sync the state.
    /// @param tokenId The tokenId of the account to poke.
    function _poke(uint256 tokenId) internal {
        _earmark();
        _sync(tokenId);
    }

    /// @inheritdoc IAlchemistV3Actions
    function approveMint(uint256 tokenId, address spender, uint256 amount) external {
        _checkAccountOwnership(IAlchemistV3Position(alchemistPositionNFT).ownerOf(tokenId), msg.sender);
        _approveMint(tokenId, spender, amount);
    }

    /// @inheritdoc IAlchemistV3Actions
    function resetMintAllowances(uint256 tokenId) external {
        // Allow calls from either the token owner or the NFT contract
        if (msg.sender != address(alchemistPositionNFT)) {
            // Direct call - verify caller is current owner
            address tokenOwner = IERC721(alchemistPositionNFT).ownerOf(tokenId);
            if (msg.sender != tokenOwner) {
                revert Unauthorized();
            }
        }
        // increment version to start the mapping from a fresh state
        _accounts[tokenId].allowancesVersion += 1;
        // Emit event to notify allowance clearing
        emit MintAllowancesReset(tokenId);
    }

    /// @inheritdoc IAlchemistV3State
    function convertYieldTokensToDebt(uint256 amount) public view returns (uint256) {
        return normalizeUnderlyingTokensToDebt(convertYieldTokensToUnderlying(amount));
    }

    /// @inheritdoc IAlchemistV3State
    function convertDebtTokensToYield(uint256 amount) public view returns (uint256) {
        return convertUnderlyingTokensToYield(normalizeDebtTokensToUnderlying(amount));
    }

    /// @inheritdoc IAlchemistV3State
    function convertYieldTokensToUnderlying(uint256 amount) public view returns (uint256) {
        return IVaultV2(myt).convertToAssets(amount);
    }

    /// @inheritdoc IAlchemistV3State
    function convertUnderlyingTokensToYield(uint256 amount) public view returns (uint256) {
        return IVaultV2(myt).convertToShares(amount);
    }

    /// @inheritdoc IAlchemistV3State
    function normalizeUnderlyingTokensToDebt(uint256 amount) public view returns (uint256) {
        return amount * underlyingConversionFactor;
    }

    /// @inheritdoc IAlchemistV3State
    function normalizeDebtTokensToUnderlying(uint256 amount) public view returns (uint256) {
        return amount / underlyingConversionFactor;
    }

    /// @dev Mints debt tokens to `recipient` using the account owned by `tokenId`.
    /// @param tokenId     The tokenId of the account to mint from.
    /// @param amount    The amount to mint.
    /// @param recipient The recipient of the minted debt tokens.
    function _mint(uint256 tokenId, uint256 amount, address recipient) internal {
        if (block.number == _accounts[tokenId].lastRepayBlock) revert CannotMintOnRepayBlock();
        _addDebt(tokenId, amount);

        totalSyntheticsIssued += amount;

        // Validate the tokenId's account to assure that the collateralization invariant is still held.
        _validate(tokenId);

        _accounts[tokenId].lastMintBlock = block.number;

        // Mint the debt tokens to the recipient.
        TokenUtils.safeMint(debtToken, recipient, amount);

        emit Mint(tokenId, amount, recipient);
    }

    /**
     * @notice Force repays earmarked debt of the account owned by `accountId` using account's collateral balance.
     * @param accountId The tokenId of the account to repay from.
     * @param amount The amount to repay in debt tokens.
     * @return creditToYield The amount of yield tokens repaid.
     */

     function _forceRepay(uint256 accountId, uint256 amount, bool skipPoke) internal returns (uint256) {
        if (amount == 0) {
            return 0;
        }
        _checkForValidAccountId(accountId);
        if (!skipPoke) {
            _poke(accountId);
        }
        Account storage account = _accounts[accountId];
        uint256 debt;

        // Burning yieldTokens will pay off all types of debt
        _checkState((debt = account.debt) > 0);

        // earmarked debt always <= account debt
        uint256 credit = amount > debt ? debt : amount;
        // Repay debt from earmarked amount of debt first
        _subEarmarkedDebt(credit, accountId);
        _subDebt(accountId, credit);
        
        // sub the amount in yield tokens from collateral balance
        uint256 creditToYield = _subCollateralBalance(convertDebtTokensToYield(credit), accountId);

        // sub the protocol fee from collateral balance. collateral balance may be zero 
        uint256 targetProtocolFee = creditToYield * protocolFee / BPS;
        uint256 protocolFeeTotal = _subCollateralBalance(targetProtocolFee, accountId);


        emit ForceRepay(accountId, amount, creditToYield, protocolFeeTotal);

        if (creditToYield > 0) {
            // Transfer the repaid tokens from the account to the transmuter.
            TokenUtils.safeTransfer(myt, address(transmuter), creditToYield);
        }

        if (protocolFeeTotal > 0) {
            // Transfer the protocol fee to the protocol fee receiver
            TokenUtils.safeTransfer(myt, protocolFeeReceiver, protocolFeeTotal);
        }

        return creditToYield;
    }

    /// @inheritdoc IAlchemistV3Actions
    function selfLiquidate(uint256 accountId, address recipient) public returns (uint256 amountLiquidated) {
        _checkArgument(recipient != address(0));
        _checkForValidAccountId(accountId);
        _checkAccountOwnership(IAlchemistV3Position(alchemistPositionNFT).ownerOf(accountId), msg.sender);
        _poke(accountId);
        _checkState(_accounts[accountId].debt > 0);
        if (!_isAccountHealthy(accountId, false)) {
            // must use the regular liquidation path i.e. liquidate(accountId)
           revert AccountNotHealthy();
        }
        Account storage account = _accounts[accountId];

        // Repay any earmarked debt 
        uint256 repaidEarmarkedDebtInYield = _forceRepay(accountId, account.earmarked, true);
    
        uint256 debt = account.debt;

        // then clear all remaining debt
        _subDebt(accountId, debt);

        // sub the collateral used for repaying debt
        uint256 repaidDebtInYield = _subCollateralBalance(convertDebtTokensToYield(debt), accountId);

        // clear all remaining collateral
        uint256 remainingCollateral = _subCollateralBalance(account.collateralBalance, accountId);

        if(repaidDebtInYield > 0) {
            // transfer collateral used for repaying debt to transmuter
            TokenUtils.safeTransfer(myt, transmuter, repaidDebtInYield);
        }

        if(remainingCollateral > 0) {
            // transfer remaining collateral to the recipient
            TokenUtils.safeTransfer(myt, recipient, remainingCollateral);
        }   
        // emit event
        emit SelfLiquidated(accountId, repaidEarmarkedDebtInYield + repaidDebtInYield);
        return repaidEarmarkedDebtInYield + repaidDebtInYield;
    }

    /// @dev Subtracts the earmarked debt by `amount` for the account owned by `accountId`.
    /// @param amountInDebtTokens The amount of debt tokens to subtract from the earmarked debt.
    /// @param accountId The tokenId of the account to subtract the earmarked debt from.
    /// @return The amount of debt tokens subtracted from the earmarked debt.
    function _subEarmarkedDebt(uint256 amountInDebtTokens, uint256 accountId) internal returns (uint256) {
        Account storage account = _accounts[accountId];
        uint256 earmarkedDebt = account.earmarked;
        uint256 debt = account.debt;

        uint256 credit = amountInDebtTokens > debt ? debt : amountInDebtTokens;
        uint256 earmarkToRemove = credit > earmarkedDebt ? earmarkedDebt : credit;
        account.earmarked -= earmarkToRemove;

        uint256 earmarkPaidGlobal = cumulativeEarmarked > earmarkToRemove ? earmarkToRemove : cumulativeEarmarked;
        cumulativeEarmarked -= earmarkPaidGlobal;     
        return earmarkToRemove;
    }


    /// @dev Subtracts the collateral balance by `amount` for the account owned by `accountId`.
    /// @param amountInYieldTokens The amount of yield tokens to subtract from the collateral balance.
    /// @param accountId The tokenId of the account to subtract the collateral balance from.
    /// @return The amount of yield tokens subtracted from the collateral balance.
    function _subCollateralBalance(uint256 amountInYieldTokens, uint256 accountId) internal returns (uint256) {
        Account storage account = _accounts[accountId];
        uint256 collateralBalance = account.collateralBalance;
        uint256 amountToRemove = amountInYieldTokens > collateralBalance ? collateralBalance : amountInYieldTokens;
        account.collateralBalance -= amountToRemove;
        _mytSharesDeposited -= amountToRemove;
        return amountToRemove;
    }

    /// @dev Fetches and applies the liquidation amount to account `tokenId` if the account collateral ratio touches `collateralizationLowerBound`.
    /// @dev Repays earmarked debt if it exists
    /// @dev If earmarked repayment restores account to healthy collateralization, no liquidation is performed. Caller receives a repayment fee.
    /// @param accountId  The tokenId of the account to to liquidate.
    /// @return amountLiquidated  The amount (in yield tokens) removed from the account `tokenId`.
    /// @return feeInYield The additional fee as a % of the liquidation amount to be sent to the liquidator
    /// @return feeInUnderlying The additional fee as a % of the liquidation amount, denominated in underlying token, to be sent to the liquidator
    function _liquidate(uint256 accountId) internal returns (uint256 amountLiquidated, uint256 feeInYield, uint256 feeInUnderlying) {
        // Query transmuter and earmark global debt
        _earmark();
        // Sync current user debt before deciding how much needs to be liquidated
        _sync(accountId);

        Account storage account = _accounts[accountId];

        // In the rare scenario where 1 share is worth 0 underlying asset
        if (IVaultV2(myt).convertToAssets(1e18) == 0) {
            return (0, 0, 0);
        }
       
        if (_isAccountHealthy(accountId, false)) {
            return (0, 0, 0);
        }

        // Try to repay earmarked debt if it exists
        uint256 repaidAmountInYield = 0;
        if (account.earmarked > 0) {
            repaidAmountInYield = _forceRepay(accountId, account.earmarked, false);
            (feeInYield, feeInUnderlying) = _resolveRepaymentFee(accountId, repaidAmountInYield);
            // Final safety check after all deductions
            if (account.collateralBalance == 0 && account.debt > 0) {
                _subDebt(accountId, account.debt);
            }
        }

        // Recalculate ratio after any repayment to determine if further liquidation is needed
        if (_isAccountHealthy(accountId, false)) {

            if (feeInYield > 0) {
                TokenUtils.safeTransfer(myt, msg.sender, feeInYield);
            } else if (feeInUnderlying > 0) {
                feeInUnderlying = _payWithFeeVault(feeInUnderlying);
            }
            emit RepaymentFee(accountId, msg.sender, feeInYield, feeInUnderlying);
            return (repaidAmountInYield, feeInYield, feeInUnderlying);
        } else {
            // Do actual liquidation
            return _doLiquidation(accountId);
        }

    }

    /// @dev Pays the fee to msg.sender in underlying tokens using the fee vault
    /// @param amountInUnderlying The amount of underlying tokens to pay
    /// @return actual amount paid based on the vault balance
    function _payWithFeeVault(uint256 amountInUnderlying) internal returns (uint256) {
        uint256 vaultBalance = IFeeVault(alchemistFeeVault).totalDeposits();
        if (vaultBalance > 0) {
            uint256 adjustedAmount = amountInUnderlying > vaultBalance ? vaultBalance : amountInUnderlying;
            IFeeVault(alchemistFeeVault).withdraw(msg.sender, adjustedAmount);
            return adjustedAmount;
        }
        return 0;
    }

    /// @dev Checks if the account is healthy
    /// @dev An account is healthy if its collateralization ratio is greater than the collateralization lower bound
    /// @dev An account is healthy if it has no debt
    /// @param accountId The tokenId of the account to check.
    /// @param refresh Whether to refresh the account's collateral value by including unrealized debt.
    /// @return true if the account is healthy, false otherwise.
    function _isAccountHealthy(uint256 accountId, bool refresh) internal view returns (bool) {
        if (_accounts[accountId].debt == 0) {
            return true;
        }
        uint256 collateralInUnderlying = _totalCollateralValue(accountId, refresh);
        uint256 collateralizationRatio = collateralInUnderlying * FIXED_POINT_SCALAR / _accounts[accountId].debt;
        return collateralizationRatio > collateralizationLowerBound;
    }

    /// @dev Performs the actual liquidation logic when collateralization is below the lower bound
    /// @param accountId The tokenId of the account to to liquidate.
    /// @return amountLiquidated The amount of yield tokens liquidated.
    /// @return feeInYield The fee in yield tokens to be sent to the liquidator.
    /// @return feeInUnderlying The fee in underlying tokens to be sent to the liquidator.
    function _doLiquidation(uint256 accountId)
        internal
        returns (uint256 amountLiquidated, uint256 feeInYield, uint256 feeInUnderlying)
    {
        Account storage account = _accounts[accountId];
        uint256 debt = account.debt;
        uint256 collateralInUnderlying = totalValue(accountId);
        (uint256 liquidationAmount, uint256 debtToBurn, uint256 baseFee, uint256 outsourcedFee) = calculateLiquidation(
            collateralInUnderlying,
            debt,
            minimumCollateralization,
            normalizeUnderlyingTokensToDebt(_getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / totalDebt,
            globalMinimumCollateralization,
            liquidatorFee
        );

        if(liquidationAmount == 0) {
            return (0, 0, 0);
        }

        amountLiquidated = convertDebtTokensToYield(liquidationAmount) > account.collateralBalance ? account.collateralBalance : convertDebtTokensToYield(liquidationAmount);
        feeInYield = convertDebtTokensToYield(baseFee);
        // update user balance and debt
        _subCollateralBalance(amountLiquidated, accountId);
        _subDebt(accountId, debtToBurn);

        // send liquidation amount - fee to transmuter
        TokenUtils.safeTransfer(myt, transmuter, amountLiquidated - feeInYield);

        // send base fee to liquidator if available
        if (feeInYield > 0) {
            TokenUtils.safeTransfer(myt, msg.sender, feeInYield);
        } else if (normalizeDebtTokensToUnderlying(outsourcedFee) > 0) {
            // Handle outsourced fee from vault
            feeInUnderlying = _payWithFeeVault(normalizeDebtTokensToUnderlying(outsourcedFee));
        }
        emit Liquidated(accountId, msg.sender, amountLiquidated, feeInYield, feeInUnderlying);
        return (amountLiquidated, feeInYield, feeInUnderlying);
    }

    /// @dev Handles repayment fee calculation and account deduction
    /// @param accountId The tokenId of the account to force a repayment on.
    /// @param repaidAmountInYield The amount of debt repaid in yield tokens.
    /// @return feeInYield The fee in yield tokens to be sent to the liquidator.
    /// @return feeInUnderlying The fee in underlying tokens to be sent to the liquidator.
    function _resolveRepaymentFee(uint256 accountId, uint256 repaidAmountInYield) internal returns (uint256 feeInYield, uint256 feeInUnderlying) {
        Account storage account = _accounts[accountId];
        uint256 debtInYield = convertDebtTokensToYield(account.debt);
        uint256 surplus = account.collateralBalance > debtInYield ? account.collateralBalance - debtInYield : 0;
        if(surplus > 0){
            // calculate repayment fee and deduct from account
            uint256 targetFee = surplus * repaymentFee / BPS;
            feeInYield = _subCollateralBalance(targetFee, accountId);
        } else {
            uint256 targetFee = repaidAmountInYield * repaymentFee / BPS;
            feeInUnderlying = convertYieldTokensToUnderlying(targetFee);
        }
        return (feeInYield, feeInUnderlying);
    }

    /// @dev Increases the debt by `amount` for the account owned by `tokenId`.
    ///
    /// @param tokenId   The account owned by tokenId.
    /// @param amount  The amount to increase the debt by.
    function _addDebt(uint256 tokenId, uint256 amount) internal {
        Account storage account = _accounts[tokenId];

        // Update collateral variables
        uint256 toLock = convertDebtTokensToYield(amount) * minimumCollateralization / FIXED_POINT_SCALAR;
        uint256 lockedCollateral = convertDebtTokensToYield(account.debt) * minimumCollateralization / FIXED_POINT_SCALAR;

        if (account.collateralBalance < lockedCollateral + toLock) revert Undercollateralized();

        account.debt += amount;
        totalDebt += amount;
    }

    /// @dev Subtracts the debt by `amount` for the account owned by `tokenId`.
    ///
    /// @param tokenId   The account owned by tokenId.
    /// @param amount  The amount to decrease the debt by.
    function _subDebt(uint256 tokenId, uint256 amount) internal {
        Account storage account = _accounts[tokenId];

        account.debt -= amount;
        totalDebt -= amount;

        // Clamp to avoid underflow due to rounding later at a later time
        if (cumulativeEarmarked > totalDebt) {
            cumulativeEarmarked = totalDebt;
        }
    }

    /// @dev Set the mint allowance for `spender` to `amount` for the account owned by `tokenId`.
    ///
    /// @param ownerTokenId   The id of the account granting approval.
    /// @param spender The address of the spender.
    /// @param amount  The amount of debt tokens to set the mint allowance to.
    function _approveMint(uint256 ownerTokenId, address spender, uint256 amount) internal {
        Account storage account = _accounts[ownerTokenId];
        account.mintAllowances[account.allowancesVersion][spender] = amount;
        emit ApproveMint(ownerTokenId, spender, amount);
    }

    /// @dev Decrease the mint allowance for `spender` by `amount` for the account owned by `ownerTokenId`.
    ///
    /// @param ownerTokenId The id of the account owner.
    /// @param spender The address of the spender.
    /// @param amount  The amount of debt tokens to decrease the mint allowance by.
    function _decreaseMintAllowance(uint256 ownerTokenId, address spender, uint256 amount) internal {
        Account storage account = _accounts[ownerTokenId];
        account.mintAllowances[account.allowancesVersion][spender] -= amount;
    }

    /// @dev Checks an expression and reverts with an {IllegalArgument} error if the expression is {false}.
    ///
    /// @param expression The expression to check.
    function _checkArgument(bool expression) internal pure {
        if (!expression) {
            revert IllegalArgument();
        }
    }

    /// @dev Checks if owner == sender and reverts with an {UnauthorizedAccountAccessError} error if the result is {false}.
    ///
    /// @param owner The address of the owner of an account.
    /// @param user The address of the user attempting to access an account.
    function _checkAccountOwnership(address owner, address user) internal pure {
        if (owner != user) {
            revert UnauthorizedAccountAccessError();
        }
    }

    /// @dev reverts {UnknownAccountOwnerIDError} error by if no owner exists.
    ///
    /// @param tokenId The id of an account.
    function _checkForValidAccountId(uint256 tokenId) internal view {
        if (!_tokenExists(alchemistPositionNFT, tokenId)) {
            revert UnknownAccountOwnerIDError();
        }
    }

    /**
     * @notice Checks whether a token id is linked to an owner. Non blocking / no reverts.
     * @param nft The address of the ERC721 based contract.
     * @param tokenId The token id to check.
     * @return exists A boolean that is true if the token exists.
     */
    function _tokenExists(address nft, uint256 tokenId) internal view returns (bool exists) {
        if (tokenId == 0) {
            // token ids start from 1
            return false;
        }
        try IERC721(nft).ownerOf(tokenId) {
            // If the call succeeds, the token exists.
            exists = true;
        } catch {
            // If the call fails, then the token does not exist.
            exists = false;
        }
    }

    /// @dev Checks an expression and reverts with an {IllegalState} error if the expression is {false}.
    ///
    /// @param expression The expression to check.
    function _checkState(bool expression) internal pure {
        if (!expression) {
            revert IllegalState();
        }
    }

    /// @dev Checks that the account owned by `tokenId` is properly collateralized.
    /// @dev If the account is undercollateralized then this will revert with an {Undercollateralized} error.
    ///
    /// @param tokenId The id of the account owner.
    function _validate(uint256 tokenId) internal view {
        if (_isUnderCollateralized(tokenId)) revert Undercollateralized();
    }


    /// @dev Calculate the total collateral value of the account in debt tokens.
    /// @param tokenId The id of the account owner.
    /// @return The total collateral value of the account in debt tokens.
    function _totalCollateralValue(uint256 tokenId, bool includeUnrealizedDebt) internal view returns (uint256) {
        uint256 totalUnderlying;
        if (includeUnrealizedDebt) {
            (,, uint256 collateral) = _calculateUnrealizedDebt(tokenId);
            if (collateral > 0) totalUnderlying += convertYieldTokensToUnderlying(collateral);
        } else {
            totalUnderlying = convertYieldTokensToUnderlying(_accounts[tokenId].collateralBalance);
        }
        return normalizeUnderlyingTokensToDebt(totalUnderlying);
    }

    /// @dev Update the user's earmarked and redeemed debt amounts.
    function _sync(uint256 tokenId) internal {
        Account storage account = _accounts[tokenId];

        // Survival during current sync window
        uint256 survivalRatio = _redemptionSurvivalRatio(account.lastAccruedRedemptionWeight, _redemptionWeight);

        // User exposure at last sync used to calculate newly earmarked debt pre redemption
        uint256 userExposure = account.debt > account.earmarked ? account.debt - account.earmarked : 0;
        uint256 earmarkRaw = PositionDecay.ScaleByWeightDelta(userExposure, _earmarkWeight - account.lastAccruedEarmarkWeight);

        // Earmark survival at last sync
        // Survival is the amount of unearmarked debt left after an earmark
        uint256 earmarkSurvival = PositionDecay.SurvivalFromWeight(account.lastAccruedEarmarkWeight);
        if (earmarkSurvival == 0) earmarkSurvival = ONE_Q128;
        // Decay snapshot by what was redeemed from last sync until now
        uint256 decayedRedeemed = FixedPointMath.mulQ128(account.lastSurvivalAccumulator, survivalRatio);
        // What was added to the survival accumulator in the current sync window
        uint256 survivalDiff = _survivalAccumulator > decayedRedeemed ? _survivalAccumulator - decayedRedeemed : 0;

        // Unwind accumulated earmarked at last sync
        uint256 unredeemedRatio = FixedPointMath.divQ128(survivalDiff, earmarkSurvival);
        // Portion of earmark that remains after applying the redemption. Scaled back from 128.128
        uint256 earmarkedUnredeemed = FixedPointMath.mulQ128(userExposure, unredeemedRatio);
        if (earmarkedUnredeemed > earmarkRaw) earmarkedUnredeemed = earmarkRaw;

        // Old earmarks that survived redemptions in the current sync window
        uint256 exposureSurvival = FixedPointMath.mulQ128(account.earmarked, survivalRatio);
        // What was redeemed from the newly earmark between last sync and now
        uint256 redeemedFromEarmarked = earmarkRaw - earmarkedUnredeemed;
        // Total overall earmarked to adjust user debt
        uint256 redeemedTotal = (account.earmarked - exposureSurvival) + redeemedFromEarmarked;

        // Calculate collateral to remove
        uint256 globalDebtDelta = _totalRedeemedDebt - account.lastTotalRedeemedDebt;
        if (globalDebtDelta != 0 && redeemedTotal != 0) {
            uint256 globalSharesDelta = _totalRedeemedSharesOut - account.lastTotalRedeemedSharesOut;

            // sharesToDebit = redeemedTotal * globalSharesDelta / globalDebtDelta
            uint256 sharesToDebit = FixedPointMath.mulDivUp(redeemedTotal, globalSharesDelta, globalDebtDelta);

            if (sharesToDebit > account.collateralBalance) sharesToDebit = account.collateralBalance;
            account.collateralBalance -= sharesToDebit;
        }

        // advance checkpoints even if redeemedTotal==0
        account.lastTotalRedeemedDebt = _totalRedeemedDebt;
        account.lastTotalRedeemedSharesOut = _totalRedeemedSharesOut;

        account.earmarked = exposureSurvival + earmarkedUnredeemed;
        account.debt = account.debt >= redeemedTotal ? account.debt - redeemedTotal : 0;

        // Advance account checkpoint
        account.lastAccruedEarmarkWeight = _earmarkWeight;
        account.lastAccruedRedemptionWeight = _redemptionWeight;

        // Snapshot G for this account
        account.lastSurvivalAccumulator = _survivalAccumulator;
    }

    /// @dev Earmarks the debt for redemption.
    function _earmark() internal {
        if (totalDebt == 0) return;
        if (block.number <= lastEarmarkBlock) return;

        // update pending cover shares based on transmuter balance delta
        uint256 transmuterBalance = TokenUtils.safeBalanceOf(myt, address(transmuter));

        if (transmuterBalance > lastTransmuterTokenBalance) {
            _pendingCoverShares += (transmuterBalance - lastTransmuterTokenBalance);
        }

        lastTransmuterTokenBalance = transmuterBalance;

        // how to earmark this window
        uint256 amount = ITransmuter(transmuter).queryGraph(lastEarmarkBlock + 1, block.number);

        // apply cover 
        uint256 coverInDebt = convertYieldTokensToDebt(_pendingCoverShares);
        if (amount != 0 && coverInDebt != 0) {
            uint256 usedDebt = amount > coverInDebt ? coverInDebt : amount;
            amount -= usedDebt;

            // consume the corresponding portion of pending cover shares so we can't reuse it
            uint256 sharesUsed = FixedPointMath.mulDivUp(_pendingCoverShares, usedDebt, coverInDebt);
            if (sharesUsed > _pendingCoverShares) sharesUsed = _pendingCoverShares;
            _pendingCoverShares -= sharesUsed;
        }

        uint256 liveUnearmarked = totalDebt - cumulativeEarmarked;
        if (amount > liveUnearmarked) amount = liveUnearmarked;

        if (amount > 0 && liveUnearmarked != 0) {
            // Previous earmark survival
            uint256 previousSurvival = PositionDecay.SurvivalFromWeight(_earmarkWeight);
            if (previousSurvival == 0) previousSurvival = ONE_Q128;

            // Fraction of unearmarked debt being earmarked now in UQ128.128
            uint256 earmarkedFraction = FixedPointMath.divQ128(amount, liveUnearmarked);

            _survivalAccumulator += FixedPointMath.mulQ128(previousSurvival, earmarkedFraction);
            _earmarkWeight += PositionDecay.WeightIncrement(amount, liveUnearmarked);

            cumulativeEarmarked += amount;
        }

        lastEarmarkBlock = block.number;
    }

    /// @dev Gets the amount of debt that the account owned by `owner` will have after a sync occurs.
    ///
    /// @param tokenId The id of the account owner.
    ///
    /// @return The amount of debt that the account owned by `owner` will have after an update.
    /// @return The amount of debt which is currently earmarked fro redemption.
    /// @return The amount of collateral that has yet to be redeemed.
    function _calculateUnrealizedDebt(uint256 tokenId)
        internal
        view
        returns (uint256, uint256, uint256)
    {
        Account storage account = _accounts[tokenId];

        // Local copies
        uint256 earmarkWeightCopy = _earmarkWeight;
        uint256 survivalAccumulatorCopy   = _survivalAccumulator;

        // Simulate earmark since lastEarmarkBlock
        if (block.number > lastEarmarkBlock) {
            // update pending cover shares based on transmuter balance delta
            uint256 transmuterBalance = TokenUtils.safeBalanceOf(myt, address(transmuter));
            uint256 pendingCoverSharesCopy = _pendingCoverShares;

            if (transmuterBalance > lastTransmuterTokenBalance) {
                pendingCoverSharesCopy += (transmuterBalance - lastTransmuterTokenBalance);
            }

            // how much to earmark this window
            uint256 amount = ITransmuter(transmuter).queryGraph(lastEarmarkBlock + 1, block.number);

            // apply cover 
            uint256 coverInDebt = convertYieldTokensToDebt(pendingCoverSharesCopy);
            if (amount != 0 && coverInDebt != 0) {
                uint256 usedDebt = amount > coverInDebt ? coverInDebt : amount;
                amount -= usedDebt;

                // consume the corresponding portion of pending cover shares so we can't reuse it
                uint256 sharesUsed = FixedPointMath.mulDivUp(pendingCoverSharesCopy, usedDebt, coverInDebt);
                if (sharesUsed > pendingCoverSharesCopy) sharesUsed = pendingCoverSharesCopy;
                pendingCoverSharesCopy -= sharesUsed;
            }

            uint256 liveUnearmarked = totalDebt - cumulativeEarmarked;
            if (amount > liveUnearmarked) amount = liveUnearmarked;

            if (amount > 0 && liveUnearmarked != 0) {
                // Previous earmark survival
                uint256 previousSurvival = PositionDecay.SurvivalFromWeight(earmarkWeightCopy);
                if (previousSurvival == 0) previousSurvival = ONE_Q128;

                // Fraction of unearmarked debt being earmarked now in UQ128.128
                uint256 earmarkedFraction = FixedPointMath.divQ128(amount, liveUnearmarked);

                survivalAccumulatorCopy += FixedPointMath.mulQ128(previousSurvival, earmarkedFraction);
                earmarkWeightCopy += PositionDecay.WeightIncrement(amount, liveUnearmarked);
            }
        }

        // Survival during current sync window
        uint256 survivalRatio = _redemptionSurvivalRatio(account.lastAccruedRedemptionWeight, _redemptionWeight);

        // User exposure at last sync used to calculate newly earmarked debt pre redemption
        uint256 userExposure = account.debt > account.earmarked ? account.debt - account.earmarked : 0;
        uint256 earmarkRaw = PositionDecay.ScaleByWeightDelta(userExposure, earmarkWeightCopy - account.lastAccruedEarmarkWeight);

        // Earmark survival at last sync
        // Survival is the amount of unearmarked debt left after an earmark
        uint256 earmarkSurvival = PositionDecay.SurvivalFromWeight(account.lastAccruedEarmarkWeight);
        if (earmarkSurvival == 0) earmarkSurvival = ONE_Q128;
        // Decay snapshot by what was redeemed from last sync until now
        uint256 decayedRedeemed = FixedPointMath.mulQ128(account.lastSurvivalAccumulator, survivalRatio);
        // What was added to the survival accumulator in the current sync window
        uint256 survivalDiff  = survivalAccumulatorCopy > decayedRedeemed ? survivalAccumulatorCopy - decayedRedeemed : 0;

        // Unwind accumulated earmarked at last sync
        uint256 unredeemedRatio = FixedPointMath.divQ128(survivalDiff, earmarkSurvival);
        // Portion of earmark that remains after applying the redemption. Scaled back from 128.128
        uint256 earmarkedUnredeemed = FixedPointMath.mulQ128(userExposure, unredeemedRatio);
        if (earmarkedUnredeemed > earmarkRaw) earmarkedUnredeemed = earmarkRaw;

        // Old earmarks that survived redemptions in the current sync window
        uint256 exposureSurvival = FixedPointMath.mulQ128(account.earmarked, survivalRatio);

        // What was redeemed from the newly earmark between last sync and now
        uint256 redeemedFromEarmarked = earmarkRaw - earmarkedUnredeemed;
        // Total overall earmarked to adjust user debt
        uint256 redeemedTotal = (account.earmarked - exposureSurvival) + redeemedFromEarmarked;

        uint256 newDebt = account.debt >= redeemedTotal ? account.debt - redeemedTotal : 0;
        uint256 redeemedTotalSim = account.debt > newDebt ? account.debt - newDebt : 0;
        uint256 newEarmarked = exposureSurvival + earmarkedUnredeemed;

        // Calculate collateral to remove from fees and redemptions
        uint256 collateralBalanceCopy = account.collateralBalance;
        uint256 globalDebtDelta = _totalRedeemedDebt - account.lastTotalRedeemedDebt;
        if (globalDebtDelta != 0 && redeemedTotalSim != 0) {
            uint256 globalSharesDelta = _totalRedeemedSharesOut - account.lastTotalRedeemedSharesOut;
            uint256 sharesToDebit = FixedPointMath.mulDivUp(redeemedTotalSim, globalSharesDelta, globalDebtDelta);
            if (sharesToDebit > collateralBalanceCopy) sharesToDebit = collateralBalanceCopy;
            collateralBalanceCopy -= sharesToDebit;
        }

        return (newDebt, newEarmarked, collateralBalanceCopy);
    }

    /// @dev Checks that the account owned by `tokenId` is properly collateralized.
    /// @dev Returns true only if the account is undercollateralized
    ///
    /// @param tokenId The id of the account owner.
    function _isUnderCollateralized(uint256 tokenId) internal view returns (bool) {
        uint256 debt = _accounts[tokenId].debt;
        if (debt == 0) return false;

        uint256 collateralization = FixedPointMath.mulDivUp(totalValue(tokenId), FIXED_POINT_SCALAR, debt);
        return collateralization < minimumCollateralization;
    }

    /// @dev Calculates the total value of the alchemist in the underlying token.
    /// @return totalUnderlyingValue The total value of the alchemist in the underlying token.
    function _getTotalUnderlyingValue() internal view returns (uint256 totalUnderlyingValue) {
        uint256 yieldTokenTVLInUnderlying = convertYieldTokensToUnderlying(_mytSharesDeposited);
        totalUnderlyingValue = yieldTokenTVLInUnderlying;
    }

    /// @dev Calculates the total value locked in the system from collateralization requirements
    function _getTotalLockedUnderlyingValue() internal view returns (uint256) {
        uint256 required = _requiredLockedShares();

        // Cap by actual shares held in the Alchemist
        uint256 held = _mytSharesDeposited;

        uint256 lockedShares = required > held ? held : required;
        return convertYieldTokensToUnderlying(lockedShares);
    }

    /// @dev Calculates locked collateral based on share price
    function _requiredLockedShares() internal view returns (uint256) {
        if (totalDebt == 0) return 0;

        uint256 debtShares = convertDebtTokensToYield(totalDebt);
        return FixedPointMath.mulDivUp(debtShares, minimumCollateralization, FIXED_POINT_SCALAR);
    }

    /// @dev Computes redemption survival ratio between two redemption weights.
    ///      Uses division when survivals are representable, and falls back to delta-weight
    ///      when SurvivalFromWeight() underflows to 0 for both endpoints.
    function _redemptionSurvivalRatio(uint256 oldWeight, uint256 newWeight) internal pure returns (uint256) {
        if (newWeight <= oldWeight) return ONE_Q128;
        return PositionDecay.SurvivalFromWeight(newWeight - oldWeight);
    }

    /// @inheritdoc IAlchemistV3State
    function calculateLiquidation(
        uint256 collateral,
        uint256 debt,
        uint256 targetCollateralization,
        uint256 alchemistCurrentCollateralization,
        uint256 alchemistMinimumCollateralization,
        uint256 feeBps
    ) public pure returns (uint256 grossCollateralToSeize, uint256 debtToBurn, uint256 fee, uint256 outsourcedFee) {
        if (debt >= collateral) {
            outsourcedFee = (debt * feeBps) / BPS;
            // fully liquidate debt if debt is greater than collateral
            return (collateral, debt, 0, outsourcedFee);
        }

        if (alchemistCurrentCollateralization < alchemistMinimumCollateralization) {
            outsourcedFee = (debt * feeBps) / BPS;
            // fully liquidate debt in high ltv global environment
            return (debt, debt, 0, outsourcedFee);
        }

        // fee is taken from surplus = collateral - debt
        uint256 surplus = collateral > debt ? collateral - debt : 0;

        fee = (surplus * feeBps) / BPS;

        // collateral remaining for margin‐restore calc
        uint256 adjCollat = collateral - fee;
        // compute m*d  (both plain units)
        uint256 md = (targetCollateralization * debt) / FIXED_POINT_SCALAR;
        // if md <= adjCollat, nothing to liquidate
        if (md <= adjCollat) {
            return (0, 0, 0, 0);
        }

        // numerator = md - adjCollat
        uint256 num = md - adjCollat;

        // denom = m - 1  =>  (targetCollateralization - FIXED_POINT_SCALAR)/FIXED_POINT_SCALAR
        uint256 denom = targetCollateralization - FIXED_POINT_SCALAR;

        debtToBurn = (num * FIXED_POINT_SCALAR) / denom;

        // gross collateral seize = net + fee
        grossCollateralToSeize = debtToBurn + fee;
    }
}