// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IndexOracle} from "../src/IndexOracle.sol";

contract IndexOracleTest is Test {
    IndexOracle internal oracle;

    address internal admin = address(0xA1);
    address internal guardian = address(0xA2);
    address internal updater = address(0xA3);
    address internal stranger = address(0xBAD);

    uint256 internal constant INITIAL_INDEX = 1e18;

    function setUp() public {
        oracle = new IndexOracle(INITIAL_INDEX, admin, guardian, updater);
    }

    // ----------------------------------------------------------------------
    // Constructor
    // ----------------------------------------------------------------------

    function test_Constructor_RevertOnZeroInitialIndex() public {
        vm.expectRevert(IndexOracle.IndexOracle_ZeroIndex.selector);
        new IndexOracle(0, admin, guardian, updater);
    }

    function test_Constructor_RevertOnZeroAdmin() public {
        vm.expectRevert(IndexOracle.IndexOracle_InvalidConfig.selector);
        new IndexOracle(INITIAL_INDEX, address(0), guardian, updater);
    }

    function test_Constructor_RevertOnZeroGuardian() public {
        vm.expectRevert(IndexOracle.IndexOracle_InvalidConfig.selector);
        new IndexOracle(INITIAL_INDEX, admin, address(0), updater);
    }

    function test_Constructor_RevertOnZeroUpdater() public {
        vm.expectRevert(IndexOracle.IndexOracle_InvalidConfig.selector);
        new IndexOracle(INITIAL_INDEX, admin, guardian, address(0));
    }

    function test_ConstructorSetsInitialIndex() public view {
        assertEq(oracle.pricePerShare(), INITIAL_INDEX);
        assertTrue(oracle.isFresh());
    }

    function test_Constructor_GrantsCorrectRoles() public view {
        assertTrue(oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(oracle.hasRole(oracle.GUARDIAN_ROLE(), guardian));
        assertTrue(oracle.hasRole(oracle.ORACLE_UPDATER_ROLE(), updater));
    }

    function test_Constructor_DefaultParams() public view {
        assertEq(oracle.maxChangeBps(), 500);
        assertEq(oracle.gracePeriod(), 1 days);
        assertEq(oracle.minUpdateInterval(), 1 hours);
    }

    // ----------------------------------------------------------------------
    // updateIndex()
    // ----------------------------------------------------------------------

    function test_UpdateIndex_HappyPath() public {
        skip(1 hours + 1);
        uint256 newIndex = (INITIAL_INDEX * 1003) / 1000; // +0.3%

        vm.prank(updater);
        oracle.updateIndex(newIndex);

        assertEq(oracle.pricePerShare(), newIndex);
    }

    function test_UpdateIndex_DownwardAlsoBounded() public {
        skip(1 hours + 1);
        uint256 newIndex = (INITIAL_INDEX * 997) / 1000; // -0.3%

        vm.prank(updater);
        oracle.updateIndex(newIndex);

        assertEq(oracle.pricePerShare(), newIndex);
    }

    function test_UpdateIndex_RevertOnExceedingMaxDelta() public {
        skip(1 hours + 1);
        uint256 newIndex = (INITIAL_INDEX * 11) / 10; // +10%, max is 5%

        vm.prank(updater);
        vm.expectRevert();
        oracle.updateIndex(newIndex);
    }

    function test_UpdateIndex_RevertOnExceedingMaxDeltaDownward() public {
        skip(1 hours + 1);
        uint256 newIndex = (INITIAL_INDEX * 9) / 10; // -10%, max is 5%

        vm.prank(updater);
        vm.expectRevert();
        oracle.updateIndex(newIndex);
    }

    function test_UpdateIndex_RevertOnTooFrequent() public {
        skip(1 hours + 1);
        vm.prank(updater);
        oracle.updateIndex(INITIAL_INDEX + 1e15);

        skip(10 minutes);
        vm.prank(updater);
        vm.expectRevert();
        oracle.updateIndex(INITIAL_INDEX + 2e15);
    }

    function test_UpdateIndex_RevertOnZero() public {
        skip(1 hours + 1);
        vm.prank(updater);
        vm.expectRevert(IndexOracle.IndexOracle_ZeroIndex.selector);
        oracle.updateIndex(0);
    }

    function test_UpdateIndex_RevertOnUnauthorized() public {
        skip(1 hours + 1);
        vm.prank(stranger);
        vm.expectRevert();
        oracle.updateIndex(INITIAL_INDEX);
    }

    // ----------------------------------------------------------------------
    // Pause / unpause
    // ----------------------------------------------------------------------

    function test_Pause_BlocksUpdates() public {
        vm.prank(guardian);
        oracle.pause("incident_under_review");

        skip(1 hours + 1);
        vm.prank(updater);
        vm.expectRevert();
        oracle.updateIndex(INITIAL_INDEX + 1e15);
    }

    function test_Pause_RevertWhenUnauthorized() public {
        vm.prank(stranger);
        vm.expectRevert();
        oracle.pause("malicious");
    }

    function test_Unpause_HappyPath() public {
        vm.prank(guardian);
        oracle.pause("incident");

        vm.prank(guardian);
        oracle.unpause();
        assertFalse(oracle.paused());

        skip(1 hours + 1);
        vm.prank(updater);
        oracle.updateIndex(INITIAL_INDEX + 1e15);
        assertEq(oracle.pricePerShare(), INITIAL_INDEX + 1e15);
    }

    function test_Unpause_RevertWhenUnauthorized() public {
        vm.prank(guardian);
        oracle.pause("incident");

        vm.prank(stranger);
        vm.expectRevert();
        oracle.unpause();
    }

    function test_IsFresh_FalseWhenPaused() public {
        vm.prank(guardian);
        oracle.pause("incident");
        assertFalse(oracle.isFresh());
    }

    function test_IsFresh_FalseAfterGracePeriod() public {
        skip(2 days);
        assertFalse(oracle.isFresh());
    }

    // ----------------------------------------------------------------------
    // Stable conversion
    // ----------------------------------------------------------------------

    function test_StableToSLT_RoundTrip() public view {
        uint256 stable = 1_000 * 1e6;
        uint256 sltAmt = oracle.stableToSLT(stable);
        assertEq(sltAmt, 1_000 * 1e18);
    }

    function test_SltToStable_RoundTrip() public view {
        uint256 sltAmt = 1_000 * 1e18;
        uint256 stable = oracle.sltToStable(sltAmt);
        assertEq(stable, 1_000 * 1e6);
    }

    function test_StableToSLT_ChangesWithIndex() public {
        skip(1 hours + 1);
        // Bump max bound to allow +20% jump for testing math at higher index.
        vm.prank(admin);
        oracle.setMaxChangeBps(2_000);
        skip(1 hours + 1);
        vm.prank(updater);
        oracle.updateIndex(12 * 1e17); // index = 1.2

        // At index 1.2, $1,200 should mint 1,000 SLT.
        uint256 sltAmt = oracle.stableToSLT(1_200 * 1e6);
        assertEq(sltAmt, 1_000 * 1e18);
    }

    // ----------------------------------------------------------------------
    // Admin parameter setters
    // ----------------------------------------------------------------------

    function test_SetMaxChangeBps_HappyPath() public {
        vm.prank(admin);
        oracle.setMaxChangeBps(1_000);
        assertEq(oracle.maxChangeBps(), 1_000);
    }

    function test_SetMaxChangeBps_RevertOnZero() public {
        vm.prank(admin);
        vm.expectRevert(IndexOracle.IndexOracle_InvalidConfig.selector);
        oracle.setMaxChangeBps(0);
    }

    function test_SetMaxChangeBps_RevertAboveCeiling() public {
        vm.prank(admin);
        vm.expectRevert(IndexOracle.IndexOracle_InvalidConfig.selector);
        oracle.setMaxChangeBps(2_001); // hard ceiling 20% (2000 bps)
    }

    function test_SetMaxChangeBps_RevertWhenUnauthorized() public {
        vm.prank(stranger);
        vm.expectRevert();
        oracle.setMaxChangeBps(1_000);
    }

    function test_SetGracePeriod_HappyPath() public {
        vm.prank(admin);
        oracle.setGracePeriod(2 days);
        assertEq(oracle.gracePeriod(), 2 days);
    }

    function test_SetGracePeriod_RevertBelowMin() public {
        vm.prank(admin);
        vm.expectRevert(IndexOracle.IndexOracle_InvalidConfig.selector);
        oracle.setGracePeriod(30 minutes);
    }

    function test_SetGracePeriod_RevertAboveMax() public {
        vm.prank(admin);
        vm.expectRevert(IndexOracle.IndexOracle_InvalidConfig.selector);
        oracle.setGracePeriod(8 days);
    }

    function test_SetGracePeriod_RevertWhenUnauthorized() public {
        vm.prank(stranger);
        vm.expectRevert();
        oracle.setGracePeriod(2 days);
    }

    function test_SetMinUpdateInterval_HappyPath() public {
        vm.prank(admin);
        oracle.setMinUpdateInterval(30 minutes);
        assertEq(oracle.minUpdateInterval(), 30 minutes);
    }

    function test_SetMinUpdateInterval_RevertAboveMax() public {
        vm.prank(admin);
        vm.expectRevert(IndexOracle.IndexOracle_InvalidConfig.selector);
        oracle.setMinUpdateInterval(2 days);
    }

    function test_SetMinUpdateInterval_RevertBelowFloor() public {
        vm.prank(admin);
        vm.expectRevert(IndexOracle.IndexOracle_InvalidConfig.selector);
        oracle.setMinUpdateInterval(30 seconds);
    }

    function test_SetMinUpdateInterval_RevertOnZero() public {
        vm.prank(admin);
        vm.expectRevert(IndexOracle.IndexOracle_InvalidConfig.selector);
        oracle.setMinUpdateInterval(0);
    }

    function test_SetMinUpdateInterval_RevertWhenUnauthorized() public {
        vm.prank(stranger);
        vm.expectRevert();
        oracle.setMinUpdateInterval(30 minutes);
    }

    // ----------------------------------------------------------------------
    // Fuzz
    // ----------------------------------------------------------------------

    function testFuzz_UpdateIndex_WithinBounds(uint256 deltaBps) public {
        deltaBps = bound(deltaBps, 1, 500);
        skip(1 hours + 1);
        uint256 newIndex = (INITIAL_INDEX * (10_000 + deltaBps)) / 10_000;

        vm.prank(updater);
        oracle.updateIndex(newIndex);
        assertEq(oracle.pricePerShare(), newIndex);
    }
}
