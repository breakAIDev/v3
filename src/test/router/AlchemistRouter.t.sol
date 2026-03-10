// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AlchemistRouter} from "../../router/AlchemistRouter.sol";
import {IAlchemistV3} from "../../interfaces/IAlchemistV3.sol";
import {IAlchemistV3Position} from "../../interfaces/IAlchemistV3Position.sol";

contract AlchemistRouterTest is Test {
    AlchemistRouter public router;

    address constant ALCHEMIST = address(0x45550d91AAd47281F5FDF3d832C332D5bE5072Af); // Kungfu WETH AlchemistV3 on OP

    address user = makeAddr("user");
    uint256 constant AMOUNT = 0.1 ether;
    uint256 constant BORROW_AMOUNT = 0.05 ether;

    IAlchemistV3 alchemist;
    IAlchemistV3Position nft;
    address underlying;
    address mytVault;
    address debtToken;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_URL"));

        router = new AlchemistRouter();
        alchemist = IAlchemistV3(ALCHEMIST);
        underlying = alchemist.underlyingToken();
        mytVault = alchemist.myt();
        nft = IAlchemistV3Position(alchemist.alchemistPositionNFT());
        debtToken = alchemist.debtToken();
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + 1 hours;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  depositUnderlying — new position
    // ═══════════════════════════════════════════════════════════════════════

    function test_depositUnderlying_newPosition() public {
        deal(underlying, user, AMOUNT);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);

        uint256 tokenId = router.depositUnderlying(address(alchemist), AMOUNT, 0, 0, _deadline());
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), user, "NFT not owned by user");
    }

    function test_depositUnderlying_withBorrow() public {
        deal(underlying, user, AMOUNT);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);

        uint256 tokenId = router.depositUnderlying(address(alchemist), AMOUNT, BORROW_AMOUNT, 0, _deadline());
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), user, "NFT not owned by user");
        assertGe(IERC20(debtToken).balanceOf(user), BORROW_AMOUNT, "Debt tokens not received");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  depositETH — new position
    // ═══════════════════════════════════════════════════════════════════════

    function test_depositETH_newPosition() public {
        vm.deal(user, AMOUNT);

        vm.prank(user);
        uint256 tokenId = router.depositETH{value: AMOUNT}(address(alchemist), 0, 0, _deadline());

        assertEq(nft.ownerOf(tokenId), user, "NFT not owned by user");
    }

    function test_depositETH_withBorrow() public {
        vm.deal(user, AMOUNT);

        vm.prank(user);
        uint256 tokenId = router.depositETH{value: AMOUNT}(address(alchemist), BORROW_AMOUNT, 0, _deadline());

        assertEq(nft.ownerOf(tokenId), user, "NFT not owned by user");
        assertGe(IERC20(debtToken).balanceOf(user), BORROW_AMOUNT, "Debt tokens not received");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  depositUnderlyingToExisting
    // ═══════════════════════════════════════════════════════════════════════

    function test_depositUnderlyingToExisting() public {
        // First create a position
        deal(underlying, user, AMOUNT * 2);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT * 2);

        uint256 tokenId = router.depositUnderlying(address(alchemist), AMOUNT, 0, 0, _deadline());

        // Now deposit more into the same position
        router.depositUnderlyingToExisting(address(alchemist), tokenId, AMOUNT, 0, 0, _deadline());
        vm.stopPrank();

        // User still owns the NFT
        assertEq(nft.ownerOf(tokenId), user, "NFT not owned by user");
    }

    function test_depositUnderlyingToExisting_withBorrow() public {
        deal(underlying, user, AMOUNT * 2);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT * 2);

        uint256 tokenId = router.depositUnderlying(address(alchemist), AMOUNT, 0, 0, _deadline());

        // Approve the router to borrow on behalf of the position
        alchemist.approveMint(tokenId, address(router), BORROW_AMOUNT);

        router.depositUnderlyingToExisting(address(alchemist), tokenId, AMOUNT, BORROW_AMOUNT, 0, _deadline());
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), user, "NFT not owned by user");
        assertGe(IERC20(debtToken).balanceOf(user), BORROW_AMOUNT, "Debt tokens not received");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  depositETHToExisting
    // ═══════════════════════════════════════════════════════════════════════

    function test_depositETHToExisting() public {
        vm.deal(user, AMOUNT * 2);

        vm.startPrank(user);
        uint256 tokenId = router.depositETH{value: AMOUNT}(address(alchemist), 0, 0, _deadline());

        // Deposit more ETH into same position
        router.depositETHToExisting{value: AMOUNT}(address(alchemist), tokenId, 0, 0, _deadline());
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), user, "NFT not owned by user");
    }

    function test_depositETHToExisting_withBorrow() public {
        vm.deal(user, AMOUNT * 2);

        vm.startPrank(user);
        uint256 tokenId = router.depositETH{value: AMOUNT}(address(alchemist), 0, 0, _deadline());

        // Approve the router to borrow on behalf of the position
        alchemist.approveMint(tokenId, address(router), BORROW_AMOUNT);

        router.depositETHToExisting{value: AMOUNT}(address(alchemist), tokenId, BORROW_AMOUNT, 0, _deadline());
        vm.stopPrank();

        assertEq(nft.ownerOf(tokenId), user, "NFT not owned by user");
        assertGe(IERC20(debtToken).balanceOf(user), BORROW_AMOUNT, "Debt tokens not received");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  depositETHToVaultOnly
    // ═══════════════════════════════════════════════════════════════════════

    function test_depositETHToVaultOnly() public {
        vm.deal(user, AMOUNT);

        vm.prank(user);
        uint256 shares = router.depositETHToVaultOnly{value: AMOUNT}(address(alchemist), 0, _deadline());

        assertGt(shares, 0, "No shares returned");
        assertGt(IERC20(mytVault).balanceOf(user), 0, "User has no MYT shares");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Reverts
    // ═══════════════════════════════════════════════════════════════════════

    function test_revert_expired() public {
        vm.prank(user);
        vm.expectRevert("Expired");
        router.depositUnderlying(address(alchemist), AMOUNT, 0, 0, block.timestamp - 1);
    }

    function test_revert_depositETH_noValue() public {
        vm.prank(user);
        vm.expectRevert("No ETH sent");
        router.depositETH{value: 0}(address(alchemist), 0, 0, _deadline());
    }

    function test_revert_depositETHToExisting_noValue() public {
        vm.prank(user);
        vm.expectRevert("No ETH sent");
        router.depositETHToExisting{value: 0}(address(alchemist), 1, 0, 0, _deadline());
    }

    function test_revert_depositETHToVaultOnly_noValue() public {
        vm.prank(user);
        vm.expectRevert("No ETH sent");
        router.depositETHToVaultOnly{value: 0}(address(alchemist), 0, _deadline());
    }

    function test_revert_slippage() public {
        deal(underlying, user, AMOUNT);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);

        vm.expectRevert("Slippage");
        router.depositUnderlying(address(alchemist), AMOUNT, 0, type(uint256).max, _deadline());
        vm.stopPrank();
    }

    function test_revert_directETH() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert("Use depositETH");
        (bool s, ) = address(router).call{value: 1 ether}("");
        s;
    }

    function test_revert_depositToExisting_notOwner() public {
        // Create position as user
        deal(underlying, user, AMOUNT);
        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 tokenId = router.depositUnderlying(address(alchemist), AMOUNT, 0, 0, _deadline());
        vm.stopPrank();

        // A different user cannot deposit into someone else's position via router
        address attacker = makeAddr("attacker");
        deal(underlying, attacker, AMOUNT);
        vm.startPrank(attacker);
        IERC20(underlying).approve(address(router), AMOUNT);

        vm.expectRevert("Not position owner");
        router.depositUnderlyingToExisting(address(alchemist), tokenId, AMOUNT, 0, 0, _deadline());
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Statelessness invariants
    // ═══════════════════════════════════════════════════════════════════════

    function test_routerIsEmptyAfterDeposit() public {
        deal(underlying, user, AMOUNT);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        router.depositUnderlying(address(alchemist), AMOUNT, 0, 0, _deadline());
        vm.stopPrank();

        assertEq(IERC20(underlying).balanceOf(address(router)), 0, "Underlying stuck");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
        assertEq(nft.balanceOf(address(router)), 0, "NFT stuck");
        assertEq(address(router).balance, 0, "ETH stuck");
    }

    function test_routerIsEmptyAfterETHDeposit() public {
        vm.deal(user, AMOUNT);

        vm.prank(user);
        router.depositETH{value: AMOUNT}(address(alchemist), 0, 0, _deadline());

        assertEq(IERC20(underlying).balanceOf(address(router)), 0, "WETH stuck");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
        assertEq(nft.balanceOf(address(router)), 0, "NFT stuck");
        assertEq(address(router).balance, 0, "ETH stuck");
    }

    function test_routerIsEmptyAfterExistingDeposit() public {
        deal(underlying, user, AMOUNT * 2);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT * 2);

        uint256 tokenId = router.depositUnderlying(address(alchemist), AMOUNT, 0, 0, _deadline());
        router.depositUnderlyingToExisting(address(alchemist), tokenId, AMOUNT, 0, 0, _deadline());
        vm.stopPrank();

        assertEq(IERC20(underlying).balanceOf(address(router)), 0, "Underlying stuck");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
        assertEq(address(router).balance, 0, "ETH stuck");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  No residual approvals
    // ═══════════════════════════════════════════════════════════════════════

    function test_noResidualApprovals() public {
        deal(underlying, user, AMOUNT);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        router.depositUnderlying(address(alchemist), AMOUNT, 0, 0, _deadline());
        vm.stopPrank();

        assertEq(IERC20(underlying).allowance(address(router), mytVault), 0, "Underlying to MYT approval not cleared");
        assertEq(
            IERC20(mytVault).allowance(address(router), address(alchemist)),
            0,
            "MYT to Alchemist approval not cleared"
        );
    }

    function test_noResidualApprovals_existing() public {
        deal(underlying, user, AMOUNT * 2);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT * 2);

        uint256 tokenId = router.depositUnderlying(address(alchemist), AMOUNT, 0, 0, _deadline());
        router.depositUnderlyingToExisting(address(alchemist), tokenId, AMOUNT, 0, 0, _deadline());
        vm.stopPrank();

        assertEq(IERC20(underlying).allowance(address(router), mytVault), 0, "Underlying to MYT approval not cleared");
        assertEq(
            IERC20(mytVault).allowance(address(router), address(alchemist)),
            0,
            "MYT to Alchemist approval not cleared"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  repayUnderlying
    // ═══════════════════════════════════════════════════════════════════════

    function test_repayUnderlying() public {
        // Create position with debt
        deal(underlying, user, AMOUNT * 2);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT * 2);
        uint256 tokenId = router.depositUnderlying(address(alchemist), AMOUNT, BORROW_AMOUNT, 0, _deadline());

        uint256 debtBefore = IERC20(debtToken).balanceOf(user);
        assertGe(debtBefore, BORROW_AMOUNT, "No debt tokens minted");

        // Advance past mint block (Alchemist: CannotRepayOnMintBlock)
        vm.roll(block.number + 1);

        // Repay with underlying
        router.repayUnderlying(address(alchemist), tokenId, AMOUNT, 0, _deadline());
        vm.stopPrank();

        // Router should be empty
        assertEq(IERC20(underlying).balanceOf(address(router)), 0, "Underlying stuck");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
        assertEq(IERC20(underlying).allowance(address(router), mytVault), 0, "Approval not cleared");
        assertEq(IERC20(mytVault).allowance(address(router), address(alchemist)), 0, "MYT approval not cleared");
    }

    function test_repayUnderlying_overpayReturnsShares() public {
        // Create position with small debt
        uint256 smallBorrow = 0.01 ether;
        deal(underlying, user, AMOUNT * 2);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT * 2);
        uint256 tokenId = router.depositUnderlying(address(alchemist), AMOUNT, smallBorrow, 0, _deadline());

        uint256 mytBefore = IERC20(mytVault).balanceOf(user);

        // Advance past mint block (Alchemist: CannotRepayOnMintBlock)
        vm.roll(block.number + 1);

        // Overpay — send much more underlying than needed
        router.repayUnderlying(address(alchemist), tokenId, AMOUNT, 0, _deadline());
        vm.stopPrank();

        // User should have received leftover MYT shares back
        uint256 mytAfter = IERC20(mytVault).balanceOf(user);
        assertGt(mytAfter, mytBefore, "No MYT shares returned from overpay");

        // Router should be empty
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck in router");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  repayETH
    // ═══════════════════════════════════════════════════════════════════════

    function test_repayETH() public {
        // Create position with debt via ETH
        vm.deal(user, AMOUNT * 2);

        vm.startPrank(user);
        uint256 tokenId = router.depositETH{value: AMOUNT}(address(alchemist), BORROW_AMOUNT, 0, _deadline());

        // Advance past mint block (Alchemist: CannotRepayOnMintBlock)
        vm.roll(block.number + 1);

        // Repay with ETH
        router.repayETH{value: AMOUNT}(address(alchemist), tokenId, 0, _deadline());
        vm.stopPrank();

        // Router should be empty
        assertEq(IERC20(underlying).balanceOf(address(router)), 0, "WETH stuck");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
        assertEq(address(router).balance, 0, "ETH stuck");
    }

    function test_repayETH_overpayReturnsShares() public {
        uint256 smallBorrow = 0.01 ether;
        vm.deal(user, AMOUNT * 2);

        vm.startPrank(user);
        uint256 tokenId = router.depositETH{value: AMOUNT}(address(alchemist), smallBorrow, 0, _deadline());

        uint256 mytBefore = IERC20(mytVault).balanceOf(user);

        // Advance past mint block (Alchemist: CannotRepayOnMintBlock)
        vm.roll(block.number + 1);

        router.repayETH{value: AMOUNT}(address(alchemist), tokenId, 0, _deadline());
        vm.stopPrank();

        uint256 mytAfter = IERC20(mytVault).balanceOf(user);
        assertGt(mytAfter, mytBefore, "No MYT shares returned from overpay");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck in router");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  withdrawUnderlying
    // ═══════════════════════════════════════════════════════════════════════

    function test_withdrawUnderlying() public {
        deal(underlying, user, AMOUNT);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 tokenId = router.depositUnderlying(address(alchemist), AMOUNT, 0, 0, _deadline());

        // Get deposited shares to know how much to withdraw
        (uint256 collateral,,) = alchemist.getCDP(tokenId);
        uint256 underlyingBefore = IERC20(underlying).balanceOf(user);

        // Approve NFT to router for withdraw
        nft.approve(address(router), tokenId);

        router.withdrawUnderlying(address(alchemist), tokenId, collateral, 0, _deadline());
        vm.stopPrank();

        uint256 underlyingAfter = IERC20(underlying).balanceOf(user);
        assertGt(underlyingAfter, underlyingBefore, "No underlying received");
        assertEq(nft.ownerOf(tokenId), user, "NFT not returned");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  withdrawETH
    // ═══════════════════════════════════════════════════════════════════════

    function test_withdrawETH() public {
        address ethUser = address(0xBEEF);
        vm.deal(ethUser, AMOUNT);

        vm.startPrank(ethUser);
        uint256 tokenId = router.depositETH{value: AMOUNT}(address(alchemist), 0, 0, _deadline());
        (uint256 collateral,,) = alchemist.getCDP(tokenId);
        nft.approve(address(router), tokenId);
        vm.stopPrank();

        uint256 ethBefore = ethUser.balance;

        vm.prank(ethUser);
        router.withdrawETH(address(alchemist), tokenId, collateral, 0, _deadline());

        assertGt(ethUser.balance, ethBefore, "No ETH received");
        assertEq(nft.ownerOf(tokenId), ethUser, "NFT not returned");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
        assertEq(IERC20(underlying).balanceOf(address(router)), 0, "WETH stuck");
        assertEq(address(router).balance, 0, "ETH stuck in router");
    }

    function test_withdrawUnderlying_routerEmpty() public {
        deal(underlying, user, AMOUNT);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 tokenId = router.depositUnderlying(address(alchemist), AMOUNT, 0, 0, _deadline());

        (uint256 collateral,,) = alchemist.getCDP(tokenId);

        nft.approve(address(router), tokenId);
        router.withdrawUnderlying(address(alchemist), tokenId, collateral, 0, _deadline());
        vm.stopPrank();

        assertEq(IERC20(underlying).balanceOf(address(router)), 0, "Underlying stuck");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
        assertEq(nft.balanceOf(address(router)), 0, "NFT stuck");
        assertEq(address(router).balance, 0, "ETH stuck");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Security: mintFrom allowance theft prevention
    // ═══════════════════════════════════════════════════════════════════════

    function test_revert_mintFromTheft_underlying() public {
        // Victim creates position and approves router for future borrow
        deal(underlying, user, AMOUNT);
        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 victimTokenId = router.depositUnderlying(address(alchemist), AMOUNT, 0, 0, _deadline());
        alchemist.approveMint(victimTokenId, address(router), BORROW_AMOUNT);
        vm.stopPrank();

        // Attacker tries to use depositUnderlyingToExisting to steal borrow allowance
        address attacker = makeAddr("attacker");
        deal(underlying, attacker, 0.001 ether);
        vm.startPrank(attacker);
        IERC20(underlying).approve(address(router), 0.001 ether);

        vm.expectRevert("Not position owner");
        router.depositUnderlyingToExisting(address(alchemist), victimTokenId, 0.001 ether, BORROW_AMOUNT, 0, _deadline());
        vm.stopPrank();
    }

    function test_revert_mintFromTheft_ETH() public {
        // Victim creates position and approves router for future borrow
        vm.deal(user, AMOUNT);
        vm.startPrank(user);
        uint256 victimTokenId = router.depositETH{value: AMOUNT}(address(alchemist), 0, 0, _deadline());
        alchemist.approveMint(victimTokenId, address(router), BORROW_AMOUNT);
        vm.stopPrank();

        // Attacker tries to use depositETHToExisting to steal borrow allowance
        address attacker = makeAddr("attacker");
        vm.deal(attacker, 0.001 ether);
        vm.prank(attacker);

        vm.expectRevert("Not position owner");
        router.depositETHToExisting{value: 0.001 ether}(address(alchemist), victimTokenId, BORROW_AMOUNT, 0, _deadline());
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Security: zero amount checks
    // ═══════════════════════════════════════════════════════════════════════

    function test_revert_depositUnderlying_zeroAmount() public {
        vm.prank(user);
        vm.expectRevert("Zero amount");
        router.depositUnderlying(address(alchemist), 0, 0, 0, _deadline());
    }

    function test_revert_depositUnderlyingToExisting_zeroAmount() public {
        deal(underlying, user, AMOUNT);
        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 tokenId = router.depositUnderlying(address(alchemist), AMOUNT, 0, 0, _deadline());
        vm.stopPrank();

        vm.prank(user);
        vm.expectRevert("Zero amount");
        router.depositUnderlyingToExisting(address(alchemist), tokenId, 0, 0, 0, _deadline());
    }

    function test_revert_repayUnderlying_zeroAmount() public {
        vm.prank(user);
        vm.expectRevert("Zero amount");
        router.repayUnderlying(address(alchemist), 1, 0, 0, _deadline());
    }

    function test_revert_withdrawUnderlying_zeroShares() public {
        vm.prank(user);
        vm.expectRevert("Zero shares");
        router.withdrawUnderlying(address(alchemist), 1, 0, 0, _deadline());
    }

    function test_revert_withdrawETH_zeroShares() public {
        vm.prank(user);
        vm.expectRevert("Zero shares");
        router.withdrawETH(address(alchemist), 1, 0, 0, _deadline());
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Security: withdraw by non-owner reverts
    // ═══════════════════════════════════════════════════════════════════════

    function test_revert_withdrawUnderlying_notOwner() public {
        deal(underlying, user, AMOUNT);
        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 tokenId = router.depositUnderlying(address(alchemist), AMOUNT, 0, 0, _deadline());
        vm.stopPrank();

        // Attacker tries to withdraw from user's position (no NFT approval)
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        router.withdrawUnderlying(address(alchemist), tokenId, 1, 0, _deadline());
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Security: no residual approvals after repay and withdraw
    // ═══════════════════════════════════════════════════════════════════════

    function test_noResidualApprovals_repay() public {
        deal(underlying, user, AMOUNT * 2);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT * 2);
        uint256 tokenId = router.depositUnderlying(address(alchemist), AMOUNT, BORROW_AMOUNT, 0, _deadline());

        vm.roll(block.number + 1);
        router.repayUnderlying(address(alchemist), tokenId, AMOUNT, 0, _deadline());
        vm.stopPrank();

        assertEq(IERC20(underlying).allowance(address(router), mytVault), 0, "Underlying->MYT approval");
        assertEq(IERC20(mytVault).allowance(address(router), address(alchemist)), 0, "MYT->Alchemist approval");
    }

    function test_noResidualApprovals_withdraw() public {
        deal(underlying, user, AMOUNT);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 tokenId = router.depositUnderlying(address(alchemist), AMOUNT, 0, 0, _deadline());

        (uint256 collateral,,) = alchemist.getCDP(tokenId);
        nft.approve(address(router), tokenId);
        router.withdrawUnderlying(address(alchemist), tokenId, collateral, 0, _deadline());
        vm.stopPrank();

        assertEq(IERC20(underlying).allowance(address(router), mytVault), 0, "Underlying->MYT approval");
        assertEq(IERC20(mytVault).allowance(address(router), address(alchemist)), 0, "MYT->Alchemist approval");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Security: router statelessness after every flow
    // ═══════════════════════════════════════════════════════════════════════

    function test_routerIsEmptyAfterRepay() public {
        deal(underlying, user, AMOUNT * 2);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT * 2);
        uint256 tokenId = router.depositUnderlying(address(alchemist), AMOUNT, BORROW_AMOUNT, 0, _deadline());

        vm.roll(block.number + 1);
        router.repayUnderlying(address(alchemist), tokenId, AMOUNT, 0, _deadline());
        vm.stopPrank();

        assertEq(IERC20(underlying).balanceOf(address(router)), 0, "Underlying stuck");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
        assertEq(nft.balanceOf(address(router)), 0, "NFT stuck");
        assertEq(address(router).balance, 0, "ETH stuck");
    }

    function test_routerIsEmptyAfterRepayETH() public {
        vm.deal(user, AMOUNT * 2);

        vm.startPrank(user);
        uint256 tokenId = router.depositETH{value: AMOUNT}(address(alchemist), BORROW_AMOUNT, 0, _deadline());

        vm.roll(block.number + 1);
        router.repayETH{value: AMOUNT}(address(alchemist), tokenId, 0, _deadline());
        vm.stopPrank();

        assertEq(IERC20(underlying).balanceOf(address(router)), 0, "WETH stuck");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
        assertEq(nft.balanceOf(address(router)), 0, "NFT stuck");
        assertEq(address(router).balance, 0, "ETH stuck");
    }

    function test_routerIsEmptyAfterWithdrawETH() public {
        address ethUser = address(0xBEEF);
        vm.deal(ethUser, AMOUNT);

        vm.startPrank(ethUser);
        uint256 tokenId = router.depositETH{value: AMOUNT}(address(alchemist), 0, 0, _deadline());
        (uint256 collateral,,) = alchemist.getCDP(tokenId);
        nft.approve(address(router), tokenId);
        vm.stopPrank();

        vm.prank(ethUser);
        router.withdrawETH(address(alchemist), tokenId, collateral, 0, _deadline());

        assertEq(IERC20(underlying).balanceOf(address(router)), 0, "WETH stuck");
        assertEq(IERC20(mytVault).balanceOf(address(router)), 0, "MYT stuck");
        assertEq(nft.balanceOf(address(router)), 0, "NFT stuck");
        assertEq(address(router).balance, 0, "ETH stuck");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Security: mint allowances reset on NFT transfer through withdraw
    // ═══════════════════════════════════════════════════════════════════════

    function test_withdrawClearsMintAllowance() public {
        deal(underlying, user, AMOUNT);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 tokenId = router.depositUnderlying(address(alchemist), AMOUNT, 0, 0, _deadline());

        // Set mint allowance for router
        alchemist.approveMint(tokenId, address(router), BORROW_AMOUNT);
        assertEq(alchemist.mintAllowance(tokenId, address(router)), BORROW_AMOUNT, "Allowance not set");

        // Withdraw triggers NFT transfer through router, which resets mint allowances
        (uint256 collateral,,) = alchemist.getCDP(tokenId);
        nft.approve(address(router), tokenId);
        router.withdrawUnderlying(address(alchemist), tokenId, collateral, 0, _deadline());
        vm.stopPrank();

        // Mint allowance should be cleared due to NFT transfer
        assertEq(alchemist.mintAllowance(tokenId, address(router)), 0, "Mint allowance not cleared after withdraw");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Security: deadline enforcement on all functions
    // ═══════════════════════════════════════════════════════════════════════

    function test_revert_repayUnderlying_expired() public {
        vm.prank(user);
        vm.expectRevert("Expired");
        router.repayUnderlying(address(alchemist), 1, AMOUNT, 0, block.timestamp - 1);
    }

    function test_revert_repayETH_expired() public {
        vm.deal(user, AMOUNT);
        vm.prank(user);
        vm.expectRevert("Expired");
        router.repayETH{value: AMOUNT}(address(alchemist), 1, 0, block.timestamp - 1);
    }

    function test_revert_withdrawUnderlying_expired() public {
        vm.prank(user);
        vm.expectRevert("Expired");
        router.withdrawUnderlying(address(alchemist), 1, 1, 0, block.timestamp - 1);
    }

    function test_revert_withdrawETH_expired() public {
        vm.prank(user);
        vm.expectRevert("Expired");
        router.withdrawETH(address(alchemist), 1, 1, 0, block.timestamp - 1);
    }

    function test_revert_depositETHToVaultOnly_expired() public {
        vm.deal(user, AMOUNT);
        vm.prank(user);
        vm.expectRevert("Expired");
        router.depositETHToVaultOnly{value: AMOUNT}(address(alchemist), 0, block.timestamp - 1);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Security: slippage on withdraw
    // ═══════════════════════════════════════════════════════════════════════

    function test_revert_withdrawUnderlying_slippage() public {
        deal(underlying, user, AMOUNT);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT);
        uint256 tokenId = router.depositUnderlying(address(alchemist), AMOUNT, 0, 0, _deadline());

        (uint256 collateral,,) = alchemist.getCDP(tokenId);
        nft.approve(address(router), tokenId);

        vm.expectRevert("Slippage");
        router.withdrawUnderlying(address(alchemist), tokenId, collateral, type(uint256).max, _deadline());
        vm.stopPrank();
    }

    function test_revert_withdrawETH_slippage() public {
        address ethUser = address(0xBEEF);
        vm.deal(ethUser, AMOUNT);

        vm.startPrank(ethUser);
        uint256 tokenId = router.depositETH{value: AMOUNT}(address(alchemist), 0, 0, _deadline());
        (uint256 collateral,,) = alchemist.getCDP(tokenId);
        nft.approve(address(router), tokenId);

        vm.expectRevert("Slippage");
        router.withdrawETH(address(alchemist), tokenId, collateral, type(uint256).max, _deadline());
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Security: slippage on repay vault deposit
    // ═══════════════════════════════════════════════════════════════════════

    function test_revert_repayUnderlying_slippage() public {
        deal(underlying, user, AMOUNT * 2);

        vm.startPrank(user);
        IERC20(underlying).approve(address(router), AMOUNT * 2);
        uint256 tokenId = router.depositUnderlying(address(alchemist), AMOUNT, BORROW_AMOUNT, 0, _deadline());

        vm.roll(block.number + 1);

        vm.expectRevert("Slippage");
        router.repayUnderlying(address(alchemist), tokenId, AMOUNT, type(uint256).max, _deadline());
        vm.stopPrank();
    }

    function test_revert_repayETH_slippage() public {
        vm.deal(user, AMOUNT * 2);

        vm.startPrank(user);
        uint256 tokenId = router.depositETH{value: AMOUNT}(address(alchemist), BORROW_AMOUNT, 0, _deadline());

        vm.roll(block.number + 1);

        vm.expectRevert("Slippage");
        router.repayETH{value: AMOUNT}(address(alchemist), tokenId, type(uint256).max, _deadline());
        vm.stopPrank();
    }
}
