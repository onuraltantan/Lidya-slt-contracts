// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SLT} from "../src/SLT.sol";
import {IndexOracle} from "../src/IndexOracle.sol";
import {MintContract} from "../src/MintContract.sol";
import {MockStable} from "./invariants/Handler.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title v1.1-audit hardening tests — M-01, M-02, M-03, L-04 (Moment Research review, Sep 2026)
contract HardeningV11Test is Test {
    SLT internal slt;
    IndexOracle internal oracle;
    MintContract internal mintContract;
    MockStable internal usdc;

    address internal safe = address(0xCAFE); // Treasury Safe = DEFAULT_ADMIN + BURNER
    address internal pauser = address(0xA2);
    address internal guardian = address(0xA3);
    address internal updater = address(0xA4);
    address internal alice = address(0xB1);
    address internal stranger = address(0xDEAD);

    uint256 internal constant MIN_MINT = 1_000 * 1e6;
    uint256 internal constant MAX_MINT = 5_000_000 * 1e6;

    event BurnSourceLocked(address indexed caller);
    event TreasurySafeProposed(address indexed current, address indexed proposed, uint256 executableAt);
    event TreasurySafeUpdated(address indexed previous, address indexed updated);
    event TreasurySafeProposalCancelled(address indexed cancelled);

    function _arr(
        address a
    ) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function setUp() public {
        oracle = new IndexOracle(1e18, safe, guardian, updater);
        slt = new SLT(safe, pauser, address(oracle));
        usdc = new MockStable("USD Coin", "USDC");
        mintContract = new MintContract(
            address(slt), address(oracle), safe, safe, pauser, MIN_MINT, MAX_MINT, _arr(address(usdc))
        );

        vm.startPrank(safe);
        slt.grantRole(slt.MINTER_ROLE(), address(mintContract));
        vm.stopPrank();
    }

    function _mintTo(
        address who,
        uint256 stableAmount
    ) internal returns (uint256) {
        usdc.mint(who, stableAmount);
        vm.startPrank(who);
        usdc.approve(address(mintContract), stableAmount);
        uint256 got = mintContract.mintSLT(address(usdc), stableAmount);
        vm.stopPrank();
        return got;
    }

    // ======================================================================
    // M-01 — burn source: Treasury Safe by default, sealable with lockBurnSource()
    // ======================================================================

    function test_M01_TreasurySafeIsBurnSourceAtConstruction() public view {
        assertTrue(slt.authorizedBurnSource(safe), "admin/Treasury Safe must be a burn source from deploy");
        assertFalse(slt.burnSourceLocked());
    }

    function test_M01_BurnSourceCount_TracksSet() public {
        assertEq(slt.burnSourceCount(), 1, "only Treasury Safe at construction");
        vm.startPrank(safe);
        slt.setBurnSource(alice, true);
        assertEq(slt.burnSourceCount(), 2);
        slt.setBurnSource(alice, true); // idempotent: no double count
        assertEq(slt.burnSourceCount(), 2);
        slt.setBurnSource(alice, false);
        assertEq(slt.burnSourceCount(), 1);
        slt.setBurnSource(alice, false); // idempotent: no underflow
        assertEq(slt.burnSourceCount(), 1);
        vm.stopPrank();
    }

    function test_M01_LockBurnSource_RefusesUnlessExactlyOneSource() public {
        vm.startPrank(safe);
        slt.setBurnSource(alice, true);
        vm.expectRevert(abi.encodeWithSelector(SLT.SLT_BurnSourceCountNotOne.selector, 2));
        slt.lockBurnSource(safe);
        slt.setBurnSource(alice, false);
        slt.lockBurnSource(safe); // exactly {Treasury Safe} -> ok
        vm.stopPrank();
        assertTrue(slt.burnSourceLocked());
        assertEq(slt.burnSourceCount(), 1);
    }

    function test_M01_LockBurnSource_RefusesWhenTreasuryRemoved() public {
        vm.startPrank(safe);
        slt.setBurnSource(safe, false);
        // expected source no longer authorized → rejected before the count check
        vm.expectRevert(abi.encodeWithSelector(SLT.SLT_UnexpectedBurnSource.selector, safe));
        slt.lockBurnSource(safe);
        vm.stopPrank();
    }

    /// @notice M-3: a swapped set (holder in, Safe out) cannot be sealed under the Safe's name.
    function test_M3_LockBurnSource_RefusesSwappedSetUnderExpectedName() public {
        vm.startPrank(safe);
        slt.setBurnSource(alice, true);
        slt.setBurnSource(safe, false);
        assertEq(slt.burnSourceCount(), 1, "count is 1 but the member is wrong");
        vm.expectRevert(abi.encodeWithSelector(SLT.SLT_UnexpectedBurnSource.selector, safe));
        slt.lockBurnSource(safe);
        vm.stopPrank();
        assertFalse(slt.burnSourceLocked());
    }

    function test_M3_LockBurnSource_RevertOnZeroExpected() public {
        vm.prank(safe);
        vm.expectRevert(SLT.SLT_ZeroAddress.selector);
        slt.lockBurnSource(address(0));
    }

    function test_M3_LockBurnSource_RevertWhenExpectedNotAuthorized() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(SLT.SLT_UnexpectedBurnSource.selector, alice));
        slt.lockBurnSource(alice);
    }

    function test_M01_LockBurnSource_OnlyAdmin() public {
        vm.prank(stranger);
        vm.expectRevert();
        slt.lockBurnSource(safe);
    }

    function test_M01_LockBurnSource_OnlyOnce() public {
        vm.prank(safe);
        slt.lockBurnSource(safe);
        vm.prank(safe);
        vm.expectRevert(SLT.SLT_BurnSourceAlreadyLocked.selector);
        slt.lockBurnSource(safe);
    }

    function test_M01_LockBurnSource_EmitsAndSetsFlag() public {
        vm.expectEmit(true, false, false, false);
        emit BurnSourceLocked(safe);
        vm.prank(safe);
        slt.lockBurnSource(safe);
        assertTrue(slt.burnSourceLocked());
    }

    function test_M01_LockBurnSource_BlocksSetBurnSource_Add() public {
        vm.prank(safe);
        slt.lockBurnSource(safe);
        vm.prank(safe);
        vm.expectRevert(SLT.SLT_BurnSourceLocked.selector);
        slt.setBurnSource(alice, true);
    }

    function test_M01_LockBurnSource_BlocksSetBurnSource_Remove() public {
        vm.prank(safe);
        slt.lockBurnSource(safe);
        vm.prank(safe);
        vm.expectRevert(SLT.SLT_BurnSourceLocked.selector);
        slt.setBurnSource(safe, false);
    }

    function test_M01_AdminBurnFromTreasuryStillWorksAfterLock() public {
        // Treasury-held inventory (e.g. erroneous mint sent to Safe) is reconcilable post-lock.
        vm.prank(address(mintContract));
        slt.mint(safe, 100 ether);
        vm.prank(safe);
        slt.lockBurnSource(safe);
        vm.prank(safe);
        slt.adminBurn(safe, 40 ether);
        assertEq(slt.balanceOf(safe), 60 ether);
    }

    /// @notice INVARIANT (M-01): after lockBurnSource(), no role holder can burn a holder balance.
    function testFuzz_M01_HolderBalanceUntouchableAfterLock(
        address holder,
        uint256 amount
    ) public {
        vm.assume(holder != address(0) && holder != safe);
        amount = bound(amount, 1, 1e30);
        vm.prank(address(mintContract));
        slt.mint(holder, amount);

        vm.prank(safe);
        slt.lockBurnSource(safe);

        // BURNER_ROLE (Safe) cannot burn the holder.
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(SLT.SLT_BurnSourceNotAuthorized.selector, holder));
        slt.adminBurn(holder, amount);

        // Even granting BURNER_ROLE to a fresh address does not help — the source list is sealed.
        bytes32 burner = slt.BURNER_ROLE();
        vm.prank(safe);
        slt.grantRole(burner, stranger);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SLT.SLT_BurnSourceNotAuthorized.selector, holder));
        slt.adminBurn(holder, amount);

        assertEq(slt.balanceOf(holder), amount, "holder balance changed");
    }

    // ======================================================================
    // M-02 — gracePeriod >= minUpdateInterval + 4h (no self-halting oracle config)
    // ======================================================================

    function test_M02_DefaultsSatisfyGuard() public view {
        assertGe(oracle.gracePeriod(), oracle.minUpdateInterval() + 4 hours);
    }

    function test_M02_SetMinUpdateInterval_RevertWhenGraceTooShort() public {
        // grace = 1 day (default); 21h + 4h = 25h > 24h → reject
        vm.prank(safe);
        vm.expectRevert(IndexOracle.IndexOracle_InvalidConfig.selector);
        oracle.setMinUpdateInterval(21 hours);
    }

    function test_M02_SetMinUpdateInterval_OkWhenGraceRaisedFirst() public {
        vm.startPrank(safe);
        oracle.setGracePeriod(2 days);
        oracle.setMinUpdateInterval(1 days);
        vm.stopPrank();
        assertEq(oracle.minUpdateInterval(), 1 days);
    }

    function test_M02_SetGracePeriod_RevertBelowIntervalPlus4h() public {
        vm.startPrank(safe);
        oracle.setGracePeriod(2 days);
        oracle.setMinUpdateInterval(1 days); // now grace must be >= 28h
        vm.expectRevert(IndexOracle.IndexOracle_InvalidConfig.selector);
        oracle.setGracePeriod(27 hours);
        oracle.setGracePeriod(28 hours); // boundary OK
        vm.stopPrank();
        assertEq(oracle.gracePeriod(), 28 hours);
    }

    function testFuzz_M02_ConfigNeverSelfHalting(
        uint256 grace,
        uint256 interval
    ) public {
        grace = bound(grace, 1 days, 7 days);
        interval = bound(interval, 20 hours, 1 days);
        vm.startPrank(safe);
        // Apply in the order that can succeed; whatever lands, the guard must hold.
        try oracle.setGracePeriod(grace) {} catch {}
        try oracle.setMinUpdateInterval(interval) {} catch {}
        try oracle.setGracePeriod(grace) {} catch {}
        vm.stopPrank();
        assertGe(oracle.gracePeriod(), oracle.minUpdateInterval() + 4 hours, "self-halting config reachable");
    }

    // ======================================================================
    // M-03 — setTreasurySafe: in-contract 24h delay (propose -> execute)
    // ======================================================================

    function test_M03_Delay_Is24h() public view {
        assertEq(mintContract.TREASURY_SAFE_DELAY(), 24 hours);
    }

    function test_M03_ProposeDoesNotChangeSafe() public {
        address newSafe = address(0xC0FFEE);
        vm.expectEmit(true, true, false, true);
        emit TreasurySafeProposed(safe, newSafe, block.timestamp + 24 hours);
        vm.prank(safe);
        mintContract.setTreasurySafe(newSafe);

        assertEq(mintContract.treasurySafe(), safe, "safe changed immediately");
        assertEq(mintContract.pendingTreasurySafe(), newSafe);
        assertEq(mintContract.pendingTreasurySafeExecutableAt(), block.timestamp + 24 hours);

        // Deposits keep flowing to the current safe meanwhile.
        _mintTo(alice, MIN_MINT);
        assertEq(usdc.balanceOf(safe), MIN_MINT);
        assertEq(usdc.balanceOf(newSafe), 0);
    }

    function test_M03_ExecuteBeforeDelay_Reverts() public {
        vm.prank(safe);
        mintContract.setTreasurySafe(address(0xC0FFEE));
        vm.warp(block.timestamp + 24 hours - 1);
        vm.prank(safe);
        vm.expectRevert(MintContract.MintContract_TreasurySafeDelayNotElapsed.selector);
        mintContract.executeTreasurySafe();
    }

    function test_M03_ExecuteAfterDelay_Succeeds() public {
        address newSafe = address(0xC0FFEE);
        vm.prank(safe);
        mintContract.setTreasurySafe(newSafe);
        vm.warp(block.timestamp + 24 hours);

        vm.expectEmit(true, true, false, true);
        emit TreasurySafeUpdated(safe, newSafe);
        vm.prank(safe);
        mintContract.executeTreasurySafe();

        assertEq(mintContract.treasurySafe(), newSafe);
        assertEq(mintContract.pendingTreasurySafe(), address(0));
        assertEq(mintContract.pendingTreasurySafeExecutableAt(), 0);

        _mintTo(alice, MIN_MINT);
        assertEq(usdc.balanceOf(newSafe), MIN_MINT);
    }

    function test_M03_ExecuteWithoutProposal_Reverts() public {
        vm.prank(safe);
        vm.expectRevert(MintContract.MintContract_NoPendingTreasurySafe.selector);
        mintContract.executeTreasurySafe();
    }

    function test_M03_Execute_OnlyAdmin() public {
        vm.prank(safe);
        mintContract.setTreasurySafe(address(0xC0FFEE));
        vm.warp(block.timestamp + 24 hours);
        vm.prank(stranger);
        vm.expectRevert();
        mintContract.executeTreasurySafe();
    }

    function test_M03_Cancel_ClearsProposal() public {
        address newSafe = address(0xC0FFEE);
        vm.prank(safe);
        mintContract.setTreasurySafe(newSafe);
        vm.expectEmit(true, false, false, true);
        emit TreasurySafeProposalCancelled(newSafe);
        vm.prank(safe);
        mintContract.cancelTreasurySafe();
        assertEq(mintContract.pendingTreasurySafe(), address(0));
        assertEq(mintContract.pendingTreasurySafeExecutableAt(), 0);

        vm.warp(block.timestamp + 24 hours);
        vm.prank(safe);
        vm.expectRevert(MintContract.MintContract_NoPendingTreasurySafe.selector);
        mintContract.executeTreasurySafe();
    }

    function test_M03_Cancel_OnlyAdmin_AndRequiresPending() public {
        vm.prank(safe);
        vm.expectRevert(MintContract.MintContract_NoPendingTreasurySafe.selector);
        mintContract.cancelTreasurySafe();

        vm.prank(safe);
        mintContract.setTreasurySafe(address(0xC0FFEE));
        vm.prank(stranger);
        vm.expectRevert();
        mintContract.cancelTreasurySafe();
    }

    function test_M03_ReproposeResetsClock() public {
        vm.prank(safe);
        mintContract.setTreasurySafe(address(0xC0FFEE));
        vm.warp(block.timestamp + 20 hours);
        vm.prank(safe);
        mintContract.setTreasurySafe(address(0xBEEF));
        assertEq(mintContract.pendingTreasurySafe(), address(0xBEEF));
        assertEq(mintContract.pendingTreasurySafeExecutableAt(), block.timestamp + 24 hours);

        vm.warp(block.timestamp + 4 hours); // 24h since first proposal, only 4h since second
        vm.prank(safe);
        vm.expectRevert(MintContract.MintContract_TreasurySafeDelayNotElapsed.selector);
        mintContract.executeTreasurySafe();
    }

    function test_M03_ProposeZero_Reverts() public {
        vm.prank(safe);
        vm.expectRevert(MintContract.MintContract_ZeroAddress.selector);
        mintContract.setTreasurySafe(address(0));
    }

    // ======================================================================
    // Coverage: whitelisting a token without decimals() must revert (decimals reported as 0)
    // ======================================================================

    function test_SetStablecoinAccepted_RevertWhenNoDecimalsFunction() public {
        // IndexOracle has no decimals(); the try/catch path must map to UnexpectedDecimals(token, 0).
        vm.prank(safe);
        vm.expectRevert(
            abi.encodeWithSelector(MintContract.MintContract_UnexpectedDecimals.selector, address(oracle), uint8(0))
        );
        mintContract.setStablecoinAccepted(address(oracle), true);
    }

    // ======================================================================
    // L-04 — lockMinterRole(expectedMinter): lock refuses to seal the wrong minter set
    // ======================================================================

    function test_L04_LockWithCorrectMinter_Succeeds() public {
        vm.prank(safe);
        slt.lockMinterRole(address(mintContract));
        assertTrue(slt.minterRoleLocked());
    }

    function test_L04_LockWithWrongMinter_Reverts() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(SLT.SLT_UnexpectedMinter.selector, alice));
        slt.lockMinterRole(alice);
        assertFalse(slt.minterRoleLocked());
    }

    function test_L04_LockWithZero_Reverts() public {
        vm.prank(safe);
        vm.expectRevert(SLT.SLT_ZeroAddress.selector);
        slt.lockMinterRole(address(0));
    }

    function test_L04_LockRefusesWhenExtraMinterPresent() public {
        // Expected minter holds the role, but a second (unexpected) minter exists → refuse to seal.
        vm.startPrank(safe);
        slt.grantRole(slt.MINTER_ROLE(), alice);
        vm.expectRevert(abi.encodeWithSelector(SLT.SLT_MinterCountNotOne.selector, 2));
        slt.lockMinterRole(address(mintContract));
        vm.stopPrank();
    }

    function test_L04_LockRefusesWhenExpectedMinterLacksRole() public {
        vm.startPrank(safe);
        slt.revokeRole(slt.MINTER_ROLE(), address(mintContract));
        vm.expectRevert(abi.encodeWithSelector(SLT.SLT_UnexpectedMinter.selector, address(mintContract)));
        slt.lockMinterRole(address(mintContract));
        vm.stopPrank();
    }

    // ======================================================================
    // v1.1.1 — M-4: lockMinterRole must point at a MintContract wired to THIS token
    // ======================================================================

    function test_M4_LockMinterRole_RefusesEOA() public {
        bytes32 minter = slt.MINTER_ROLE();
        vm.startPrank(safe);
        slt.revokeRole(minter, address(mintContract));
        slt.grantRole(minter, alice); // EOA is the sole minter
        vm.expectRevert(abi.encodeWithSelector(SLT.SLT_MinterNotWiredToThisToken.selector, alice));
        slt.lockMinterRole(alice);
        vm.stopPrank();
        assertFalse(slt.minterRoleLocked());
    }

    function test_M4_LockMinterRole_RefusesMintContractOfAnotherToken() public {
        SLT otherSlt = new SLT(safe, pauser, address(oracle));
        MintContract foreign = new MintContract(
            address(otherSlt), address(oracle), safe, safe, pauser, MIN_MINT, MAX_MINT, _arr(address(usdc))
        );
        bytes32 minter = slt.MINTER_ROLE();
        vm.startPrank(safe);
        slt.revokeRole(minter, address(mintContract));
        slt.grantRole(minter, address(foreign));
        vm.expectRevert(abi.encodeWithSelector(SLT.SLT_MinterNotWiredToThisToken.selector, address(foreign)));
        slt.lockMinterRole(address(foreign));
        vm.stopPrank();
    }

    function test_M4_LockMinterRole_RefusesContractWithoutSlt() public {
        bytes32 minter = slt.MINTER_ROLE();
        vm.startPrank(safe);
        slt.revokeRole(minter, address(mintContract));
        slt.grantRole(minter, address(usdc)); // a contract, but no slt()
        vm.expectRevert(abi.encodeWithSelector(SLT.SLT_MinterNotWiredToThisToken.selector, address(usdc)));
        slt.lockMinterRole(address(usdc));
        vm.stopPrank();
    }

    // ======================================================================
    // v1.1.1 — minterCount bookkeeping (revoke / idempotent grant / renounce)
    // ======================================================================

    function test_MinterCount_RevokeDecrementsAndLockSucceeds() public {
        bytes32 minter = slt.MINTER_ROLE();
        vm.startPrank(safe);
        slt.grantRole(minter, alice);
        assertEq(slt.minterCount(), 2);
        slt.revokeRole(minter, alice);
        assertEq(slt.minterCount(), 1);
        slt.lockMinterRole(address(mintContract));
        vm.stopPrank();
        assertTrue(slt.minterRoleLocked());
    }

    function test_MinterCount_DoubleGrantIsIdempotent() public {
        bytes32 minter = slt.MINTER_ROLE();
        vm.prank(safe);
        slt.grantRole(minter, address(mintContract)); // already a minter
        assertEq(slt.minterCount(), 1);
        vm.prank(safe);
        slt.revokeRole(minter, alice); // not a minter: no underflow
        assertEq(slt.minterCount(), 1);
    }

    function test_MinterCount_RenounceDecrements() public {
        bytes32 minter = slt.MINTER_ROLE();
        vm.prank(safe);
        slt.grantRole(minter, alice);
        assertEq(slt.minterCount(), 2);
        vm.prank(alice);
        slt.renounceRole(minter, alice);
        assertEq(slt.minterCount(), 1);
        vm.prank(safe);
        slt.lockMinterRole(address(mintContract));
        assertTrue(slt.minterRoleLocked());
    }

    function test_MinterCount_ZeroMintersCannotLock() public {
        bytes32 minter = slt.MINTER_ROLE();
        vm.startPrank(safe);
        slt.revokeRole(minter, address(mintContract));
        assertEq(slt.minterCount(), 0);
        vm.expectRevert(abi.encodeWithSelector(SLT.SLT_UnexpectedMinter.selector, address(mintContract)));
        slt.lockMinterRole(address(mintContract));
        vm.stopPrank();
    }

    // ======================================================================
    // v1.1.1 — H-1: stablecoin whitelist additions are timelocked (24h); removals immediate
    // ======================================================================

    event StablecoinProposed(address indexed token, uint256 executableAt);
    event StablecoinProposalCancelled(address indexed token);
    event StablecoinWhitelistUpdated(address indexed token, bool accepted);

    function test_H1_ConstructorSeedsWhitelist() public view {
        assertTrue(mintContract.acceptedStablecoin(address(usdc)));
        assertEq(mintContract.STABLECOIN_DELAY(), 24 hours);
    }

    function test_H1_ConstructorRejectsNonSixDecimals() public {
        vm.expectRevert(
            abi.encodeWithSelector(MintContract.MintContract_UnexpectedDecimals.selector, address(oracle), uint8(0))
        );
        new MintContract(address(slt), address(oracle), safe, safe, pauser, MIN_MINT, MAX_MINT, _arr(address(oracle)));
    }

    function test_H1_ConstructorRejectsZeroStablecoin() public {
        vm.expectRevert(MintContract.MintContract_ZeroAddress.selector);
        new MintContract(address(slt), address(oracle), safe, safe, pauser, MIN_MINT, MAX_MINT, _arr(address(0)));
    }

    function test_H1_ProposeDoesNotWhitelistImmediately() public {
        MockStable usdt = new MockStable("Tether", "USDT");
        vm.expectEmit(true, false, false, true, address(mintContract));
        emit StablecoinProposed(address(usdt), block.timestamp + 24 hours);
        vm.prank(safe);
        mintContract.setStablecoinAccepted(address(usdt), true);
        assertFalse(mintContract.acceptedStablecoin(address(usdt)), "whitelisted instantly");
        assertEq(mintContract.pendingStablecoinExecutableAt(address(usdt)), block.timestamp + 24 hours);

        usdt.mint(alice, MIN_MINT);
        vm.startPrank(alice);
        usdt.approve(address(mintContract), MIN_MINT);
        vm.expectRevert(abi.encodeWithSelector(MintContract.MintContract_StablecoinNotAccepted.selector, address(usdt)));
        mintContract.mintSLT(address(usdt), MIN_MINT);
        vm.stopPrank();
    }

    function test_H1_ExecuteBeforeDelayReverts_AfterDelaySucceeds() public {
        MockStable usdt = new MockStable("Tether", "USDT");
        vm.startPrank(safe);
        mintContract.setStablecoinAccepted(address(usdt), true);
        vm.warp(block.timestamp + 24 hours - 1);
        vm.expectRevert(
            abi.encodeWithSelector(MintContract.MintContract_StablecoinDelayNotElapsed.selector, address(usdt))
        );
        mintContract.executeStablecoinAccepted(address(usdt));
        vm.warp(block.timestamp + 1);
        vm.expectEmit(true, false, false, true, address(mintContract));
        emit StablecoinWhitelistUpdated(address(usdt), true);
        mintContract.executeStablecoinAccepted(address(usdt));
        vm.stopPrank();
        assertTrue(mintContract.acceptedStablecoin(address(usdt)));
        assertEq(mintContract.pendingStablecoinExecutableAt(address(usdt)), 0);
    }

    function test_H1_ExecuteWithoutProposalReverts() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(MintContract.MintContract_NoPendingStablecoin.selector, alice));
        mintContract.executeStablecoinAccepted(alice);
    }

    function test_H1_CancelClearsProposal() public {
        MockStable usdt = new MockStable("Tether", "USDT");
        vm.startPrank(safe);
        mintContract.setStablecoinAccepted(address(usdt), true);
        vm.expectEmit(true, false, false, true, address(mintContract));
        emit StablecoinProposalCancelled(address(usdt));
        mintContract.cancelStablecoinProposal(address(usdt));
        assertEq(mintContract.pendingStablecoinExecutableAt(address(usdt)), 0);
        vm.warp(block.timestamp + 24 hours);
        vm.expectRevert(abi.encodeWithSelector(MintContract.MintContract_NoPendingStablecoin.selector, address(usdt)));
        mintContract.executeStablecoinAccepted(address(usdt));
        vm.expectRevert(abi.encodeWithSelector(MintContract.MintContract_NoPendingStablecoin.selector, address(usdt)));
        mintContract.cancelStablecoinProposal(address(usdt));
        vm.stopPrank();
    }

    function test_H1_DelistIsImmediateAndCancelsPending() public {
        vm.startPrank(safe);
        mintContract.setStablecoinAccepted(address(usdc), true); // re-propose an already listed token
        assertGt(mintContract.pendingStablecoinExecutableAt(address(usdc)), 0);
        vm.expectEmit(true, false, false, true, address(mintContract));
        emit StablecoinWhitelistUpdated(address(usdc), false);
        mintContract.setStablecoinAccepted(address(usdc), false);
        vm.stopPrank();
        assertFalse(mintContract.acceptedStablecoin(address(usdc)));
        assertEq(mintContract.pendingStablecoinExecutableAt(address(usdc)), 0, "pending cleared by delist");
    }

    function test_H1_ExecuteRechecksDecimals() public {
        MutableDecimalsToken t = new MutableDecimalsToken();
        vm.startPrank(safe);
        mintContract.setStablecoinAccepted(address(t), true); // 6 dec at proposal
        t.setDecimals(18); // token "upgrades" during the delay
        vm.warp(block.timestamp + 24 hours);
        vm.expectRevert(
            abi.encodeWithSelector(MintContract.MintContract_UnexpectedDecimals.selector, address(t), uint8(18))
        );
        mintContract.executeStablecoinAccepted(address(t));
        vm.stopPrank();
    }

    function test_H1_OnlyConfigRole() public {
        vm.startPrank(stranger);
        vm.expectRevert();
        mintContract.setStablecoinAccepted(alice, true);
        vm.expectRevert();
        mintContract.executeStablecoinAccepted(alice);
        vm.expectRevert();
        mintContract.cancelStablecoinProposal(alice);
        vm.stopPrank();
    }

    // ======================================================================
    // v1.1.1 — M-1: mintSLT(stable, amount, minSltOut, deadline)
    // ======================================================================

    function test_M1_FourArgMint_HappyPath() public {
        usdc.mint(alice, MIN_MINT);
        vm.startPrank(alice);
        usdc.approve(address(mintContract), MIN_MINT);
        uint256 got = mintContract.mintSLT(address(usdc), MIN_MINT, 1_000 ether, block.timestamp);
        vm.stopPrank();
        assertEq(got, 1_000 ether);
        assertEq(slt.balanceOf(alice), 1_000 ether);
    }

    function test_M1_FourArgMint_RevertOnSlippage() public {
        usdc.mint(alice, MIN_MINT);
        vm.startPrank(alice);
        usdc.approve(address(mintContract), MIN_MINT);
        vm.expectRevert(
            abi.encodeWithSelector(MintContract.MintContract_SlippageExceeded.selector, 1_000 ether, 1_000 ether + 1)
        );
        mintContract.mintSLT(address(usdc), MIN_MINT, 1_000 ether + 1, block.timestamp + 1);
        vm.stopPrank();
    }

    function test_M1_FourArgMint_RevertOnDeadline() public {
        usdc.mint(alice, MIN_MINT);
        vm.startPrank(alice);
        usdc.approve(address(mintContract), MIN_MINT);
        vm.expectRevert(MintContract.MintContract_DeadlineExpired.selector);
        mintContract.mintSLT(address(usdc), MIN_MINT, 0, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_M1_TwoArgMint_StillWorks_NoFloor() public {
        uint256 got = _mintTo(alice, MIN_MINT);
        assertEq(got, 1_000 ether);
    }

    // ======================================================================
    // v1.1.1 — L-6: Treasury Safe must receive the full amount (fee-on-transfer guard)
    // ======================================================================

    function test_L6_FeeOnTransferTokenReverts() public {
        FeeToken fee = new FeeToken();
        vm.startPrank(safe);
        mintContract.setStablecoinAccepted(address(fee), true);
        vm.warp(block.timestamp + 24 hours);
        mintContract.executeStablecoinAccepted(address(fee));
        vm.stopPrank();

        fee.mint(alice, MIN_MINT);
        vm.startPrank(alice);
        fee.approve(address(mintContract), MIN_MINT);
        vm.expectRevert(
            abi.encodeWithSelector(
                MintContract.MintContract_TransferShortfall.selector, MIN_MINT, MIN_MINT - MIN_MINT / 100
            )
        );
        mintContract.mintSLT(address(fee), MIN_MINT);
        vm.stopPrank();
        assertEq(slt.totalSupply(), 0);
    }

    // ======================================================================
    // v1.1.1 — L-5: setTreasurySafe rejects self / token / current safe
    // ======================================================================

    function test_L5_SetTreasurySafe_RejectsSelfTokenAndCurrent() public {
        vm.startPrank(safe);
        vm.expectRevert(
            abi.encodeWithSelector(MintContract.MintContract_InvalidTreasurySafe.selector, address(mintContract))
        );
        mintContract.setTreasurySafe(address(mintContract));
        vm.expectRevert(abi.encodeWithSelector(MintContract.MintContract_InvalidTreasurySafe.selector, address(slt)));
        mintContract.setTreasurySafe(address(slt));
        vm.expectRevert(abi.encodeWithSelector(MintContract.MintContract_InvalidTreasurySafe.selector, safe));
        mintContract.setTreasurySafe(safe);
        vm.stopPrank();
    }

    // ======================================================================
    // v1.1.1 — L-1 / L-2: exact bound, initial index band
    // ======================================================================

    function test_L1_BoundIsExact_501bpsRejected_500bpsAccepted() public {
        vm.warp(block.timestamp + 20 hours);
        vm.prank(updater);
        vm.expectRevert(abi.encodeWithSelector(IndexOracle.IndexOracle_OutOfBounds.selector, 1.0501e18, 1e18, 500));
        oracle.updateIndex(1.0501e18);
        vm.prank(updater);
        oracle.updateIndex(1.05e18);
        assertEq(oracle.pricePerShare(), 1.05e18);
    }

    function test_L1_BoundIsExact_OneWeiOverFivePercentRejected() public {
        vm.warp(block.timestamp + 20 hours);
        vm.prank(updater);
        vm.expectRevert(abi.encodeWithSelector(IndexOracle.IndexOracle_OutOfBounds.selector, 1.05e18 + 1, 1e18, 500));
        oracle.updateIndex(1.05e18 + 1);
    }

    function test_L2_InitialIndexBand() public {
        vm.expectRevert(abi.encodeWithSelector(IndexOracle.IndexOracle_InitialIndexOutOfRange.selector, 1e17 - 1));
        new IndexOracle(1e17 - 1, safe, guardian, updater);
        vm.expectRevert(abi.encodeWithSelector(IndexOracle.IndexOracle_InitialIndexOutOfRange.selector, 1e19 + 1));
        new IndexOracle(1e19 + 1, safe, guardian, updater);
        IndexOracle lo = new IndexOracle(1e17, safe, guardian, updater);
        IndexOracle hi = new IndexOracle(1e19, safe, guardian, updater);
        assertEq(lo.pricePerShare(), 1e17);
        assertEq(hi.pricePerShare(), 1e19);
    }

    // ======================================================================
    // v1.1.1 — time boundaries pinned (throttle, grace, M-02 slack)
    // ======================================================================

    function test_Time_UpdateAtExactly20hSucceeds_OneSecondEarlyReverts() public {
        uint256 t0 = oracle.lastUpdateTimestamp();
        vm.warp(t0 + 20 hours - 1);
        vm.prank(updater);
        vm.expectRevert(abi.encodeWithSelector(IndexOracle.IndexOracle_TooSoon.selector, t0, 20 hours));
        oracle.updateIndex(1.01e18);
        vm.warp(t0 + 20 hours);
        vm.prank(updater);
        oracle.updateIndex(1.01e18);
        assertEq(oracle.pricePerShare(), 1.01e18);
    }

    function test_Time_FreshAtExactlyGrace_StaleOneSecondLater() public {
        uint256 t0 = oracle.lastUpdateTimestamp();
        vm.warp(t0 + 1 days);
        assertTrue(oracle.isFresh(), "fresh at == grace");
        vm.warp(t0 + 1 days + 1);
        assertFalse(oracle.isFresh(), "stale at grace + 1");
    }

    function test_Time_SlackMeansUpdaterHas4hWindow() public {
        uint256 t0 = oracle.lastUpdateTimestamp();
        vm.warp(t0 + 20 hours + 4 hours);
        assertTrue(oracle.isFresh(), "still fresh at the end of the slack window");
        vm.prank(updater);
        oracle.updateIndex(1.01e18);
        assertTrue(oracle.isFresh());
    }

    function test_Time_SetMinUpdateInterval_Exactly20hOk_20hPlus1Reverts_WithDefaultGrace() public {
        vm.startPrank(safe);
        oracle.setMinUpdateInterval(20 hours);
        vm.expectRevert(IndexOracle.IndexOracle_InvalidConfig.selector);
        oracle.setMinUpdateInterval(20 hours + 1);
        vm.stopPrank();
    }

    // ======================================================================
    // v1.1.1 — events for the L-03 oracle setters + MinterRoleLocked + MintLimitsUpdated
    // ======================================================================

    event MaxChangeBpsUpdated(uint256 oldValue, uint256 newValue);
    event GracePeriodUpdated(uint256 oldValue, uint256 newValue);
    event MinUpdateIntervalUpdated(uint256 oldValue, uint256 newValue);
    event MinterRoleLocked(address indexed caller);
    event MintLimitsUpdated(uint256 minAmount, uint256 maxAmount);

    function test_Events_OracleSetters() public {
        vm.startPrank(safe);
        vm.expectEmit(false, false, false, true, address(oracle));
        emit MaxChangeBpsUpdated(500, 250);
        oracle.setMaxChangeBps(250);
        vm.expectEmit(false, false, false, true, address(oracle));
        emit GracePeriodUpdated(1 days, 2 days);
        oracle.setGracePeriod(2 days);
        vm.expectEmit(false, false, false, true, address(oracle));
        emit MinUpdateIntervalUpdated(20 hours, 1 days);
        oracle.setMinUpdateInterval(1 days);
        vm.stopPrank();
    }

    function test_Events_MinterRoleLocked_And_MintLimits() public {
        vm.expectEmit(true, false, false, true, address(slt));
        emit MinterRoleLocked(safe);
        vm.prank(safe);
        slt.lockMinterRole(address(mintContract));

        vm.expectEmit(false, false, false, true, address(mintContract));
        emit MintLimitsUpdated(2_000e6, 10_000e6);
        vm.prank(safe);
        mintContract.setMintLimits(2_000e6, 10_000e6);
    }
}

/// @dev 6-decimal token whose decimals can be changed after deployment (simulates an upgrade).
contract MutableDecimalsToken is ERC20 {
    uint8 internal _dec = 6;

    constructor() ERC20("Mutable", "MUT") {}

    function setDecimals(
        uint8 d
    ) external {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }
}

/// @dev 6-decimal token that burns 1% on every transferFrom (fee-on-transfer).
contract FeeToken is MockStable {
    constructor() MockStable("Fee", "FEE") {}

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        uint256 fee = amount / 100;
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount - fee);
        _burn(from, fee);
        return true;
    }
}
