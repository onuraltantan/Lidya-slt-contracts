// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SLT} from "../src/SLT.sol";
import {IndexOracle} from "../src/IndexOracle.sol";
import {MintContract} from "../src/MintContract.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev A configurable-decimals mock "stablecoin".
contract MockToken is ERC20 {
    uint8 private immutable _dec;

    constructor(
        string memory n,
        string memory s,
        uint8 d
    ) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(
        address to,
        uint256 amt
    ) external {
        _mint(to, amt);
    }
}

/// @dev A malicious 6-decimal token that tries to re-enter mintSLT from inside transferFrom.
contract ReentrantToken is ERC20 {
    MintContract public mintC;
    bool public armed;
    bool private entered;
    constructor() ERC20("Evil", "EVL") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(
        address to,
        uint256 amt
    ) external {
        _mint(to, amt);
    }

    function arm(
        MintContract m
    ) external {
        mintC = m;
        armed = true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amt
    ) public override returns (bool) {
        if (armed && !entered) {
            entered = true;
            // Fund + approve ourselves so the nested call would succeed if nonReentrant were missing.
            _mint(address(this), amt);
            _approve(address(this), address(mintC), amt);
            mintC.mintSLT(address(this), amt); // second entry — must be blocked
        }
        return super.transferFrom(from, to, amt);
    }
}

/// @notice Second batch of adversarial proof-of-concepts for SLT v1.1-prereview.
contract PreAuditPoC2 is Test {
    SLT slt;
    IndexOracle oracle;
    MintContract mintC;
    MockToken usdc; // correct 6-decimal control

    address safe = makeAddr("treasurySafe");
    address updater = makeAddr("updater");
    address alice = makeAddr("alice");
    address attacker = makeAddr("attacker");

    bytes32 CONFIG;

    uint256 constant MIN_MINT = 1_000e6; // $1,000 in 6-dec
    uint256 constant MAX_MINT = 5_000_000e6; // $5,000,000 in 6-dec

    function _arr(
        address a
    ) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function setUp() public {
        oracle = new IndexOracle(1e18, safe, safe, updater);
        slt = new SLT(safe, safe, address(oracle));
        usdc = new MockToken("USD Coin", "USDC", 6);
        mintC = new MintContract(address(slt), address(oracle), safe, safe, safe, MIN_MINT, MAX_MINT, _arr(address(usdc)));
        CONFIG = mintC.CONFIG_ROLE();

        vm.startPrank(safe);
        slt.grantRole(slt.MINTER_ROLE(), address(mintC));
        vm.stopPrank();

        usdc.mint(alice, 100_000e6);
    }

    // ==================================================================
    // NEW — the mint math hardcodes 6 decimals; nothing verifies the
    // whitelisted token actually has them. Whitelisting an 18-decimal
    // "stablecoin" (e.g. DAI.e on Avalanche IS 18 decimals) lets an
    // attacker mint millions of SLT for dust.
    // ==================================================================
    function test_PoC_DecimalsAssumptionBlocked() public {
        // REGRESSION: whitelisting an 18-decimal "stablecoin" (DAI.e, TUSD, several bridged stables
        // on Avalanche are 18-dec) now reverts, because the mint math is hardcoded for 6 decimals.
        MockToken dai = new MockToken("DAI.e", "DAI", 18);
        vm.prank(safe);
        vm.expectRevert(
            abi.encodeWithSelector(MintContract.MintContract_UnexpectedDecimals.selector, address(dai), uint8(18))
        );
        mintC.setStablecoinAccepted(address(dai), true);
        assertFalse(mintC.acceptedStablecoin(address(dai)), "18-dec token rejected from whitelist");

        // The correct 6-decimal token can be proposed, and is accepted after the 24h delay (H-1).
        MockToken good = new MockToken("USDT.e", "USDT", 6);
        vm.prank(safe);
        mintC.setStablecoinAccepted(address(good), true);
        assertFalse(mintC.acceptedStablecoin(address(good)), "not accepted before the delay");
        vm.warp(block.timestamp + mintC.STABLECOIN_DELAY());
        vm.prank(safe);
        mintC.executeStablecoinAccepted(address(good));
        assertTrue(mintC.acceptedStablecoin(address(good)), "6-dec token accepted after delay");
    }

    // ==================================================================
    // NEW — MintContract constructor does not validate `pauser != 0`,
    // unlike SLT and IndexOracle. A fat-fingered deploy silently ships a
    // MintContract whose only pauser is the zero address (unpausable).
    // ==================================================================
    function test_PoC_MintContractRejectsZeroPauser() public {
        // SLT already rejected a zero pauser...
        vm.expectRevert(SLT.SLT_ZeroAddress.selector);
        new SLT(safe, address(0), address(oracle));

        // REGRESSION: MintContract now rejects it too, so a fat-fingered deploy can't ship an
        // unpausable mint contract.
        vm.expectRevert(MintContract.MintContract_ZeroAddress.selector);
        new MintContract(address(slt), address(oracle), safe, safe, address(0), MIN_MINT, MAX_MINT, _arr(address(usdc)));
    }

    // ==================================================================
    // Quantifies I-01/I-04: the ±5% bound rounds DOWN, so an update of
    // ~5.0099% passes the check. Immaterial in size, but the "±5% is a
    // hard code guarantee" claim is really "±5% plus rounding slack."
    // ==================================================================
    function test_PoC_BoundCheckLetsThroughSlightlyOverFivePercent() public {
        // v1.1.1 (L-1 fix): the check no longer floors to bps, so 5.0099% is REJECTED and exactly
        // 5.0000% is the last accepted value.
        vm.warp(block.timestamp + 21 hours);
        uint256 prev = 1e18;
        uint256 delta = 50_099_000_000_000_000; // 5.0099%
        uint256 newIndex = prev + delta;
        assertEq((delta * 10_000) / prev, 500, "would have rounded to exactly the 500-bps ceiling");
        assertGt(delta * 10_000, 500 * prev, "actual move exceeds 5%");

        vm.prank(updater);
        vm.expectRevert(abi.encodeWithSelector(IndexOracle.IndexOracle_OutOfBounds.selector, newIndex, prev, 500));
        oracle.updateIndex(newIndex);

        vm.prank(updater);
        oracle.updateIndex(prev + prev * 500 / 10_000); // exactly +5.00%
        assertEq(oracle.pricePerShare(), 1.05e18, "exact 5% accepted");
    }

    // ==================================================================
    // Positive control — reentrancy. Confirms the nonReentrant guard
    // actually holds against a whitelisted malicious token (threat 3.1).
    // This one SHOULD revert; it's here to prove the defense works.
    // ==================================================================
    function test_PoC_ReentrancyIsBlocked() public {
        ReentrantToken evil = new ReentrantToken();
        vm.startPrank(safe);
        mintC.setStablecoinAccepted(address(evil), true);
        vm.warp(block.timestamp + mintC.STABLECOIN_DELAY());
        mintC.executeStablecoinAccepted(address(evil));
        vm.stopPrank();

        evil.mint(alice, 10_000e6);
        evil.arm(mintC);

        vm.startPrank(alice);
        evil.approve(address(mintC), 10_000e6);
        // The nested call is funded and approved (see ReentrantToken.transferFrom), so ONLY the guard
        // can stop it: the exact ReentrancyGuardReentrantCall selector must surface.
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        mintC.mintSLT(address(evil), 1_000e6);
        vm.stopPrank();
        assertEq(slt.balanceOf(alice), 0, "no SLT minted; guard held");
        assertEq(slt.totalSupply(), 0, "nothing minted anywhere");
    }

    // ==================================================================
    // Quantifies L-01: with no minSltOut, an updater (or anyone who can
    // land an update first) moves the index +5% in front of a user's
    // mint and the user silently receives ~4.76% fewer SLT than quoted.
    // ==================================================================
    function test_PoC_IndexSandwichShortsTheUser() public {
        // Alice expects ~1000 SLT for $1000 at index 1.0.
        uint256 expectedAtQuote = oracle.stableToSLT(1_000e6);
        assertEq(expectedAtQuote, 1_000e18, "quote: 1000 SLT");

        // An update lands first, moving the index to the +5% edge.
        vm.warp(block.timestamp + 21 hours);
        vm.prank(updater);
        oracle.updateIndex(1.05e18);

        // Alice's mint now executes at the new index with no floor to protect her.
        vm.startPrank(alice);
        usdc.approve(address(mintC), 1_000e6);
        uint256 got = mintC.mintSLT(address(usdc), 1_000e6);
        vm.stopPrank();

        console2.log("expected:", expectedAtQuote, " got:", got);
        assertLt(got, expectedAtQuote, "user received fewer SLT than quoted (2-arg legacy path)");
        assertApproxEqAbs(got, 952_380952380952380952, 1e12, "~952 SLT, ~4.76% short");

        // v1.1.1 (M-1 fix): the 4-arg overload lets the user set a floor; the same sandwich reverts.
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(mintC), 1_000e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                MintContract.MintContract_SlippageExceeded.selector, 952_380952380952380952, expectedAtQuote
            )
        );
        mintC.mintSLT(address(usdc), 1_000e6, expectedAtQuote, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    // ==================================================================
    // Confirms deliberate-but-worth-showing behavior: adminBurn is NOT
    // gated by pause, so allowlisted balances can be destroyed while the
    // token is "paused" and every ordinary transfer is frozen.
    // ==================================================================
    function test_PoC_AdminBurnWorksWhilePaused() public {
        // Give the treasury-controlled address some SLT: alice mints and transfers to the Safe.
        // (The Safe cannot mint for itself: the L-6 receipt check sees a zero-delta self-transfer.)
        vm.startPrank(alice);
        usdc.approve(address(mintC), 2_000e6);
        uint256 bal = mintC.mintSLT(address(usdc), 2_000e6);
        slt.transfer(safe, bal);
        vm.stopPrank();
        vm.startPrank(safe);
        slt.setBurnSource(safe, true);
        slt.pause(); // freeze all transfers
        vm.stopPrank();

        // Ordinary transfers are frozen...
        vm.prank(safe);
        vm.expectRevert();
        slt.transfer(alice, 1);

        // ...but adminBurn still executes.
        vm.prank(safe);
        slt.adminBurn(safe, bal);
        assertEq(slt.balanceOf(safe), 0, "burned while paused (by design)");
    }
}
