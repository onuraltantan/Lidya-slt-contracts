// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {SLT} from "../src/SLT.sol";
import {IndexOracle} from "../src/IndexOracle.sol";
import {MintContract} from "../src/MintContract.sol";

contract MockStable is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(
        address to,
        uint256 amt
    ) external {
        _mint(to, amt);
    }
}

/// @notice Independent proof-of-concept tests for the second-pass review of SLT v1.1-prereview.
contract PreAuditPoC is Test {
    SLT slt;
    IndexOracle oracle;
    MintContract mintC;
    MockStable usdc;

    address safe = makeAddr("treasurySafe");
    address updater = makeAddr("updater");
    address alice = makeAddr("alice"); // ordinary holder
    address evil = makeAddr("evilKey"); // key quietly pre-loaded before the lock

    bytes32 MINTER;
    bytes32 LOCK;

    uint256 constant MIN_MINT = 1_000e6;
    uint256 constant MAX_MINT = 5_000_000e6;

    function setUp() public {
        oracle = new IndexOracle(1e18, safe, safe, updater);
        slt = new SLT(safe, safe, address(oracle));
        mintC = new MintContract(address(slt), address(oracle), safe, safe, safe, MIN_MINT, MAX_MINT);
        usdc = new MockStable();
        MINTER = slt.MINTER_ROLE();
        LOCK = slt.MINTER_ADMIN_LOCK();

        // Canonical deployment wiring, exactly as documented (README step 4 / runbook).
        vm.startPrank(safe);
        slt.grantRole(MINTER, address(mintC));
        mintC.setStablecoinAccepted(address(usdc), true);
        vm.stopPrank();

        usdc.mint(alice, 10_000e6);
    }

    // ------------------------------------------------------------------
    // H-01 — REGRESSION: the sentinel is sealed at construction, so the
    // permanent-backdoor pre-grant is now impossible. (Before the fix this
    // test demonstrated the exploit; it now proves the fix holds.)
    // ------------------------------------------------------------------
    function test_PoC_LockSentinelCannotBePreGranted() public {
        // The pre-grant that used to install the backdoor now reverts: MINTER_ADMIN_LOCK is its
        // own role-admin from block zero, held by nobody, so DEFAULT_ADMIN cannot grant it.
        vm.prank(safe);
        vm.expectRevert();
        slt.grantRole(LOCK, evil);
        assertFalse(slt.hasRole(LOCK, evil), "sentinel can never be held");

        // The documented lock sequence still works end to end.
        vm.prank(safe);
        slt.lockMinterRole(address(mintC));
        assertTrue(slt.minterRoleLocked(), "lock flag set");
        assertTrue(slt.hasRole(MINTER, address(mintC)), "MintContract still minter");

        // And DEFAULT_ADMIN remains locked out of granting MINTER afterwards.
        vm.prank(safe);
        vm.expectRevert();
        slt.grantRole(MINTER, safe);
    }

    /// @notice REGRESSION: nobody can ever hold MINTER_ADMIN_LOCK, before or after the lock — the
    ///         missing post-deploy verification is now enforced by the constructor itself.
    function test_PoC_SentinelUnheldBeforeAndAfterLock() public {
        assertFalse(slt.hasRole(LOCK, safe), "unheld pre-lock");
        vm.prank(safe);
        slt.lockMinterRole(address(mintC));
        assertFalse(slt.hasRole(LOCK, safe), "unheld post-lock");
    }

    // ------------------------------------------------------------------
    // PoC 2 — M-02: the oracle can be configured into a permanently self-halting state
    // ------------------------------------------------------------------
    function test_PoC_SelfHaltingOracleConfig() public {
        // v1.1-audit (M-02 fix): the self-halting pair is no longer configurable. gracePeriod must
        // stay >= minUpdateInterval + 4h, so raising the interval to the 1-day ceiling while grace
        // sits at its 1-day floor is rejected.
        vm.startPrank(safe);
        oracle.setGracePeriod(1 days);
        vm.expectRevert(IndexOracle.IndexOracle_InvalidConfig.selector);
        oracle.setMinUpdateInterval(1 days);
        vm.stopPrank();
        assertGe(oracle.gracePeriod(), oracle.minUpdateInterval() + 4 hours, "guard holds");
    }

    // ------------------------------------------------------------------
    // PoC 3 — M-01: any holder can be allowlisted and burned
    // ------------------------------------------------------------------
    function test_PoC_HolderBalanceIsBurnable() public {
        vm.startPrank(alice);
        usdc.approve(address(mintC), MIN_MINT);
        uint256 got = mintC.mintSLT(address(usdc), MIN_MINT);
        vm.stopPrank();
        assertGt(got, 0);

        vm.startPrank(safe);
        slt.setBurnSource(alice, true); // no constraint on `source`
        slt.adminBurn(alice, got);
        vm.stopPrank();
        assertEq(slt.balanceOf(alice), 0, "holder wiped, nothing paid out");
    }

    // ------------------------------------------------------------------
    // PoC 4 — index walk: what +/-5% per 20h compounds to, and the missing absolute floor/ceiling
    // ------------------------------------------------------------------
    function test_PoC_IndexWalkHasNoAbsoluteBand() public {
        uint256 t = block.timestamp;
        // 36 updates ~= 30 days at the 20h floor
        for (uint256 i = 0; i < 36; i++) {
            t += 20 hours;
            vm.warp(t);
            uint256 next = oracle.pricePerShare() * 95 / 100;
            vm.prank(updater);
            oracle.updateIndex(next);
        }
        console2.log("index after 30d of max downward walk (1e18 = 1.0):", oracle.pricePerShare());
        assertLt(oracle.pricePerShare(), 0.16e18, "index walked below 16% of par with no floor");
    }

    // ------------------------------------------------------------------
    // PoC 5 — SLT metadata serves a stale/paused price with no freshness signal
    // ------------------------------------------------------------------
    function test_PoC_TokenMetadataHidesStaleness() public {
        vm.prank(safe);
        oracle.pause("investigating anomaly");

        // The index reads still return the last-known value (a view must not revert)...
        assertEq(slt.pricePerShare(), 1e18, "last-known price still readable");
        assertEq(slt.indexValueForSLT(1e18), 1e18, "conversion helper likewise");
        // ...but M-05 REGRESSION: SLT now exposes a freshness passthrough so a lending market can
        // gate on it instead of trusting a silently-frozen price.
        assertFalse(slt.isFresh(), "SLT.isFresh() passthrough reports the staleness");
        assertEq(slt.lastUpdateTimestamp(), oracle.lastUpdateTimestamp(), "timestamp passthrough");
    }
}
