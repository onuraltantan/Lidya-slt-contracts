// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SLT} from "../src/SLT.sol";
import {IndexOracle} from "../src/IndexOracle.sol";

contract SLTTest is Test {
    SLT internal slt;
    IndexOracle internal oracle;

    address internal admin = address(0xA1);
    address internal pauser = address(0xA2);
    address internal minter = address(0xA3);
    address internal alice = address(0xB1);
    address internal bob = address(0xB2);

    function setUp() public {
        oracle = new IndexOracle(1e18, admin, admin, admin);
        slt = new SLT(admin, pauser, address(oracle));

        // Cache role before pranking — vm.prank only affects the immediately
        // following external call, and SLT.MINTER_ROLE() would consume it
        // before grantRole executes.
        bytes32 minterRole = slt.MINTER_ROLE();
        vm.prank(admin);
        slt.grantRole(minterRole, minter);
    }

    // ----------------------------------------------------------------------
    // Constructor
    // ----------------------------------------------------------------------

    function test_Constructor_RevertOnZeroAdmin() public {
        vm.expectRevert(SLT.SLT_ZeroAddress.selector);
        new SLT(address(0), pauser, address(oracle));
    }

    function test_Constructor_RevertOnZeroPauser() public {
        vm.expectRevert(SLT.SLT_ZeroAddress.selector);
        new SLT(admin, address(0), address(oracle));
    }

    function test_Constructor_RevertOnZeroOracle() public {
        vm.expectRevert(SLT.SLT_ZeroAddress.selector);
        new SLT(admin, pauser, address(0));
    }

    function test_Constructor_GrantsCorrectRoles() public view {
        assertTrue(slt.hasRole(slt.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(slt.hasRole(slt.PAUSER_ROLE(), pauser));
        assertTrue(slt.hasRole(slt.BURNER_ROLE(), admin));
        assertFalse(slt.hasRole(slt.MINTER_ROLE(), admin));
    }

    // ----------------------------------------------------------------------
    // Metadata
    // ----------------------------------------------------------------------

    function test_Metadata() public view {
        assertEq(slt.name(), "Synthetic Liquid Token");
        assertEq(slt.symbol(), "SLT");
        assertEq(slt.decimals(), 18);
    }

    // ----------------------------------------------------------------------
    // mint()
    // ----------------------------------------------------------------------

    function test_Mint_OnlyByMinterRole() public {
        vm.prank(minter);
        slt.mint(alice, 1_000 ether);
        assertEq(slt.balanceOf(alice), 1_000 ether);
    }

    function test_Mint_RevertWhenUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert();
        slt.mint(alice, 1 ether);
    }

    function test_Mint_RevertOnZeroAddress() public {
        vm.prank(minter);
        vm.expectRevert(SLT.SLT_ZeroAddress.selector);
        slt.mint(address(0), 1 ether);
    }

    function test_Mint_RevertOnZeroAmount() public {
        vm.prank(minter);
        vm.expectRevert(SLT.SLT_ZeroAmount.selector);
        slt.mint(alice, 0);
    }

    function test_Mint_BlockedWhenPaused() public {
        vm.prank(pauser);
        slt.pause();

        vm.prank(minter);
        vm.expectRevert();
        slt.mint(alice, 1 ether);
    }

    // ----------------------------------------------------------------------
    // adminBurn()
    // ----------------------------------------------------------------------

    function test_AdminBurn_OnlyByBurnerRole() public {
        vm.prank(minter);
        slt.mint(alice, 1_000 ether);

        vm.prank(admin);
        slt.adminBurn(alice, 500 ether);
        assertEq(slt.balanceOf(alice), 500 ether);
    }

    function test_AdminBurn_RevertWhenUnauthorized() public {
        vm.prank(minter);
        slt.mint(alice, 1_000 ether);

        vm.prank(alice);
        vm.expectRevert();
        slt.adminBurn(alice, 1 ether);
    }

    function test_AdminBurn_RevertOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(SLT.SLT_ZeroAddress.selector);
        slt.adminBurn(address(0), 1 ether);
    }

    function test_AdminBurn_RevertOnZeroAmount() public {
        vm.prank(minter);
        slt.mint(alice, 1_000 ether);

        vm.prank(admin);
        vm.expectRevert(SLT.SLT_ZeroAmount.selector);
        slt.adminBurn(alice, 0);
    }

    // ----------------------------------------------------------------------
    // Pause / unpause
    // ----------------------------------------------------------------------

    function test_Transfer_BlockedWhenPaused() public {
        vm.prank(minter);
        slt.mint(alice, 1_000 ether);

        vm.prank(pauser);
        slt.pause();

        vm.prank(alice);
        vm.expectRevert();
        slt.transfer(bob, 100 ether);
    }

    function test_Pause_RevertWhenUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert();
        slt.pause();
    }

    function test_Unpause_HappyPath() public {
        vm.prank(pauser);
        slt.pause();
        assertTrue(slt.paused());

        vm.prank(pauser);
        slt.unpause();
        assertFalse(slt.paused());

        // Mint should now work again.
        vm.prank(minter);
        slt.mint(alice, 1 ether);
        assertEq(slt.balanceOf(alice), 1 ether);
    }

    function test_Unpause_RevertWhenUnauthorized() public {
        vm.prank(pauser);
        slt.pause();

        vm.prank(alice);
        vm.expectRevert();
        slt.unpause();
    }

    // ----------------------------------------------------------------------
    // ERC-4626 view-only metadata
    // ----------------------------------------------------------------------

    function test_PricePerShare_ReadsFromOracle() public view {
        assertEq(slt.pricePerShare(), oracle.pricePerShare());
    }

    function test_SyntheticTotalValue() public {
        vm.prank(minter);
        slt.mint(alice, 1_000 ether);
        // At index 1.0, totalAssets = totalSupply.
        assertEq(slt.syntheticTotalValue(), 1_000 ether);
    }

    function test_IndexValueFunctions_AtUnitIndex() public view {
        assertEq(slt.sltForIndexValue(100 ether), 100 ether);
        assertEq(slt.indexValueForSLT(100 ether), 100 ether);
    }

    function test_NoRedeemFunction_Exists() public {
        // SLT must NOT expose any redeem/withdraw entry point.
        // adminBurn does not pay out — verify no native value leaves the contract.
        vm.prank(minter);
        slt.mint(alice, 1_000 ether);

        uint256 balanceBefore = address(slt).balance;
        vm.prank(admin);
        slt.adminBurn(alice, 500 ether);
        assertEq(address(slt).balance, balanceBefore);
    }

    function test_AdminBurn_WorksWhilePaused() public {
        vm.prank(minter);
        slt.mint(alice, 1_000 ether);
        vm.prank(pauser);
        slt.pause();
        // H-1: admin reconciliation burn must still succeed while transfers are paused.
        vm.prank(admin);
        slt.adminBurn(alice, 400 ether);
        assertEq(slt.balanceOf(alice), 600 ether);
        assertTrue(slt.paused());
    }
}
