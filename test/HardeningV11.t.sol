// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SLT} from "../src/SLT.sol";
import {IndexOracle} from "../src/IndexOracle.sol";
import {MintContract} from "../src/MintContract.sol";
import {MockStable} from "./invariants/Handler.sol";

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

    function setUp() public {
        oracle = new IndexOracle(1e18, safe, guardian, updater);
        slt = new SLT(safe, pauser, address(oracle));
        usdc = new MockStable("USD Coin", "USDC");
        mintContract = new MintContract(address(slt), address(oracle), safe, safe, pauser, MIN_MINT, MAX_MINT);

        vm.startPrank(safe);
        slt.grantRole(slt.MINTER_ROLE(), address(mintContract));
        mintContract.setStablecoinAccepted(address(usdc), true);
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
        slt.lockBurnSource();
        slt.setBurnSource(alice, false);
        slt.lockBurnSource(); // exactly {Treasury Safe} -> ok
        vm.stopPrank();
        assertTrue(slt.burnSourceLocked());
        assertEq(slt.burnSourceCount(), 1);
    }

    function test_M01_LockBurnSource_RefusesWhenTreasuryRemoved() public {
        vm.startPrank(safe);
        slt.setBurnSource(safe, false);
        vm.expectRevert(abi.encodeWithSelector(SLT.SLT_BurnSourceCountNotOne.selector, 0));
        slt.lockBurnSource();
        vm.stopPrank();
    }

    function test_M01_LockBurnSource_OnlyAdmin() public {
        vm.prank(stranger);
        vm.expectRevert();
        slt.lockBurnSource();
    }

    function test_M01_LockBurnSource_OnlyOnce() public {
        vm.prank(safe);
        slt.lockBurnSource();
        vm.prank(safe);
        vm.expectRevert(SLT.SLT_BurnSourceAlreadyLocked.selector);
        slt.lockBurnSource();
    }

    function test_M01_LockBurnSource_EmitsAndSetsFlag() public {
        vm.expectEmit(true, false, false, false);
        emit BurnSourceLocked(safe);
        vm.prank(safe);
        slt.lockBurnSource();
        assertTrue(slt.burnSourceLocked());
    }

    function test_M01_LockBurnSource_BlocksSetBurnSource_Add() public {
        vm.prank(safe);
        slt.lockBurnSource();
        vm.prank(safe);
        vm.expectRevert(SLT.SLT_BurnSourceLocked.selector);
        slt.setBurnSource(alice, true);
    }

    function test_M01_LockBurnSource_BlocksSetBurnSource_Remove() public {
        vm.prank(safe);
        slt.lockBurnSource();
        vm.prank(safe);
        vm.expectRevert(SLT.SLT_BurnSourceLocked.selector);
        slt.setBurnSource(safe, false);
    }

    function test_M01_AdminBurnFromTreasuryStillWorksAfterLock() public {
        // Treasury-held inventory (e.g. erroneous mint sent to Safe) is reconcilable post-lock.
        vm.prank(address(mintContract));
        slt.mint(safe, 100 ether);
        vm.prank(safe);
        slt.lockBurnSource();
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
        slt.lockBurnSource();

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
}
