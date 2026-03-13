// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./Invariants/HardenedInvariantsTest.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface IHardenedReplayTarget {
    function depositCollateral(uint256 amount, uint256 onBehalfSeed) external;
    function borrowCollateral(uint256 amount, uint256 onBehalfSeed) external;
    function transmuterStake(uint256 amount, uint256 onBehalfSeed) external;
    function transmuterClaim(uint256 onBehalfSeed) external;
    function simulateValueLoss(uint256 lossBps) external;
}

contract ReplayCaller {
    function depositCollateral(address target, uint256 amount, uint256 onBehalfSeed) external {
        IHardenedReplayTarget(target).depositCollateral(amount, onBehalfSeed);
    }

    function borrowCollateral(address target, uint256 amount, uint256 onBehalfSeed) external {
        IHardenedReplayTarget(target).borrowCollateral(amount, onBehalfSeed);
    }

    function transmuterStake(address target, uint256 amount, uint256 onBehalfSeed) external {
        IHardenedReplayTarget(target).transmuterStake(amount, onBehalfSeed);
    }

    function transmuterClaim(address target, uint256 onBehalfSeed) external {
        IHardenedReplayTarget(target).transmuterClaim(onBehalfSeed);
    }

    function simulateValueLoss(address target, uint256 lossBps) external {
        IHardenedReplayTarget(target).simulateValueLoss(lossBps);
    }
}

interface IReplayAlchemist {
    function deposit(uint256 amount, address recipient, uint256 tokenId) external returns (uint256);
    function mint(uint256 tokenId, uint256 amount, address recipient) external;
}

interface IReplayTransmuter {
    function createRedemption(uint256 syntheticDepositAmount) external;
    function claimRedemption(uint256 id) external;
}

interface IReplayAlToken {
    function mint(address recipient, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IReplayYieldToken {
    function siphon(uint256 amount) external;
}

contract ReplayActor {
    function depositSequence(address underlying, address vaultAddr, address alchemistAddr, uint256 amount, uint256 tokenId)
        external
    {
        IERC20(underlying).approve(vaultAddr, amount * 2);
        IVaultV2(vaultAddr).mint(amount, address(this));
        IReplayAlchemist(alchemistAddr).deposit(amount, address(this), tokenId);
    }

    function borrowSequence(address alchemistAddr, uint256 tokenId, uint256 amount) external {
        IReplayAlchemist(alchemistAddr).mint(tokenId, amount, address(this));
    }

    function stakeSequence(address alTokenAddr, address transmuterAddr, uint256 amount) external {
        IReplayAlToken(alTokenAddr).mint(address(this), amount);
        IReplayAlToken(alTokenAddr).approve(transmuterAddr, amount);
        IReplayTransmuter(transmuterAddr).createRedemption(amount);
    }

    function claimSequence(address transmuterAddr, uint256 tokenId) external {
        IReplayTransmuter(transmuterAddr).claimRedemption(tokenId);
    }

    function siphonSequence(address yieldTokenAddr, uint256 amount) external {
        IReplayYieldToken(yieldTokenAddr).siphon(amount);
    }
}

contract HardenedH1cReplayTest is HardenedInvariantsTest {
    address internal constant REPLAY_SENDER_1 = 0x71b3Ff058345Ab2Ad3f59aE87D88a98ec95eeA95;
    address internal constant REPLAY_SENDER_2 = 0x558a3E99E1b0cD45f37b0d2AC7Ba7E6E448341b5;
    address internal constant REPLAY_SENDER_3 = 0xD28A15E0406206874e46eeA4a0c9E8dBd8d581c3;
    address internal constant REPLAY_SENDER_4 = 0xB788D82d64BD2aA02B6331EbbBD7622Cb5394856;
    address internal constant REPLAY_SENDER_5 = 0xA6A4A5d3b4b8Af71a895F06e70c928Cd374C2dD0;
    address internal constant REPLAY_SENDER_6 = 0x326935A8eb4f0d2F47d90DC2665CFb67A42f9733;
    address internal constant REPLAY_SENDER_8 = 0x558a3E99E1b0cD45f37b0d2AC7Ba7E6E448341b5;

    function test_Replay_H1c_Run15() public {
        _inspectState("start");

        this.depositCollateral(100604225311423565863199815, 18529138594950818569606233213767597);
        _inspectState("1 depositCollateral");

        this.depositCollateral(110983680496392019800630532713543631868369888980899, 21843098231561245709296699493021555797329339618551);
        _inspectState("2 depositCollateral");

        this.borrowCollateral(45662132078738577387723720624637923512403513, 700082738749228695263805748473636813192274);
        _inspectState("3 borrowCollateral");

        this.transmuterStake(4467552170855813835530, 16135181);
        _inspectState("4 transmuterStake");

        this.transmuterStake(115792089210356248756420345214020892766250353992003419616917011526809519390720, 17969);
        _inspectState("5 transmuterStake");

        this.transmuterClaim(2845);
        _inspectState("6 transmuterClaim");

        this.borrowCollateral(850000000000000000, 1974614269);
        _inspectState("7 borrowCollateral");

        this.simulateValueLoss(15380);
        _inspectState("8 simulateValueLoss");

        this.transmuterClaim(1575976380507028377494437209687826004004996653274528662102292941099014226389);
        _inspectState("9 transmuterClaim");

        invariantStorageDebtConsistency();
    }

    function test_Replay_H1c_Run15_WithInterleavedPokes() public {
        this.depositCollateral(100604225311423565863199815, 18529138594950818569606233213767597);
        _runMutatingInvariants();

        this.depositCollateral(110983680496392019800630532713543631868369888980899, 21843098231561245709296699493021555797329339618551);
        _runMutatingInvariants();

        this.borrowCollateral(45662132078738577387723720624637923512403513, 700082738749228695263805748473636813192274);
        _runMutatingInvariants();

        this.transmuterStake(4467552170855813835530, 16135181);
        _runMutatingInvariants();

        this.transmuterStake(115792089210356248756420345214020892766250353992003419616917011526809519390720, 17969);
        _runMutatingInvariants();

        this.transmuterClaim(2845);
        _runMutatingInvariants();

        this.borrowCollateral(850000000000000000, 1974614269);
        _runMutatingInvariants();

        this.simulateValueLoss(15380);
        _runMutatingInvariants();

        this.transmuterClaim(1575976380507028377494437209687826004004996653274528662102292941099014226389);
        _runMutatingInvariants();

        invariantStorageDebtConsistency();
    }

    function test_Replay_H1c_Run15_CleanSequence() public {
        this.depositCollateral(100604225311423565863199815, 18529138594950818569606233213767597);
        this.depositCollateral(110983680496392019800630532713543631868369888980899, 21843098231561245709296699493021555797329339618551);
        this.borrowCollateral(45662132078738577387723720624637923512403513, 700082738749228695263805748473636813192274);
        this.transmuterStake(4467552170855813835530, 16135181);
        this.transmuterStake(115792089210356248756420345214020892766250353992003419616917011526809519390720, 17969);
        this.transmuterClaim(2845);
        this.borrowCollateral(850000000000000000, 1974614269);
        this.simulateValueLoss(15380);
        this.transmuterClaim(1575976380507028377494437209687826004004996653274528662102292941099014226389);

        invariantStorageDebtConsistency();
    }

    function test_Replay_H1c_Run15_AsRecordedSenders() public {
        _installReplayCallers();

        ReplayCaller(REPLAY_SENDER_1).depositCollateral(address(this), 100604225311423565863199815, 18529138594950818569606233213767597);
        ReplayCaller(REPLAY_SENDER_2).depositCollateral(address(this), 110983680496392019800630532713543631868369888980899, 21843098231561245709296699493021555797329339618551);
        ReplayCaller(REPLAY_SENDER_3).borrowCollateral(address(this), 45662132078738577387723720624637923512403513, 700082738749228695263805748473636813192274);
        ReplayCaller(REPLAY_SENDER_3).transmuterStake(address(this), 4467552170855813835530, 16135181);
        ReplayCaller(REPLAY_SENDER_4).transmuterStake(address(this), 115792089210356248756420345214020892766250353992003419616917011526809519390720, 17969);
        ReplayCaller(REPLAY_SENDER_4).transmuterClaim(address(this), 2845);
        ReplayCaller(REPLAY_SENDER_3).borrowCollateral(address(this), 850000000000000000, 1974614269);
        ReplayCaller(REPLAY_SENDER_5).simulateValueLoss(address(this), 15380);
        ReplayCaller(REPLAY_SENDER_6).transmuterClaim(address(this), 1575976380507028377494437209687826004004996653274528662102292941099014226389);

        invariantStorageDebtConsistency();
    }

    function test_Replay_H1c_Run15_BroadcastedTransactions() public {
        _installReplayActors();

        deal(mockVaultCollateral, REPLAY_SENDER_6, 100604225311423565863199815);
        vm.broadcast(REPLAY_SENDER_6);
        ReplayActor(REPLAY_SENDER_6).depositSequence(
            mockVaultCollateral, address(vault), address(alchemist), 100604225311423565863199815, 0
        );

        deal(mockVaultCollateral, REPLAY_SENDER_8, 532702445263818730687000836);
        vm.broadcast(REPLAY_SENDER_8);
        ReplayActor(REPLAY_SENDER_8).depositSequence(
            mockVaultCollateral, address(vault), address(alchemist), 532702445263818730687000836, 0
        );

        vm.roll(block.number + 1);
        vm.broadcast(REPLAY_SENDER_6);
        ReplayActor(REPLAY_SENDER_6).borrowSequence(address(alchemist), 1, 83400112072670140649730987);

        vm.broadcast(REPLAY_SENDER_6);
        ReplayActor(REPLAY_SENDER_6).stakeSequence(address(alToken), address(transmuterLogic), 4467552170855813835530);

        vm.broadcast(REPLAY_SENDER_2);
        ReplayActor(REPLAY_SENDER_2).stakeSequence(address(alToken), address(transmuterLogic), 26220731389542374247354042);

        vm.roll(block.number + 10000);
        vm.broadcast(REPLAY_SENDER_6);
        ReplayActor(REPLAY_SENDER_6).claimSequence(address(transmuterLogic), 1);

        vm.roll(block.number + 1);
        vm.broadcast(REPLAY_SENDER_8);
        ReplayActor(REPLAY_SENDER_8).borrowSequence(address(alchemist), 2, 850000000000000000);

        vm.broadcast(REPLAY_SENDER_4);
        ReplayActor(REPLAY_SENDER_4).siphonSequence(mockStrategyYieldToken, 10000000000000000000000);

        vm.roll(block.number + 10000);
        vm.broadcast(REPLAY_SENDER_2);
        ReplayActor(REPLAY_SENDER_2).claimSequence(address(transmuterLogic), 2);

        _inspectState("broadcasted_final");
        invariantStorageDebtConsistency();
    }

    function _inspectState(string memory label) internal {
        uint256 snap = vm.snapshotState();

        emit log_string(label);
        emit log_named_uint("block", block.number);
        emit log_named_uint("totalDeposited", alchemist.getTotalDeposited());
        emit log_named_uint("totalDebt", alchemist.totalDebt());
        emit log_named_uint("cumulativeEarmarked", alchemist.cumulativeEarmarked());
        emit log_named_uint("contractMYTBalance", IERC20(alchemist.myt()).balanceOf(address(alchemist)));
        emit log_named_uint("transmuterMYTBalance", IERC20(alchemist.myt()).balanceOf(address(transmuterLogic)));

        address[] memory senders = targetSenders();
        for (uint256 i; i < senders.length; ++i) {
            uint256 tokenId = _safeGetFirstTokenId(senders[i]);
            if (tokenId == 0) continue;

            try alchemist.getCDP(tokenId) returns (uint256 col, uint256 debt, uint256 earmarked) {
                emit log_named_address("pre_owner", senders[i]);
                emit log_named_uint("pre_tokenId", tokenId);
                emit log_named_uint("pre_collateral", col);
                emit log_named_uint("pre_debt", debt);
                emit log_named_uint("pre_earmarked", earmarked);
            } catch {}
        }

        for (uint256 i; i < senders.length; ++i) {
            uint256 tokenId = _safeGetFirstTokenId(senders[i]);
            if (tokenId != 0) {
                try alchemist.poke(tokenId) {} catch {}
            }
        }

        uint256 sumDebt;
        uint256 sumEarmarked;
        uint256 sumCollateral;
        uint256 active;

        for (uint256 i; i < senders.length; ++i) {
            uint256 tokenId = _safeGetFirstTokenId(senders[i]);
            if (tokenId == 0) continue;

            try alchemist.getCDP(tokenId) returns (uint256 col, uint256 debt, uint256 earmarked) {
                active++;
                sumDebt += debt;
                sumEarmarked += earmarked;
                sumCollateral += col;

                emit log_named_address("post_owner", senders[i]);
                emit log_named_uint("post_tokenId", tokenId);
                emit log_named_uint("post_collateral", col);
                emit log_named_uint("post_debt", debt);
                emit log_named_uint("post_earmarked", earmarked);
            } catch {}
        }

        emit log_named_uint("active", active);
        emit log_named_uint("sumCollateral", sumCollateral);
        emit log_named_uint("sumDebt", sumDebt);
        emit log_named_uint("sumEarmarked", sumEarmarked);
        emit log_named_uint("post_totalDeposited", alchemist.getTotalDeposited());
        emit log_named_uint("post_totalDebt", alchemist.totalDebt());
        emit log_named_uint("post_cumulativeEarmarked", alchemist.cumulativeEarmarked());
        emit log_named_uint("debtDelta", _absDiff(sumDebt, alchemist.totalDebt()));
        emit log_named_uint("earmarkDelta", _absDiff(sumEarmarked, alchemist.cumulativeEarmarked()));
        emit log_named_uint("collateralDelta", _absDiff(sumCollateral, alchemist.getTotalDeposited()));

        vm.revertToState(snap);
    }

    function _runMutatingInvariants() internal {
        invariantStorageDebtConsistency();
        invariantPerPositionSanity();
        invariantPokeIdempotent();
    }

    function _installReplayCallers() internal {
        bytes memory code = type(ReplayCaller).runtimeCode;
        vm.etch(REPLAY_SENDER_1, code);
        vm.etch(REPLAY_SENDER_2, code);
        vm.etch(REPLAY_SENDER_3, code);
        vm.etch(REPLAY_SENDER_4, code);
        vm.etch(REPLAY_SENDER_5, code);
        vm.etch(REPLAY_SENDER_6, code);
    }

    function _installReplayActors() internal {
        bytes memory code = type(ReplayActor).runtimeCode;
        vm.etch(REPLAY_SENDER_2, code);
        vm.etch(REPLAY_SENDER_4, code);
        vm.etch(REPLAY_SENDER_6, code);
        vm.etch(REPLAY_SENDER_8, code);
    }
}
