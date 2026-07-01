// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SLT} from "../../src/SLT.sol";
import {IndexOracle} from "../../src/IndexOracle.sol";
import {MintContract} from "../../src/MintContract.sol";

/// @notice Mock USDC for invariant tests (6 decimals).
contract MockStable is ERC20 {
    constructor(string memory name, string memory sym) ERC20(name, sym) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Stateful fuzz handler for invariant tests. Foundry calls these functions in random
///         order with random inputs. Each function is bounded to keep the contract in a valid
///         state (so fail_on_revert=true catches real invariant violations, not noise).
contract Handler is Test {
    SLT public slt;
    IndexOracle public oracle;
    MintContract public mintContract;
    MockStable public usdc;
    MockStable public usdt;
    address public treasurySafe;
    address public admin;
    address public pauser;
    address public guardian;
    address public updater;

    uint256 public constant MIN_MINT = 1_000 * 1e6;
    uint256 public constant MAX_MINT = 5_000_000 * 1e6;

    address[] public actors;
    address internal currentActor;

    // Ghost variables track expected state.
    uint256 public ghost_totalUSDCDeposited;
    uint256 public ghost_totalUSDTDeposited;
    uint256 public ghost_totalSLTMinted;
    uint256 public ghost_mintCallCount;
    uint256 public ghost_indexUpdateCount;

    constructor(
        SLT _slt,
        IndexOracle _oracle,
        MintContract _mintContract,
        MockStable _usdc,
        MockStable _usdt,
        address _treasurySafe,
        address _admin,
        address _pauser,
        address _guardian,
        address _updater
    ) {
        slt = _slt;
        oracle = _oracle;
        mintContract = _mintContract;
        usdc = _usdc;
        usdt = _usdt;
        treasurySafe = _treasurySafe;
        admin = _admin;
        pauser = _pauser;
        guardian = _guardian;
        updater = _updater;

        // Seed a small set of actors so fuzz state space is bounded.
        actors.push(address(0xB1));
        actors.push(address(0xB2));
        actors.push(address(0xB3));
        actors.push(address(0xB4));
    }

    modifier useActor(uint256 actorSeed) {
        currentActor = actors[bound(actorSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    // ----------------------------------------------------------------------
    // Mint actions
    // ----------------------------------------------------------------------

    function mintWithUSDC(uint256 stableAmount, uint256 actorSeed) external {
        // Skip if mint paused or oracle stale (avoid noise reverts).
        if (mintContract.paused() || !oracle.isFresh()) return;

        stableAmount = bound(stableAmount, MIN_MINT, MAX_MINT);
        currentActor = actors[bound(actorSeed, 0, actors.length - 1)];

        usdc.mint(currentActor, stableAmount);

        vm.startPrank(currentActor);
        usdc.approve(address(mintContract), stableAmount);
        uint256 minted = mintContract.mintSLT(address(usdc), stableAmount);
        vm.stopPrank();

        ghost_totalUSDCDeposited += stableAmount;
        ghost_totalSLTMinted += minted;
        ghost_mintCallCount++;
    }

    function mintWithUSDT(uint256 stableAmount, uint256 actorSeed) external {
        if (mintContract.paused() || !oracle.isFresh()) return;

        stableAmount = bound(stableAmount, MIN_MINT, MAX_MINT);
        currentActor = actors[bound(actorSeed, 0, actors.length - 1)];

        usdt.mint(currentActor, stableAmount);

        vm.startPrank(currentActor);
        usdt.approve(address(mintContract), stableAmount);
        uint256 minted = mintContract.mintSLT(address(usdt), stableAmount);
        vm.stopPrank();

        ghost_totalUSDTDeposited += stableAmount;
        ghost_totalSLTMinted += minted;
        ghost_mintCallCount++;
    }

    // ----------------------------------------------------------------------
    // Oracle actions
    // ----------------------------------------------------------------------

    function updateOracleIndex(uint256 deltaBps, bool upward) external {
        if (oracle.paused()) return;

        // Bound delta to within max allowed (5% = 500 bps) minus a small margin
        // to keep the test moving even at the boundary.
        deltaBps = bound(deltaBps, 0, 499);

        // Advance time past throttle.
        skip(oracle.minUpdateInterval() + 1);

        uint256 prev = oracle.pricePerShare();
        uint256 newIndex;
        if (upward) {
            newIndex = prev + (prev * deltaBps) / 10_000;
        } else {
            // Avoid going to zero in extreme cases.
            uint256 deduction = (prev * deltaBps) / 10_000;
            newIndex = prev > deduction ? prev - deduction : prev;
        }

        if (newIndex == 0) return;

        vm.prank(updater);
        oracle.updateIndex(newIndex);
        ghost_indexUpdateCount++;
    }

    // ----------------------------------------------------------------------
    // Pause/unpause actions (rare, non-zero probability via external calls)
    // ----------------------------------------------------------------------

    function pauseMint() external {
        if (mintContract.paused()) return;
        vm.prank(pauser);
        mintContract.pause();
    }

    function unpauseMint() external {
        if (!mintContract.paused()) return;
        vm.prank(pauser);
        mintContract.unpause();
    }

    function pauseOracle() external {
        if (oracle.paused()) return;
        vm.prank(guardian);
        oracle.pause("invariant_test");
    }

    function unpauseOracle() external {
        if (!oracle.paused()) return;
        vm.prank(guardian);
        oracle.unpause();
    }

    // ----------------------------------------------------------------------
    // Helpers for invariant assertions
    // ----------------------------------------------------------------------

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }
}
