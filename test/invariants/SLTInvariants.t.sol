// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SLT} from "../../src/SLT.sol";
import {IndexOracle} from "../../src/IndexOracle.sol";
import {MintContract} from "../../src/MintContract.sol";
import {Handler, MockStable} from "./Handler.sol";

/// @notice Stateful invariant tests for SLT V1.
///         Foundry randomly invokes Handler functions and checks each invariant_*
///         assertion holds across all reachable states.
contract SLTInvariantsTest is StdInvariant, Test {
    SLT internal slt;
    IndexOracle internal oracle;
    MintContract internal mintContract;
    MockStable internal usdc;
    MockStable internal usdt;
    Handler internal handler;

    address internal admin = address(0xA1);
    address internal pauser = address(0xA2);
    address internal guardian = address(0xA3);
    address internal updater = address(0xA4);
    address internal treasurySafe = address(0xCAFE);

    uint256 internal constant MIN_MINT = 1_000 * 1e6;
    uint256 internal constant MAX_MINT = 5_000_000 * 1e6;

    function setUp() public {
        // Deploy core contracts.
        oracle = new IndexOracle(1e18, admin, guardian, updater);
        slt = new SLT(admin, pauser, address(oracle));

        usdc = new MockStable("USD Coin", "USDC");
        usdt = new MockStable("Tether USD", "USDT");

        address[] memory stables = new address[](2);
        stables[0] = address(usdc);
        stables[1] = address(usdt);
        mintContract =
            new MintContract(address(slt), address(oracle), treasurySafe, admin, pauser, MIN_MINT, MAX_MINT, stables);

        // Wire up roles (whitelist is seeded by the constructor, H-1).
        vm.startPrank(admin);
        slt.grantRole(slt.MINTER_ROLE(), address(mintContract));
        // v1.1-audit production lock sequence (mirrors Deploy script):
        slt.lockMinterRole(address(mintContract)); // L-04 / H-01 / M-4
        slt.lockBurnSource(admin); // M-01 / M-3
        vm.stopPrank();

        // Deploy the handler.
        handler = new Handler(slt, oracle, mintContract, usdc, usdt, treasurySafe, admin, pauser, guardian, updater);

        // Tell Foundry to fuzz only the handler's functions (not SLT/oracle/mint directly).
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.mintWithUSDC.selector;
        selectors[1] = handler.mintWithUSDT.selector;
        selectors[2] = handler.updateOracleIndex.selector;
        selectors[3] = handler.pauseMint.selector;
        selectors[4] = handler.unpauseMint.selector;
        selectors[5] = handler.pauseOracle.selector;
        selectors[6] = handler.unpauseOracle.selector;
        selectors[7] = handler.adminBurnAttempt.selector;
        selectors[8] = handler.widenBurnSourceAttempt.selector;
        selectors[9] = handler.grantMinterAttempt.selector;
        selectors[10] = handler.revokeMinterAttempt.selector;
        selectors[11] = handler.warpOnly.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ----------------------------------------------------------------------
    // INV-1: All deposited stablecoin reaches Treasury Safe.
    //        ghost_totalUSDCDeposited == usdc.balanceOf(treasurySafe)
    //        ghost_totalUSDTDeposited == usdt.balanceOf(treasurySafe)
    // ----------------------------------------------------------------------

    function invariant_USDCDepositsReachTreasury() public view {
        assertEq(usdc.balanceOf(treasurySafe), handler.ghost_totalUSDCDeposited(), "USDC: deposits != treasury balance");
    }

    function invariant_USDTDepositsReachTreasury() public view {
        assertEq(usdt.balanceOf(treasurySafe), handler.ghost_totalUSDTDeposited(), "USDT: deposits != treasury balance");
    }

    // ----------------------------------------------------------------------
    // INV-2: MintContract NEVER holds stablecoins. They are forwarded
    //        atomically in mintSLT() — any residual implies a bug.
    // ----------------------------------------------------------------------

    function invariant_MintContractHoldsNoUSDC() public view {
        assertEq(usdc.balanceOf(address(mintContract)), 0, "MintContract holds USDC");
    }

    function invariant_MintContractHoldsNoUSDT() public view {
        assertEq(usdt.balanceOf(address(mintContract)), 0, "MintContract holds USDT");
    }

    // ----------------------------------------------------------------------
    // INV-3: SLT.syntheticTotalValue() == totalSupply * pricePerShare / 1e18.
    //        Math consistency between view metadata and underlying state.
    // ----------------------------------------------------------------------

    function invariant_TotalAssetsMathConsistent() public view {
        uint256 expected = (slt.totalSupply() * oracle.pricePerShare()) / 1e18;
        assertEq(slt.syntheticTotalValue(), expected, "syntheticTotalValue math mismatch");
    }

    // ----------------------------------------------------------------------
    // INV-4: pricePerShare > 0 always. The oracle never publishes zero
    //        (constructor + updateIndex enforce this).
    // ----------------------------------------------------------------------

    function invariant_OracleNeverZero() public view {
        assertGt(oracle.pricePerShare(), 0, "Oracle reported zero index");
    }

    // ----------------------------------------------------------------------
    // INV-5: SLT.totalSupply() equals the sum of all minted SLT amounts
    //        tracked by the handler. This certifies that supply is changed
    //        ONLY through the MintContract (and never through any other path).
    // ----------------------------------------------------------------------

    function invariant_TotalSupplyMatchesMintContractCalls() public view {
        assertEq(slt.totalSupply(), handler.ghost_totalSLTMinted(), "Supply diverged from minted total");
    }

    // ----------------------------------------------------------------------
    // INV-6: The accepted stablecoins remain whitelisted (handler does
    //        not toggle them off) — a baseline sanity check ensuring our
    //        environment isn't drifting between runs.
    // ----------------------------------------------------------------------

    function invariant_StablecoinsRemainAccepted() public view {
        assertTrue(mintContract.acceptedStablecoin(address(usdc)), "USDC dropped from whitelist");
        assertTrue(mintContract.acceptedStablecoin(address(usdt)), "USDT dropped from whitelist");
    }

    // ----------------------------------------------------------------------
    // INV-8 (M-01): after lockBurnSource(), NO role holder can reduce a holder's
    //        balance. Actors never transfer in the handler, so balanceOf(actor)
    //        must equal exactly what was minted to them, regardless of how many
    //        adminBurn / setBurnSource / grantRole(BURNER) attempts were made.
    // ----------------------------------------------------------------------

    function invariant_HolderBalancesUntouchableAfterBurnLock() public view {
        assertTrue(slt.burnSourceLocked(), "burn source not locked");
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            address a = handler.actorAt(i);
            assertEq(slt.balanceOf(a), handler.ghost_mintedTo(a), "holder balance touched by issuer");
            assertFalse(slt.authorizedBurnSource(a), "holder became a burn source");
        }
        assertTrue(slt.authorizedBurnSource(admin), "Treasury Safe dropped from burn sources");
        assertEq(slt.burnSourceCount(), 1, "burn-source set is not exactly {Treasury Safe}");
    }

    // ----------------------------------------------------------------------
    // INV-9 (H-01 / L-04): after lockMinterRole(mintContract), MintContract is
    //        the one and only minter, forever.
    // ----------------------------------------------------------------------

    function invariant_SingleMinterForever() public view {
        assertTrue(slt.minterRoleLocked(), "minter role not locked");
        assertEq(slt.minterCount(), 1, "minter count != 1");
        assertTrue(slt.hasRole(slt.MINTER_ROLE(), address(mintContract)), "MintContract lost MINTER_ROLE");
        assertEq(slt.getRoleAdmin(slt.MINTER_ROLE()), slt.MINTER_ADMIN_LOCK(), "minter admin not sealed");
    }

    // ----------------------------------------------------------------------
    // INV-7 (call summary): exposes ghost counters as test "summary" so the
    //        invariant runs are visible in -vvv output. Does not assert.
    // ----------------------------------------------------------------------

    // ----------------------------------------------------------------------
    // INV-10 (pricing): every mint paid exactly stable * 1e12 * 1e18 / index at the index in force.
    //        Computed independently in the handler (not via stableToSLT), so a pricing bug in the
    //        oracle or MintContract cannot cancel out.
    // ----------------------------------------------------------------------

    function invariant_SupplyMatchesIndependentPricing() public view {
        assertEq(slt.totalSupply(), handler.ghost_expectedSLTByPricing(), "supply != independently priced total");
    }
}
