// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAlchemistV3} from "../interfaces/IAlchemistV3.sol";
import {IAlchemistV3Position} from "../interfaces/IAlchemistV3Position.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {IVaultV2} from "../../lib/vault-v2/src/interfaces/IVaultV2.sol";

/// @title  AlchemistRouter
/// @notice Batches wrap + deposit + borrow into a single transaction for EOA users.
/// @dev    Stateless — never holds tokens or NFTs between transactions.
///         Uses before/after balance check to identify the newly minted NFT,
///         immune to donation griefing.
contract AlchemistRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Flag to allow receiving ETH from WETH unwrap during withdraw flows.
    bool private _ethExpected;

    /// @notice Deposit underlying token into MYT vault + Alchemist, optionally borrow.
    /// @dev    Caller must have approved this contract for `amount` of underlying.
    /// @param  alchemist     The Alchemist contract address.
    /// @param  amount        Amount of underlying token to deposit.
    /// @param  borrowAmount  Amount of debt tokens to borrow (0 to skip borrowing).
    /// @param  minSharesOut  Minimum MYT shares to receive (slippage protection).
    /// @param  deadline      Timestamp after which the transaction reverts.
    /// @return tokenId       The position NFT token ID.
    function depositUnderlying(
        address alchemist,
        uint256 amount,
        uint256 borrowAmount,
        uint256 minSharesOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 tokenId) {
        require(block.timestamp <= deadline, "Expired");
        require(amount > 0, "Zero amount");

        address mytVault = IAlchemistV3(alchemist).myt();
        address underlying = IAlchemistV3(alchemist).underlyingToken();

        IERC20(underlying).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(underlying).forceApprove(mytVault, amount);

        tokenId = _depositAndBorrow(alchemist, underlying, mytVault, amount, borrowAmount, minSharesOut);
    }

    /// @notice Deposit native ETH → WETH → MYT vault → Alchemist, optionally borrow.
    /// @dev    WETH address is derived from alchemist.underlyingToken().
    /// @param  alchemist     The Alchemist contract address.
    /// @param  borrowAmount  Amount of debt tokens to borrow (0 to skip borrowing).
    /// @param  minSharesOut  Minimum MYT shares to receive (slippage protection).
    /// @param  deadline      Timestamp after which the transaction reverts.
    /// @return tokenId       The position NFT token ID.
    function depositETH(
        address alchemist,
        uint256 borrowAmount,
        uint256 minSharesOut,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 tokenId) {
        require(msg.value > 0, "No ETH sent");
        require(block.timestamp <= deadline, "Expired");

        address mytVault = IAlchemistV3(alchemist).myt();
        address underlying = IAlchemistV3(alchemist).underlyingToken();

        IWETH(underlying).deposit{value: msg.value}();
        IERC20(underlying).forceApprove(mytVault, msg.value);

        tokenId = _depositAndBorrow(alchemist, underlying, mytVault, msg.value, borrowAmount, minSharesOut);
    }

    /// @notice Deposit underlying into an existing Alchemist position, optionally borrow.
    /// @dev    Caller must have approved this contract for `amount` of underlying.
    ///         Caller must own the position NFT (it stays with the caller).
    ///         If `borrowAmount` > 0, caller must have called `approveMint(tokenId, router, borrowAmount)` on the Alchemist.
    /// @param  alchemist     The Alchemist contract address.
    /// @param  existingTokenId The position NFT token ID to deposit into.
    /// @param  amount        Amount of underlying token to deposit.
    /// @param  borrowAmount  Amount of debt tokens to borrow (0 to skip borrowing).
    /// @param  minSharesOut  Minimum MYT shares to receive (slippage protection).
    /// @param  deadline      Timestamp after which the transaction reverts.
    function depositUnderlyingToExisting(
        address alchemist,
        uint256 existingTokenId,
        uint256 amount,
        uint256 borrowAmount,
        uint256 minSharesOut,
        uint256 deadline
    ) external nonReentrant {
        require(block.timestamp <= deadline, "Expired");
        require(amount > 0, "Zero amount");

        address mytVault = IAlchemistV3(alchemist).myt();
        address underlying = IAlchemistV3(alchemist).underlyingToken();

        IERC20(underlying).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(underlying).forceApprove(mytVault, amount);

        _depositToExisting(alchemist, underlying, mytVault, amount, existingTokenId, borrowAmount, minSharesOut);
    }

    /// @notice Deposit native ETH into an existing Alchemist position, optionally borrow.
    /// @dev    WETH address is derived from alchemist.underlyingToken().
    ///         Caller must own the position NFT (it stays with the caller).
    ///         If `borrowAmount` > 0, caller must have called `approveMint(tokenId, router, borrowAmount)` on the Alchemist.
    /// @param  alchemist     The Alchemist contract address.
    /// @param  existingTokenId The position NFT token ID to deposit into.
    /// @param  borrowAmount  Amount of debt tokens to borrow (0 to skip borrowing).
    /// @param  minSharesOut  Minimum MYT shares to receive (slippage protection).
    /// @param  deadline      Timestamp after which the transaction reverts.
    function depositETHToExisting(
        address alchemist,
        uint256 existingTokenId,
        uint256 borrowAmount,
        uint256 minSharesOut,
        uint256 deadline
    ) external payable nonReentrant {
        require(msg.value > 0, "No ETH sent");
        require(block.timestamp <= deadline, "Expired");

        address mytVault = IAlchemistV3(alchemist).myt();
        address underlying = IAlchemistV3(alchemist).underlyingToken();

        IWETH(underlying).deposit{value: msg.value}();
        IERC20(underlying).forceApprove(mytVault, msg.value);

        _depositToExisting(alchemist, underlying, mytVault, msg.value, existingTokenId, borrowAmount, minSharesOut);
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

    // ─── Internal ────────────────────────────────────────────────────────

    /// @dev Deposits into MYT vault → existing Alchemist position, optionally borrows.
    ///      Assumes underlying tokens are already in this contract and
    ///      approved to the MYT vault. NFT stays with the caller.
    ///      Borrowing uses mintFrom, which requires the caller to have set a mint allowance
    ///      for this contract via approveMint on the Alchemist.
    function _depositToExisting(
        address alchemist,
        address underlying,
        address mytVault,
        uint256 underlyingAmount,
        uint256 existingTokenId,
        uint256 borrowAmount,
        uint256 minSharesOut
    ) internal {
        IAlchemistV3Position nft = IAlchemistV3Position(IAlchemistV3(alchemist).alchemistPositionNFT());
        require(nft.ownerOf(existingTokenId) == msg.sender, "Not position owner");

        uint256 shares = IVaultV2(mytVault).deposit(underlyingAmount, address(this));
        require(shares >= minSharesOut, "Slippage");

        IERC20(underlying).forceApprove(mytVault, 0);
        IERC20(mytVault).forceApprove(alchemist, shares);

        // Deposit into existing position — recipient must be the NFT owner (msg.sender)
        IAlchemistV3(alchemist).deposit(shares, msg.sender, existingTokenId);

        IERC20(mytVault).forceApprove(alchemist, 0);

        // Borrow if requested (uses mintFrom — requires prior approveMint from position owner)
        if (borrowAmount > 0) {
            IAlchemistV3(alchemist).mintFrom(existingTokenId, borrowAmount, msg.sender);
        }
    }

    /// @dev Deposits into MYT vault → Alchemist, optionally borrows, then
    ///      transfers the position NFT to the caller.
    ///      Assumes underlying tokens are already in this contract and
    ///      approved to the MYT vault.
    function _depositAndBorrow(
        address alchemist,
        address underlying,
        address mytVault,
        uint256 underlyingAmount,
        uint256 borrowAmount,
        uint256 minSharesOut
    ) internal returns (uint256 tokenId) {
        // Deposit underlying into MYT vault (shares come to this contract)
        uint256 shares = IVaultV2(mytVault).deposit(underlyingAmount, address(this));
        require(shares >= minSharesOut, "Slippage");

        // Clear residual underlying approval
        IERC20(underlying).forceApprove(mytVault, 0);

        // Approve MYT shares → Alchemist
        IERC20(mytVault).forceApprove(alchemist, shares);

        // Snapshot NFT balance before deposit to isolate the newly minted token
        IAlchemistV3Position nft = IAlchemistV3Position(IAlchemistV3(alchemist).alchemistPositionNFT());
        uint256 balanceBefore = nft.balanceOf(address(this));

        // Deposit into Alchemist — NFT minted to this contract (tokenId=0 creates new position)
        IAlchemistV3(alchemist).deposit(shares, address(this), 0);

        // Clear residual MYT approval
        IERC20(mytVault).forceApprove(alchemist, 0);

        // Retrieve the newly minted tokenId via balance diff
        uint256 balanceAfter = nft.balanceOf(address(this));
        require(balanceAfter == balanceBefore + 1, "No NFT minted");
        tokenId = nft.tokenOfOwnerByIndex(address(this), balanceAfter - 1);

        // Borrow if requested (this contract is the NFT owner, so mint succeeds)
        if (borrowAmount > 0) {
            IAlchemistV3(alchemist).mint(tokenId, borrowAmount, msg.sender);
        }

        // Transfer NFT to user
        nft.transferFrom(address(this), msg.sender, tokenId);
    }

    /// @dev Accept ETH only from WETH unwrap during withdraw flows.
    receive() external payable {
        require(_ethExpected, "Use depositETH");
    }
}
