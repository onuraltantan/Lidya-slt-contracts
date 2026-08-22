// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IIndexOracle} from "./interfaces/IIndexOracle.sol";

/// @title IndexOracle
/// @author Blockxell
/// @notice Stores the synthetic performance index for SLT and exposes it to consumers
///         (MintContract, DeFi integrators, risk engines).
/// @dev    Index updates are submitted by the ORACLE_UPDATER_ROLE (Chainlink custom data feed
///         adapter or rotated backup signer). All updates are subject to:
///           - per-update bounds check (±5%, which is also the hard ceiling — 500 bps)
///           - throttle floor (default 20 hours minimum interval; hard floor 20 hours)
///           - guardian-controlled pause
///         Combined, the bound and throttle guarantee the index cannot move more than ±5%
///         per update on a ~daily cadence, matching the whitepaper's stated behavior.
///         The oracle never custodies funds; it only transports a single uint256 value
///         (pricePerShare, scaled to 1e18) and reports staleness state via isFresh().
contract IndexOracle is IIndexOracle, AccessControl, Pausable {
    // -----------------------------------------------------------------------
    // Role identifiers
    // -----------------------------------------------------------------------

    /// @notice Role allowed to push new index values. Held by the Chainlink adapter
    ///         or a rotated backup signer authorized by the Treasury Safe.
    bytes32 public constant ORACLE_UPDATER_ROLE = keccak256("ORACLE_UPDATER_ROLE");

    /// @notice Role allowed to pause/unpause the oracle and adjust safety parameters.
    ///         Held by the Treasury Safe (BVI Issuer SPV multisig).
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // -----------------------------------------------------------------------
    // Scale constants
    // -----------------------------------------------------------------------

    /// @notice Index precision (1e18 = 1.000000000000000000).
    uint256 public constant INDEX_PRECISION = 1e18;

    /// @notice Basis-points denominator (10_000 bps = 100.00%).
    uint256 public constant BPS = 10_000;

    /// @notice Stablecoin scale (USDC/USDT use 6 decimals on Avalanche).
    uint256 public constant STABLE_PRECISION = 1e6;

    /// @notice Compile-time scale factor between 18-decimal SLT and 6-decimal stablecoin.
    /// @dev    Equals INDEX_PRECISION / STABLE_PRECISION = 1e12. Hoisted to a constant so
    ///         downstream conversion math reads as a single multiply (no division-before-multiply).
    uint256 public constant SLT_TO_STABLE_SCALE = 1e12;

    // -----------------------------------------------------------------------
    // Mutable state
    // -----------------------------------------------------------------------

    /// @notice Current SLT performance index value, scaled to 1e18.
    /// @dev    Initialized in the constructor; updated only by ORACLE_UPDATER_ROLE via updateIndex().
    uint256 public override pricePerShare;

    /// @notice Block timestamp of the most recent successful index update.
    uint256 public override lastUpdateTimestamp;

    /// @notice Maximum allowed absolute change per update, in basis points (default 500 = 5%).
    /// @dev    Adjustable by DEFAULT_ADMIN_ROLE up to a hard ceiling of 500 bps (5%) — the
    ///         default IS the ceiling; the parameter can only be tightened, never loosened
    ///         beyond the whitepaper's ±5% claim.
    uint256 public maxChangeBps;

    /// @notice Period after which the index is considered stale (default 1 day).
    /// @dev    When `block.timestamp - lastUpdateTimestamp > gracePeriod`, isFresh() returns false
    ///         and downstream consumers (MintContract) treat the oracle as paused.
    uint256 public gracePeriod;

    /// @notice Minimum interval between consecutive successful updates (default 20 hours).
    /// @dev    Throttle floor that prevents rapid-fire updates. The 20-hour hard floor supports
    ///         a daily update cadence (with scheduling slack) while making the documented
    ///         "±5% per day" behavior a code-level guarantee rather than an operational habit.
    uint256 public minUpdateInterval;

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    /// @notice Reverts when an attempted update exceeds maxChangeBps relative to the previous index.
    /// @param attempted The proposed new index value.
    /// @param previous  The current index value.
    /// @param maxBps    The configured per-update bound in basis points.
    error IndexOracle_OutOfBounds(uint256 attempted, uint256 previous, uint256 maxBps);

    /// @notice Reverts when an update is submitted before minUpdateInterval has elapsed.
    /// @param lastUpdate  Timestamp of the most recent successful update.
    /// @param minInterval Configured minimum interval between updates.
    error IndexOracle_TooSoon(uint256 lastUpdate, uint256 minInterval);

    /// @notice Reverts when initialIndex or a proposed updateIndex value is zero.
    error IndexOracle_ZeroIndex();

    /// @notice Reverts on invalid constructor or setter inputs (zero address, out-of-range parameter).
    error IndexOracle_InvalidConfig();

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /// @notice Deploy and initialize the index oracle.
    /// @param initialIndex Starting index value, scaled to 1e18 (typically 1e18 for index = 1.0).
    /// @param admin        Address granted DEFAULT_ADMIN_ROLE (Treasury Safe at deployment).
    /// @param guardian     Address granted GUARDIAN_ROLE (Treasury Safe).
    /// @param updater      Address granted ORACLE_UPDATER_ROLE (Chainlink adapter).
    /// @dev    Sets default safety parameters: maxChangeBps=500 (5%), gracePeriod=1 day,
    ///         minUpdateInterval=20 hours. Emits an initial IndexUpdated event.
    constructor(uint256 initialIndex, address admin, address guardian, address updater) {
        if (initialIndex == 0) revert IndexOracle_ZeroIndex();
        if (admin == address(0) || guardian == address(0) || updater == address(0)) {
            revert IndexOracle_InvalidConfig();
        }

        pricePerShare = initialIndex;
        lastUpdateTimestamp = block.timestamp;
        maxChangeBps = 500;           // 5.00% per update (default = hard ceiling)
        gracePeriod = 1 days;         // staleness threshold
        minUpdateInterval = 20 hours; // throttle floor (default = hard floor; daily cadence)

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
        _grantRole(ORACLE_UPDATER_ROLE, updater);

        emit IndexUpdated(initialIndex, 0, int256(0), block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Index updates
    // -----------------------------------------------------------------------

    /// @notice Push a new index value. Subject to bounds, throttle, and pause checks.
    /// @param newIndex The new index value, scaled to 1e18. Must be non-zero and within
    ///                 ±maxChangeBps of the current pricePerShare.
    /// @dev    Reverts with IndexOracle_ZeroIndex if newIndex is zero, IndexOracle_TooSoon if
    ///         less than minUpdateInterval has elapsed, IndexOracle_OutOfBounds if the absolute
    ///         change exceeds maxChangeBps, or AccessControl/Pausable errors for unauthorized
    ///         or paused calls. Emits IndexUpdated on success.
    function updateIndex(uint256 newIndex) external whenNotPaused onlyRole(ORACLE_UPDATER_ROLE) {
        if (newIndex == 0) revert IndexOracle_ZeroIndex();

        uint256 previous = pricePerShare;

        // Throttle: enforce minimum interval between updates.
        // Validator timestamp skew (~12s on Avalanche) is negligible vs the 20-hour default
        // throttle floor; using block.timestamp here is safe by design.
        // forge-lint: disable-next-line(block-timestamp)
        // slither-disable-next-line timestamp
        if (block.timestamp < lastUpdateTimestamp + minUpdateInterval) {
            revert IndexOracle_TooSoon(lastUpdateTimestamp, minUpdateInterval);
        }

        // Bounds check: |newIndex - previous| / previous <= maxChangeBps / BPS.
        uint256 delta = newIndex > previous ? newIndex - previous : previous - newIndex;
        uint256 deltaBps = (delta * BPS) / previous;
        if (deltaBps > maxChangeBps) {
            revert IndexOracle_OutOfBounds(newIndex, previous, maxChangeBps);
        }

        pricePerShare = newIndex;
        lastUpdateTimestamp = block.timestamp;

        // deltaBps is bounded by maxChangeBps (≤ 500 hard ceiling), well below int256.max.
        // Casting uint256 → int256 here is provably safe.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 signedDelta = newIndex > previous ? int256(deltaBps) : -int256(deltaBps);
        emit IndexUpdated(newIndex, previous, signedDelta, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // View / consumer-facing
    // -----------------------------------------------------------------------

    /// @notice Returns whether the oracle is fresh given the current grace period.
    /// @return True if the oracle is not paused and the last update is within gracePeriod.
    /// @dev    Validator timestamp skew (~12s on Avalanche) is negligible vs the 1-day
    ///         default grace period; block.timestamp comparison is safe by design.
    function isFresh() external view override returns (bool) {
        // forge-lint: disable-next-line(block-timestamp)
        // slither-disable-next-line timestamp
        return !paused() && (block.timestamp - lastUpdateTimestamp) <= gracePeriod;
    }

    /// @notice Convert a 6-decimal stable amount to an 18-decimal SLT amount at the current index.
    /// @param stableAmount Stablecoin amount in 6-decimal units (USDC/USDT).
    /// @return SLT amount in 18-decimal units.
    /// @dev    Math: stableAmount (6 dec) * 1e12 (scale-up) * 1e18 / pricePerShare (1e18 scale) → 18 dec SLT.
    function stableToSLT(uint256 stableAmount) external view override returns (uint256) {
        return (stableAmount * SLT_TO_STABLE_SCALE * INDEX_PRECISION) / pricePerShare;
    }

    /// @notice Convert an 18-decimal SLT amount to a 6-decimal stable amount at the current index.
    /// @param sltAmount SLT amount in 18-decimal units.
    /// @return Stablecoin amount in 6-decimal units.
    /// @dev    Math: sltAmount (18 dec) * pricePerShare / 1e18 / 1e12 (scale-down) → 6 dec stable.
    function sltToStable(uint256 sltAmount) external view override returns (uint256) {
        return (sltAmount * pricePerShare) / (INDEX_PRECISION * SLT_TO_STABLE_SCALE);
    }

    // -----------------------------------------------------------------------
    // Pause / unpause
    // -----------------------------------------------------------------------

    /// @notice Pause all index updates. Callable by Guardian during anomaly investigation.
    /// @param reason Free-form string emitted in the OraclePaused event for audit traceability.
    /// @dev    While paused, updateIndex() reverts and isFresh() returns false. Existing SLT
    ///         remains transferable and the last-known index continues to be readable.
    function pause(string calldata reason) external onlyRole(GUARDIAN_ROLE) {
        _pause();
        emit OraclePaused(msg.sender, reason);
    }

    /// @notice Resume index updates. Callable by Guardian after issue resolution.
    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
        emit OracleResumed(msg.sender);
    }

    // -----------------------------------------------------------------------
    // Admin parameter setters
    // -----------------------------------------------------------------------

    /// @notice Adjust the per-update bounds limit (basis points). Restricted to admin.
    /// @param newMaxBps New bound, in basis points. Must be > 0 and <= 500 (5% hard ceiling).
    /// @dev    Reverts with IndexOracle_InvalidConfig on out-of-range input. The ceiling equals
    ///         the whitepaper's ±5% claim — admin can tighten the bound but never loosen it
    ///         beyond the documented limit.
    function setMaxChangeBps(uint256 newMaxBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newMaxBps == 0 || newMaxBps > 500) revert IndexOracle_InvalidConfig(); // hard ceiling 5%
        maxChangeBps = newMaxBps;
    }

    /// @notice Adjust the staleness grace period. Restricted to admin.
    /// @param newGracePeriod New grace period in seconds. Must be in [1 day, 7 days].
    /// @dev    Reverts with IndexOracle_InvalidConfig on out-of-range input. Floor raised to
    ///         1 day in v1.1: gracePeriod must always exceed the 20-hour minimum update
    ///         interval, otherwise the oracle would read stale between routine updates and
    ///         needlessly block minting.
    function setGracePeriod(uint256 newGracePeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newGracePeriod < 1 days || newGracePeriod > 7 days) revert IndexOracle_InvalidConfig();
        gracePeriod = newGracePeriod;
    }

    /// @notice Adjust the minimum interval between consecutive successful updates. Restricted to admin.
    /// @param newInterval New interval in seconds. Must be in [20 hours, 1 day].
    /// @dev    Reverts with IndexOracle_InvalidConfig on out-of-range input. The 20-hour hard
    ///         floor makes the documented daily-cadence / ±5%-per-update-per-day behavior a
    ///         code-level guarantee: even a compromised admin cannot re-enable rapid-fire
    ///         updates to walk the index. Upper limit stays below gracePeriod's 1-day default
    ///         so a normally-operating updater never trips staleness.
    function setMinUpdateInterval(uint256 newInterval) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newInterval < 20 hours || newInterval > 1 days) revert IndexOracle_InvalidConfig();
        minUpdateInterval = newInterval;
    }
}
