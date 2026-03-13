// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IAlchemistV3} from "../interfaces/IAlchemistV3.sol";
import {IAlchemistV3Position} from "../interfaces/IAlchemistV3Position.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {IVaultV2} from "../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {ITransmuter} from "../interfaces/ITransmuter.sol";

/// @title  AlchemistRouter
/// @notice Batches wrap + deposit + borrow into a single transaction for EOA users.
/// @dev    Stateless — never holds tokens or NFTs between transactions.
///         Uses before/after balance check to identify the newly minted NFT,
///         immune to donation griefing.
contract AlchemistRouter is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @dev Flag to allow receiving ETH from WETH unwrap during withdraw flows.
    bool private transient _ethExpected;

    /// @notice Deposit underlying token into MYT vault + Alchemist, optionally borrow.
    /// @dev    Caller must have approved this contract for `amount` of underlying.
    ///         Pass `tokenId = 0` to create a new position, or an existing token ID to deposit into it.
    ///         For existing positions: caller must own the NFT (it stays with the caller).
    ///         If `borrowAmount` > 0 on an existing position, caller must have called
    ///         `approveMint(tokenId, router, borrowAmount)` on the Alchemist.
    /// @param  alchemist     The Alchemist contract address.
    /// @param  tokenId       Position NFT token ID (0 to create a new position).
    /// @param  amount        Amount of underlying token to deposit.
    /// @param  borrowAmount  Amount of debt tokens to borrow (0 to skip borrowing).
    /// @param  minSharesOut  Minimum MYT shares to receive (slippage protection).
    /// @param  deadline      Timestamp after which the transaction reverts.
    /// @return                The position NFT token ID (newly minted or same as input).
    function depositUnderlying(
        address alchemist,
        uint256 tokenId,
        uint256 amount,
        uint256 borrowAmount,
        uint256 minSharesOut,
        uint256 deadline
    ) external nonReentrant returns (uint256) {
        require(block.timestamp <= deadline, "Expired");
        require(amount > 0, "Zero amount");

        address mytVault = IAlchemistV3(alchemist).myt();
        address underlying = IAlchemistV3(alchemist).underlyingToken();

        IERC20(underlying).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(underlying).forceApprove(mytVault, amount);

        uint256 shares = IVaultV2(mytVault).deposit(amount, address(this));
        require(shares >= minSharesOut, "Slippage");

        IERC20(underlying).forceApprove(mytVault, 0);

        return _depositAndBorrow(alchemist, mytVault, shares, tokenId, borrowAmount);
    }

    /// @notice Deposit native ETH → WETH → MYT vault → Alchemist, optionally borrow.
    /// @dev    WETH address is derived from alchemist.underlyingToken().
    ///         Pass `tokenId = 0` to create a new position, or an existing token ID to deposit into it.
    ///         For existing positions: caller must own the NFT (it stays with the caller).
    ///         If `borrowAmount` > 0 on an existing position, caller must have called
    ///         `approveMint(tokenId, router, borrowAmount)` on the Alchemist.
    /// @param  alchemist     The Alchemist contract address.
    /// @param  tokenId       Position NFT token ID (0 to create a new position).
    /// @param  borrowAmount  Amount of debt tokens to borrow (0 to skip borrowing).
    /// @param  minSharesOut  Minimum MYT shares to receive (slippage protection).
    /// @param  deadline      Timestamp after which the transaction reverts.
    /// @return                The position NFT token ID (newly minted or same as input).
    function depositETH(
        address alchemist,
        uint256 tokenId,
        uint256 borrowAmount,
        uint256 minSharesOut,
        uint256 deadline
    ) external payable nonReentrant returns (uint256) {
        require(msg.value > 0, "No ETH sent");
        require(block.timestamp <= deadline, "Expired");

        address mytVault = IAlchemistV3(alchemist).myt();
        address underlying = IAlchemistV3(alchemist).underlyingToken();

        IWETH(underlying).deposit{value: msg.value}();
        IERC20(underlying).forceApprove(mytVault, msg.value);

        uint256 shares = IVaultV2(mytVault).deposit(msg.value, address(this));
        require(shares >= minSharesOut, "Slippage");

        IERC20(underlying).forceApprove(mytVault, 0);

        return _depositAndBorrow(alchemist, mytVault, shares, tokenId, borrowAmount);
    }

    /// @notice Deposit MYT shares directly into Alchemist, optionally borrow.
    /// @dev    Caller must have approved this contract for `shares` of MYT.
    ///         Pass `tokenId = 0` to create a new position, or an existing token ID to deposit into it.
    ///         For existing positions: caller must own the NFT (it stays with the caller).
    ///         If `borrowAmount` > 0 on an existing position, caller must have called
    ///         `approveMint(tokenId, router, borrowAmount)` on the Alchemist.
    /// @param  alchemist     The Alchemist contract address.
    /// @param  tokenId       Position NFT token ID (0 to create a new position).
    /// @param  shares        Amount of MYT shares to deposit.
    /// @param  borrowAmount  Amount of debt tokens to borrow (0 to skip borrowing).
    /// @param  deadline      Timestamp after which the transaction reverts.
    /// @return                The position NFT token ID (newly minted or same as input).
    function depositMYT(
        address alchemist,
        uint256 tokenId,
        uint256 shares,
        uint256 borrowAmount,
        uint256 deadline
    ) external nonReentrant returns (uint256) {
        require(block.timestamp <= deadline, "Expired");
        require(shares > 0, "Zero shares");

        address mytVault = IAlchemistV3(alchemist).myt();

        IERC20(mytVault).safeTransferFrom(msg.sender, address(this), shares);

        return _depositAndBorrow(alchemist, mytVault, shares, tokenId, borrowAmount);
    }

    /// @notice Deposit ETH into MYT vault only (no Alchemist position).
    ///         MYT shares are sent directly to the caller.
    /// @dev    WETH address is derived from alchemist.underlyingToken().
    /// @param  alchemist     The Alchemist contract (used to resolve MYT vault + underlying).
    /// @param  minSharesOut  Minimum MYT shares to receive (slippage protection).
    /// @param  deadline      Timestamp after which the transaction reverts.
    /// @return shares        MYT shares received.
    function depositETHToVaultOnly(
        address alchemist,
        uint256 minSharesOut,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 shares) {
        require(msg.value > 0, "No ETH sent");
        require(block.timestamp <= deadline, "Expired");

        address mytVault = IAlchemistV3(alchemist).myt();
        address underlying = IAlchemistV3(alchemist).underlyingToken();

        IWETH(underlying).deposit{value: msg.value}();
        IERC20(underlying).forceApprove(mytVault, msg.value);
        shares = IVaultV2(mytVault).deposit(msg.value, msg.sender);
        require(shares >= minSharesOut, "Slippage");

        // Clear residual approval
        IERC20(underlying).forceApprove(mytVault, 0);
    }

    // ─── Repay ───────────────────────────────────────────────────────────

    /// @notice Repay debt on a position using underlying tokens.
    /// @dev    Caller must have approved this contract for `amount` of underlying.
    ///         Any MYT shares not consumed by the repayment are returned to the caller.
    /// @param  alchemist         The Alchemist contract address.
    /// @param  recipientTokenId  The position NFT token ID to repay debt on.
    /// @param  amount            Amount of underlying token to use for repayment.
    /// @param  minSharesOut      Minimum MYT shares from vault deposit (slippage protection).
    /// @param  deadline          Timestamp after which the transaction reverts.
    function repayUnderlying(
        address alchemist,
        uint256 recipientTokenId,
        uint256 amount,
        uint256 minSharesOut,
        uint256 deadline
    ) external nonReentrant {
        require(block.timestamp <= deadline, "Expired");
        require(amount > 0, "Zero amount");

        address mytVault = IAlchemistV3(alchemist).myt();
        address underlying = IAlchemistV3(alchemist).underlyingToken();

        IERC20(underlying).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(underlying).forceApprove(mytVault, amount);

        uint256 shares = IVaultV2(mytVault).deposit(amount, address(this));
        require(shares >= minSharesOut, "Slippage");

        IERC20(underlying).forceApprove(mytVault, 0);
        IERC20(mytVault).forceApprove(alchemist, shares);

        IAlchemistV3(alchemist).repay(shares, recipientTokenId);

        IERC20(mytVault).forceApprove(alchemist, 0);

        // Return any unused MYT shares (repay caps to outstanding debt)
        uint256 remaining = IERC20(mytVault).balanceOf(address(this));
        if (remaining > 0) {
            IERC20(mytVault).safeTransfer(msg.sender, remaining);
        }
    }

    /// @notice Repay debt on a position using native ETH.
    /// @dev    WETH address is derived from alchemist.underlyingToken().
    ///         Any MYT shares not consumed by the repayment are returned to the caller.
    /// @param  alchemist         The Alchemist contract address.
    /// @param  recipientTokenId  The position NFT token ID to repay debt on.
    /// @param  minSharesOut      Minimum MYT shares from vault deposit (slippage protection).
    /// @param  deadline          Timestamp after which the transaction reverts.
    function repayETH(
        address alchemist,
        uint256 recipientTokenId,
        uint256 minSharesOut,
        uint256 deadline
    ) external payable nonReentrant {
        require(msg.value > 0, "No ETH sent");
        require(block.timestamp <= deadline, "Expired");

        address mytVault = IAlchemistV3(alchemist).myt();
        address underlying = IAlchemistV3(alchemist).underlyingToken();

        IWETH(underlying).deposit{value: msg.value}();
        IERC20(underlying).forceApprove(mytVault, msg.value);

        uint256 shares = IVaultV2(mytVault).deposit(msg.value, address(this));
        require(shares >= minSharesOut, "Slippage");

        IERC20(underlying).forceApprove(mytVault, 0);
        IERC20(mytVault).forceApprove(alchemist, shares);

        IAlchemistV3(alchemist).repay(shares, recipientTokenId);

        IERC20(mytVault).forceApprove(alchemist, 0);

        // Return any unused MYT shares (repay caps to outstanding debt)
        uint256 remaining = IERC20(mytVault).balanceOf(address(this));
        if (remaining > 0) {
            IERC20(mytVault).safeTransfer(msg.sender, remaining);
        }
    }

    // ─── Withdraw ────────────────────────────────────────────────────────

    /// @notice Withdraw MYT shares from Alchemist, redeem to underlying, send to caller.
    /// @dev    Caller must approve this contract for the position NFT (ERC721 approve).
    ///         NFT is temporarily held by the router and returned after withdraw.
    ///         WARNING: The NFT round-trip resets ALL mint allowances (approveMint) on this position.
    /// @param  alchemist     The Alchemist contract address.
    /// @param  tokenId       The position NFT token ID to withdraw from.
    /// @param  shares        Amount of MYT shares to withdraw from the Alchemist.
    /// @param  minAmountOut  Minimum underlying tokens to receive (slippage protection on vault redeem).
    /// @param  deadline      Timestamp after which the transaction reverts.
    function withdrawUnderlying(
        address alchemist,
        uint256 tokenId,
        uint256 shares,
        uint256 minAmountOut,
        uint256 deadline
    ) external nonReentrant {
        require(block.timestamp <= deadline, "Expired");
        require(shares > 0, "Zero shares");

        IAlchemistV3Position nft = IAlchemistV3Position(IAlchemistV3(alchemist).alchemistPositionNFT());
        address mytVault = IAlchemistV3(alchemist).myt();

        // Take custody of position NFT (caller must have approved router)
        nft.transferFrom(msg.sender, address(this), tokenId);

        // Withdraw MYT shares from Alchemist to this contract
        IAlchemistV3(alchemist).withdraw(shares, address(this), tokenId);

        // Return NFT to caller
        nft.transferFrom(address(this), msg.sender, tokenId);

        // Redeem MYT shares → underlying, sent directly to caller
        uint256 assets = IVaultV2(mytVault).redeem(shares, msg.sender, address(this));
        require(assets >= minAmountOut, "Slippage");
    }

    /// @notice Withdraw MYT shares from Alchemist, redeem to WETH, unwrap, send ETH to caller.
    /// @dev    Caller must approve this contract for the position NFT (ERC721 approve).
    ///         NFT is temporarily held by the router and returned after withdraw.
    ///         WARNING: The NFT round-trip resets ALL mint allowances (approveMint) on this position.
    /// @param  alchemist     The Alchemist contract address.
    /// @param  tokenId       The position NFT token ID to withdraw from.
    /// @param  shares        Amount of MYT shares to withdraw from the Alchemist.
    /// @param  minAmountOut  Minimum ETH to receive (slippage protection on vault redeem).
    /// @param  deadline      Timestamp after which the transaction reverts.
    function withdrawETH(
        address alchemist,
        uint256 tokenId,
        uint256 shares,
        uint256 minAmountOut,
        uint256 deadline
    ) external nonReentrant {
        require(block.timestamp <= deadline, "Expired");
        require(shares > 0, "Zero shares");

        IAlchemistV3Position nft = IAlchemistV3Position(IAlchemistV3(alchemist).alchemistPositionNFT());
        address mytVault = IAlchemistV3(alchemist).myt();
        address underlying = IAlchemistV3(alchemist).underlyingToken();

        // Take custody of position NFT (caller must have approved router)
        nft.transferFrom(msg.sender, address(this), tokenId);

        // Withdraw MYT shares from Alchemist to this contract
        IAlchemistV3(alchemist).withdraw(shares, address(this), tokenId);

        // Return NFT to caller
        nft.transferFrom(address(this), msg.sender, tokenId);

        // Redeem MYT shares → WETH to this contract
        uint256 assets = IVaultV2(mytVault).redeem(shares, address(this), address(this));
        require(assets >= minAmountOut, "Slippage");

        // Unwrap WETH → ETH and send to caller
        _ethExpected = true;
        IWETH(underlying).withdraw(assets);
        _ethExpected = false;
        (bool success, ) = msg.sender.call{value: assets}("");
        require(success, "ETH transfer failed");
    }

    // ─── Transmuter Claim ────────────────────────────────────────────────

    /// @notice Claim a matured transmuter position, redeem MYT shares, and send proceeds to caller.
    /// @dev    Caller must approve this contract for the transmuter position NFT (ERC721 approve).
    ///         The transmuter burns the NFT on claim. Any untransmuted synthetic tokens
    ///         are forwarded to the caller as-is.
    ///         When `unwrapETH` is true, redeemed WETH is unwrapped and sent as native ETH.
    /// @param  alchemist       The Alchemist contract address (used to resolve transmuter + MYT vault).
    /// @param  positionId      The transmuter position NFT token ID to claim.
    /// @param  minAmountOut    Minimum underlying tokens (or ETH if unwrapETH) to receive (slippage protection).
    /// @param  deadline        Timestamp after which the transaction reverts.
    /// @param  unwrapETH       If true, redeem to WETH and unwrap to native ETH before sending.
    function claimRedemption(
        address alchemist,
        uint256 positionId,
        uint256 minAmountOut,
        uint256 deadline,
        bool unwrapETH
    ) external nonReentrant {
        require(block.timestamp <= deadline, "Expired");
        _claimRedemption(alchemist, positionId, minAmountOut, unwrapETH);
    }

    // ─── Internal ────────────────────────────────────────────────────────

    /// @dev Unified deposit + optional borrow logic.
    ///      Assumes MYT shares are already in this contract.
    ///      When tokenId == 0: creates a new position (NFT minted to router, then transferred to caller).
    ///      When tokenId != 0: deposits into existing position (NFT stays with caller, uses mintFrom for borrowing).
    function _depositAndBorrow(
        address alchemist,
        address mytVault,
        uint256 shares,
        uint256 tokenId,
        uint256 borrowAmount
    ) internal returns (uint256) {
        IERC20(mytVault).forceApprove(alchemist, shares);

        IAlchemistV3Position nft = IAlchemistV3Position(IAlchemistV3(alchemist).alchemistPositionNFT());

        if (tokenId == 0) {
            // New position: deposit to this contract, discover minted NFT, transfer to caller
            uint256 balanceBefore = nft.balanceOf(address(this));

            IAlchemistV3(alchemist).deposit(shares, address(this), 0);
            IERC20(mytVault).forceApprove(alchemist, 0);

            uint256 balanceAfter = nft.balanceOf(address(this));
            require(balanceAfter == balanceBefore + 1, "No NFT minted");
            tokenId = nft.tokenOfOwnerByIndex(address(this), balanceAfter - 1);

            if (borrowAmount > 0) {
                IAlchemistV3(alchemist).mint(tokenId, borrowAmount, msg.sender);
            }

            nft.transferFrom(address(this), msg.sender, tokenId);
        } else {
            // Existing position: deposit to caller (NFT owner), borrow via mintFrom
            require(nft.ownerOf(tokenId) == msg.sender, "Not position owner");

            IAlchemistV3(alchemist).deposit(shares, msg.sender, tokenId);
            IERC20(mytVault).forceApprove(alchemist, 0);

            if (borrowAmount > 0) {
                IAlchemistV3(alchemist).mintFrom(tokenId, borrowAmount, msg.sender);
            }
        }

        return tokenId;
    }

    /// @dev Shared claim logic: takes transmuter NFT, claims, forwards synthetic refund, redeems MYT.
    ///      When unwrapETH is true, redeems MYT → WETH → unwrap → send native ETH to caller.
    ///      When unwrapETH is false, redeems MYT → underlying sent directly to caller.
    function _claimRedemption(
        address alchemist,
        uint256 positionId,
        uint256 minAmountOut,
        bool unwrapETH
    ) internal {
        address transmuter = IAlchemistV3(alchemist).transmuter();
        address mytVault = IAlchemistV3(alchemist).myt();
        address syntheticToken = IAlchemistV3(alchemist).debtToken();

        // Take custody of transmuter NFT (caller must have approved router)
        IERC721(transmuter).transferFrom(msg.sender, address(this), positionId);

        // Claim — transmuter burns the NFT, sends MYT shares + synthetic refund to this contract
        ITransmuter(transmuter).claimRedemption(positionId);

        // Redeem MYT shares
        uint256 mytBalance = IERC20(mytVault).balanceOf(address(this));
        require(mytBalance > 0, "No MYT to redeem");

        if (unwrapETH) {
            address underlying = IAlchemistV3(alchemist).underlyingToken();
            uint256 assets = IVaultV2(mytVault).redeem(mytBalance, address(this), address(this));
            require(assets >= minAmountOut, "Slippage");

            _ethExpected = true;
            IWETH(underlying).withdraw(assets);
            _ethExpected = false;
            (bool success, ) = msg.sender.call{value: assets}("");
            require(success, "ETH transfer failed");
        } else {
            uint256 assets = IVaultV2(mytVault).redeem(mytBalance, msg.sender, address(this));
            require(assets >= minAmountOut, "Slippage");
        }

        // Forward any returned synthetic tokens to caller
        uint256 synthBalance = IERC20(syntheticToken).balanceOf(address(this));
        if (synthBalance > 0) {
            IERC20(syntheticToken).safeTransfer(msg.sender, synthBalance);
        }
    }

    /// @dev Accept ETH only from WETH unwrap during withdraw flows.
    receive() external payable {
        require(_ethExpected, "Use depositETH");
    }
}
