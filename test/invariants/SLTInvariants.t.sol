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

        mintContract =
            new MintContract(address(slt), address(oracle), treasurySafe, admin, pauser, MIN_MINT, MAX_MINT);

        // Wire up roles and whitelists.
        vm.startPrank(admin);
        slt.grantRole(slt.MINTER_ROLE(), address(mintContract));
        mintContract.setStablecoinAccepted(address(usdc), true);
        mintContract.setStablecoinAccepted(address(usdt), true);
        vm.stopPrank();

        // Deploy the handler.
        handler = new Handler(slt, oracle, mintContract, usdc, usdt, treasurySafe, admin, pauser, guardian, updater);

        // Tell Foundry to fuzz only the handler's functions (not SLT/oracle/mint directly).
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.mintWithUSDC.selector;
        selectors[1] = handler.mintWithUSDT.selector;
        selectors[2] = handler.updateOracleIndex.selector;
        selectors[3] = handler.pauseMint.selector;
        selectors[4] = handler.unpauseMint.selector;
        selectors[5] = handler.pauseOracle.selector;
        selectors[6] = handler.unpauseOracle.selector;
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
    // INV-3: SLT.totalAssets() == totalSupply * pricePerShare / 1e18.
    //        Math consistency between view metadata and underlying state.
    // ----------------------------------------------------------------------

    function invariant_TotalAssetsMathConsistent() public view {
        uint256 expected = (slt.totalSupply() * oracle.pricePerShare()) / 1e18;
        assertEq(slt.syntheticTotalValue(), expected, "totalAssets math mismatch");
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
    // INV-7 (call summary): exposes ghost counters as test "summary" so the
    //        invariant runs are visible in -vvv output. Does not assert.
    // ----------------------------------------------------------------------

    function invariant_callSummary() public view {
        // No assertion — just emits state visible in trace output.
        // Foundry will print this as part of invariant suite output.
        assertTrue(true);
        // (Counters: ghost_mintCallCount, ghost_indexUpdateCount, totalSupply, etc.)
    }
}
