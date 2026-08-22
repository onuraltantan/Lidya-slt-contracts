// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SLT} from "../src/SLT.sol";
import {IndexOracle} from "../src/IndexOracle.sol";
import {MintContract} from "../src/MintContract.sol";

/// @notice Minimal mock USDC for tests (6 decimals).
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Reentrant token: tries to call mintSLT again from within transferFrom.
///         Used to verify the nonReentrant guard on MintContract.mintSLT().
contract ReentrantUSDC is ERC20 {
    MintContract public target;
    bool public attackArmed;

    constructor() ERC20("Reentrant USDC", "RUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(MintContract t) external {
        target = t;
        attackArmed = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (attackArmed && address(target) != address(0)) {
            attackArmed = false; // disarm to prevent infinite recursion in revert path
            // This nested call should revert with ReentrancyGuardReentrantCall().
            target.mintSLT(address(this), 1_000 * 1e6);
        }
        return super.transferFrom(from, to, amount);
    }
}

contract MintContractTest is Test {
    SLT internal slt;
    IndexOracle internal oracle;
    MintContract internal mintContract;
    MockUSDC internal usdc;

    address internal admin = address(0xA1);
    address internal pauser = address(0xA2);
    address internal treasurySafe = address(0xCAFE);
    address internal alice = address(0xB1);
    address internal stranger = address(0xBAD);

    uint256 internal constant MIN_MINT = 1_000 * 1e6; // $1,000
    uint256 internal constant MAX_MINT = 5_000_000 * 1e6; // $5,000,000

    function setUp() public {
        oracle = new IndexOracle(1e18, admin, admin, admin);
        slt = new SLT(admin, pauser, address(oracle));
        usdc = new MockUSDC();

        mintContract =
            new MintContract(address(slt), address(oracle), treasurySafe, admin, pauser, MIN_MINT, MAX_MINT);

        vm.startPrank(admin);
        slt.grantRole(slt.MINTER_ROLE(), address(mintContract));
        mintContract.setStablecoinAccepted(address(usdc), true);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------------
    // Constructor
    // ----------------------------------------------------------------------

    function test_Constructor_RevertOnZeroSltToken() public {
        vm.expectRevert(MintContract.MintContract_ZeroAddress.selector);
        new MintContract(address(0), address(oracle), treasurySafe, admin, pauser, MIN_MINT, MAX_MINT);
    }

    function test_Constructor_RevertOnZeroOracle() public {
        vm.expectRevert(MintContract.MintContract_ZeroAddress.selector);
        new MintContract(address(slt), address(0), treasurySafe, admin, pauser, MIN_MINT, MAX_MINT);
    }

    function test_Constructor_RevertOnZeroSafe() public {
        vm.expectRevert(MintContract.MintContract_ZeroAddress.selector);
        new MintContract(address(slt), address(oracle), address(0), admin, pauser, MIN_MINT, MAX_MINT);
    }

    function test_Constructor_RevertOnZeroAdmin() public {
        vm.expectRevert(MintContract.MintContract_ZeroAddress.selector);
        new MintContract(address(slt), address(oracle), treasurySafe, address(0), pauser, MIN_MINT, MAX_MINT);
    }

    function test_Constructor_RevertOnZeroMin() public {
        vm.expectRevert(MintContract.MintContract_InvalidLimits.selector);
        new MintContract(address(slt), address(oracle), treasurySafe, admin, pauser, 0, MAX_MINT);
    }

    function test_Constructor_RevertOnMinGreaterThanMax() public {
        vm.expectRevert(MintContract.MintContract_InvalidLimits.selector);
        new MintContract(address(slt), address(oracle), treasurySafe, admin, pauser, MAX_MINT + 1, MAX_MINT);
    }

    function test_Constructor_GrantsCorrectRoles() public view {
        assertTrue(mintContract.hasRole(mintContract.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(mintContract.hasRole(mintContract.CONFIG_ROLE(), admin));
        assertTrue(mintContract.hasRole(mintContract.PAUSER_ROLE(), pauser));
    }

    // ----------------------------------------------------------------------
    // mintSLT() — happy path & reverts
    // ----------------------------------------------------------------------

    function test_Mint_HappyPath() public {
        usdc.mint(alice, 10_000 * 1e6);

        vm.startPrank(alice);
        usdc.approve(address(mintContract), 10_000 * 1e6);
        uint256 minted = mintContract.mintSLT(address(usdc), 10_000 * 1e6);
        vm.stopPrank();

        assertEq(minted, 10_000 ether);
        assertEq(slt.balanceOf(alice), 10_000 ether);
        assertEq(usdc.balanceOf(treasurySafe), 10_000 * 1e6);
        assertEq(usdc.balanceOf(address(mintContract)), 0);
    }

    function test_Mint_RevertOnUnacceptedStablecoin() public {
        MockUSDC fakeStable = new MockUSDC();
        fakeStable.mint(alice, 10_000 * 1e6);

        vm.startPrank(alice);
        fakeStable.approve(address(mintContract), 10_000 * 1e6);
        vm.expectRevert();
        mintContract.mintSLT(address(fakeStable), 10_000 * 1e6);
        vm.stopPrank();
    }

    function test_Mint_RevertOnBelowMin() public {
        usdc.mint(alice, 100 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(mintContract), 100 * 1e6);
        vm.expectRevert();
        mintContract.mintSLT(address(usdc), 100 * 1e6);
        vm.stopPrank();
    }

    function test_Mint_RevertOnAboveMax() public {
        usdc.mint(alice, 10_000_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(mintContract), 10_000_000 * 1e6);
        vm.expectRevert();
        mintContract.mintSLT(address(usdc), 10_000_000 * 1e6);
        vm.stopPrank();
    }

    function test_Mint_BlockedWhenPaused() public {
        vm.prank(pauser);
        mintContract.pause();

        usdc.mint(alice, 10_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(mintContract), 10_000 * 1e6);
        vm.expectRevert();
        mintContract.mintSLT(address(usdc), 10_000 * 1e6);
        vm.stopPrank();
    }

    function test_Mint_RevertWhenOracleStale() public {
        skip(2 days);

        usdc.mint(alice, 10_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(mintContract), 10_000 * 1e6);
        vm.expectRevert();
        mintContract.mintSLT(address(usdc), 10_000 * 1e6);
        vm.stopPrank();
    }

    function test_Mint_AtElevatedIndex() public {
        // v1.1: bound ceiling is 5% — reach index 1.10 in two compliant steps
        // (1.0 -> 1.05 -> 1.10), respecting the 20-hour throttle floor.
        skip(20 hours + 1);
        vm.prank(admin);
        oracle.updateIndex(105 * 1e16);
        skip(20 hours + 1);
        vm.prank(admin);
        oracle.updateIndex(11 * 1e17);

        usdc.mint(alice, 11_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(mintContract), 11_000 * 1e6);
        uint256 minted = mintContract.mintSLT(address(usdc), 11_000 * 1e6);
        vm.stopPrank();

        // At index 1.10, $11,000 should mint 10,000 SLT.
        assertEq(minted, 10_000 ether);
    }

    function test_Mint_AtMinAmount() public {
        usdc.mint(alice, MIN_MINT);
        vm.startPrank(alice);
        usdc.approve(address(mintContract), MIN_MINT);
        uint256 minted = mintContract.mintSLT(address(usdc), MIN_MINT);
        vm.stopPrank();
        assertEq(minted, 1_000 ether);
    }

    function test_Mint_AtMaxAmount() public {
        usdc.mint(alice, MAX_MINT);
        vm.startPrank(alice);
        usdc.approve(address(mintContract), MAX_MINT);
        uint256 minted = mintContract.mintSLT(address(usdc), MAX_MINT);
        vm.stopPrank();
        assertEq(minted, 5_000_000 ether);
    }

    function test_Mint_RevertOnReentrancy() public {
        ReentrantUSDC bad = new ReentrantUSDC();
        vm.prank(admin);
        mintContract.setStablecoinAccepted(address(bad), true);

        bad.mint(alice, 10_000 * 1e6);
        bad.arm(mintContract);

        vm.startPrank(alice);
        bad.approve(address(mintContract), 10_000 * 1e6);
        vm.expectRevert();
        mintContract.mintSLT(address(bad), 1_000 * 1e6);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------------
    // setStablecoinAccepted()
    // ----------------------------------------------------------------------

    function test_SetStablecoinAccepted_TogglesOff() public {
        vm.prank(admin);
        mintContract.setStablecoinAccepted(address(usdc), false);
        assertFalse(mintContract.acceptedStablecoin(address(usdc)));

        usdc.mint(alice, 10_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(mintContract), 10_000 * 1e6);
        vm.expectRevert();
        mintContract.mintSLT(address(usdc), 10_000 * 1e6);
        vm.stopPrank();
    }

    function test_SetStablecoinAccepted_RevertOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(MintContract.MintContract_ZeroAddress.selector);
        mintContract.setStablecoinAccepted(address(0), true);
    }

    function test_SetStablecoinAccepted_RevertWhenUnauthorized() public {
        vm.prank(stranger);
        vm.expectRevert();
        mintContract.setStablecoinAccepted(address(usdc), false);
    }

    // ----------------------------------------------------------------------
    // setTreasurySafe()
    // ----------------------------------------------------------------------

    function test_SetTreasurySafe_HappyPath() public {
        address newSafe = address(0xC0FFEE);
        vm.prank(admin);
        mintContract.setTreasurySafe(newSafe);
        assertEq(mintContract.treasurySafe(), newSafe);

        // New mints flow to the new safe.
        usdc.mint(alice, MIN_MINT);
        vm.startPrank(alice);
        usdc.approve(address(mintContract), MIN_MINT);
        mintContract.mintSLT(address(usdc), MIN_MINT);
        vm.stopPrank();
        assertEq(usdc.balanceOf(newSafe), MIN_MINT);
        assertEq(usdc.balanceOf(treasurySafe), 0);
    }

    function test_SetTreasurySafe_RevertOnZero() public {
        vm.prank(admin);
        vm.expectRevert(MintContract.MintContract_ZeroAddress.selector);
        mintContract.setTreasurySafe(address(0));
    }

    function test_SetTreasurySafe_RevertWhenUnauthorized() public {
        vm.prank(stranger);
        vm.expectRevert();
        mintContract.setTreasurySafe(address(0xC0FFEE));
    }

    // ----------------------------------------------------------------------
    // setMintLimits()
    // ----------------------------------------------------------------------

    function test_SetMintLimits_HappyPath() public {
        vm.prank(admin);
        mintContract.setMintLimits(500 * 1e6, 1_000_000 * 1e6);
        assertEq(mintContract.minMintAmount(), 500 * 1e6);
        assertEq(mintContract.maxMintAmount(), 1_000_000 * 1e6);
    }

    function test_SetMintLimits_RevertOnZeroMin() public {
        vm.prank(admin);
        vm.expectRevert(MintContract.MintContract_InvalidLimits.selector);
        mintContract.setMintLimits(0, MAX_MINT);
    }

    function test_SetMintLimits_RevertOnMinGreaterThanMax() public {
        vm.prank(admin);
        vm.expectRevert(MintContract.MintContract_InvalidLimits.selector);
        mintContract.setMintLimits(MAX_MINT + 1, MAX_MINT);
    }

    function test_SetMintLimits_RevertWhenUnauthorized() public {
        vm.prank(stranger);
        vm.expectRevert();
        mintContract.setMintLimits(500 * 1e6, 1_000_000 * 1e6);
    }

    // ----------------------------------------------------------------------
    // pause / unpause
    // ----------------------------------------------------------------------

    function test_Pause_RevertWhenUnauthorized() public {
        vm.prank(stranger);
        vm.expectRevert();
        mintContract.pause();
    }

    function test_Unpause_HappyPath() public {
        vm.prank(pauser);
        mintContract.pause();
        assertTrue(mintContract.paused());

        vm.prank(pauser);
        mintContract.unpause();
        assertFalse(mintContract.paused());

        usdc.mint(alice, MIN_MINT);
        vm.startPrank(alice);
        usdc.approve(address(mintContract), MIN_MINT);
        uint256 minted = mintContract.mintSLT(address(usdc), MIN_MINT);
        vm.stopPrank();
        assertEq(minted, 1_000 ether);
    }

    function test_Unpause_RevertWhenUnauthorized() public {
        vm.prank(pauser);
        mintContract.pause();

        vm.prank(stranger);
        vm.expectRevert();
        mintContract.unpause();
    }

    // ----------------------------------------------------------------------
    // Invariants
    // ----------------------------------------------------------------------

    function test_Invariant_NoStableEverHeldByMintContract() public {
        usdc.mint(alice, 10_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(mintContract), 10_000 * 1e6);
        mintContract.mintSLT(address(usdc), 10_000 * 1e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(mintContract)), 0);
    }
}
