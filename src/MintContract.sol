// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISLT} from "./interfaces/ISLT.sol";
import {IIndexOracle} from "./interfaces/IIndexOracle.sol";

/// @title MintContract
/// @author Blockxell
/// @notice Accepts approved stablecoins (USDC, USDT) and mints SLT to depositors at the current
///         index price. Stablecoin proceeds are forwarded atomically to the Treasury Safe
///         (BVI Issuer SPV multisig). No redemption is ever offered — exit is via secondary markets.
/// @dev    Atomic guarantee: in mintSLT() either the entire flow succeeds (stable transferred +
///         SLT minted at the validated index) or the transaction reverts and no state changes.
///         The contract holds no stablecoin balance at rest — every successful mint forwards
///         the deposit to the Treasury Safe in the same transaction.
contract MintContract is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    // Role identifiers
    // -----------------------------------------------------------------------

    /// @notice Role allowed to add/remove stablecoins and adjust mint limits.
    ///         Held by the Treasury Safe.
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");

    /// @notice Role allowed to pause/unpause minting. Held by the Treasury Safe.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // -----------------------------------------------------------------------
    // Immutables
    // -----------------------------------------------------------------------

    /// @notice The SLT token contract this MintContract mints into.
    /// @dev    Set at deployment; immutable.
    ISLT public immutable slt;

    /// @notice The index oracle providing pricePerShare and freshness state.
    /// @dev    Set at deployment; immutable.
    IIndexOracle public immutable indexOracle;

    // -----------------------------------------------------------------------
    // Mutable state
    // -----------------------------------------------------------------------

    /// @notice The Treasury Safe address that receives all stablecoin deposits.
    /// @dev    Changed only via setTreasurySafe() (propose) -> 24h -> executeTreasurySafe() (M-03).
    address public treasurySafe;

    /// @notice Whitelist of accepted stablecoin token addresses.
    /// @dev    Seeded in the constructor. Later ADDITIONS go through a 24h propose/execute flow
    ///         (setStablecoinAccepted(token, true) -> executeStablecoinAccepted(token)); removals are
    ///         immediate (finding H-1: an instant whitelist let a compromised admin mint SLT against a
    ///         worthless 6-decimal token).
    mapping(address => bool) public acceptedStablecoin;

    /// @notice Earliest timestamp at which a proposed stablecoin may be whitelisted; 0 = nothing pending.
    mapping(address => uint256) public pendingStablecoinExecutableAt;

    /// @notice Delay between proposing and executing a stablecoin whitelist ADDITION (finding H-1).
    uint256 public constant STABLECOIN_DELAY = 24 hours;

    /// @notice Minimum mint amount in stablecoin units (6 decimals); set at deploy (mainnet: $1,000).
    uint256 public minMintAmount;

    /// @notice Maximum mint amount per single transaction in stablecoin units; set at deploy (mainnet: $5,000,000).
    /// @dev    Per-transaction only. There is deliberately no per-address or per-period cap (see THREAT_MODEL).
    uint256 public maxMintAmount;

    /// @notice Decimal count every whitelisted stablecoin must report.
    /// @dev The conversion math (IndexOracle.stableToSLT) is hardcoded for 6-decimal stablecoins via
    ///      SLT_TO_STABLE_SCALE = 1e12. Whitelisting a token with different decimals (e.g. an 18-dec
    ///      "stable" such as DAI.e) would mis-scale mints by orders of magnitude, so setStablecoinAccepted
    ///      enforces this at whitelist time (finding: decimals assumption).
    uint8 public constant EXPECTED_STABLE_DECIMALS = 6;

    /// @notice Delay between proposing and executing a Treasury Safe change (finding M-03).
    /// @dev    In-contract timelock: no external TimelockController, no extra role topology. Gives
    ///         signers and watchers 24h to notice and cancel a hostile or mistaken redirect of
    ///         all future deposits.
    uint256 public constant TREASURY_SAFE_DELAY = 24 hours;

    /// @notice Treasury Safe address proposed via setTreasurySafe(); zero when nothing is pending.
    address public pendingTreasurySafe;

    /// @notice Earliest timestamp at which executeTreasurySafe() may apply the pending change.
    uint256 public pendingTreasurySafeExecutableAt;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    /// @notice Emitted on every successful mint.
    /// @param user        The address depositing stablecoin and receiving SLT.
    /// @param stablecoin  The stablecoin used (USDC or USDT address).
    /// @param stableAmount Amount of stablecoin deposited (6-decimal units).
    /// @param sltAmount   Amount of SLT minted (18-decimal units).
    /// @param indexUsed   The pricePerShare value used to compute the SLT amount.
    event Minted(
        address indexed user, address indexed stablecoin, uint256 stableAmount, uint256 sltAmount, uint256 indexUsed
    );

    /// @notice Emitted when a stablecoin is added to or removed from the whitelist.
    event StablecoinWhitelistUpdated(address indexed token, bool accepted);

    /// @notice Emitted when a stablecoin whitelist addition is proposed (H-1 timelock start).
    event StablecoinProposed(address indexed token, uint256 executableAt);

    /// @notice Emitted when a pending stablecoin proposal is cancelled (explicitly or by delisting).
    event StablecoinProposalCancelled(address indexed token);

    /// @notice Emitted when the Treasury Safe address actually changes (constructor or executeTreasurySafe).
    event TreasurySafeUpdated(address indexed previous, address indexed updated);

    /// @notice Emitted when a Treasury Safe change is proposed (M-03 timelock start).
    event TreasurySafeProposed(address indexed current, address indexed proposed, uint256 executableAt);

    /// @notice Emitted when a pending Treasury Safe proposal is cancelled.
    event TreasurySafeProposalCancelled(address indexed cancelled);

    /// @notice Emitted when mint limits are changed (constructor or setMintLimits).
    event MintLimitsUpdated(uint256 minAmount, uint256 maxAmount);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    /// @notice Reverts when attempting to mint with a non-whitelisted stablecoin.
    /// @param token The rejected token address.
    error MintContract_StablecoinNotAccepted(address token);

    /// @notice Reverts when the stable amount is outside [minMintAmount, maxMintAmount].
    /// @param amount The attempted amount.
    /// @param min    Configured minimum.
    /// @param max    Configured maximum.
    error MintContract_AmountOutOfBounds(uint256 amount, uint256 min, uint256 max);

    /// @notice Reverts when the oracle reports stale state via isFresh() == false.
    error MintContract_OracleStale();

    /// @notice Reverts when a constructor or setter argument is the zero address.
    error MintContract_ZeroAddress();

    /// @notice Reverts when mint limits are invalid (min == 0 or min > max).
    error MintContract_InvalidLimits();

    /// @notice Reverts when whitelisting a stablecoin whose decimals != EXPECTED_STABLE_DECIMALS.
    /// @param token The rejected token. @param actual The decimals it reported (0 if the call failed).
    error MintContract_UnexpectedDecimals(address token, uint8 actual);

    /// @notice Reverts when executeTreasurySafe()/cancelTreasurySafe() is called with no pending proposal.
    error MintContract_NoPendingTreasurySafe();

    /// @notice Reverts when executeTreasurySafe() is called before TREASURY_SAFE_DELAY has elapsed.
    error MintContract_TreasurySafeDelayNotElapsed();

    /// @notice Reverts when a proposed Treasury Safe is this contract, the SLT token or the current safe.
    /// @param proposed The rejected address.
    error MintContract_InvalidTreasurySafe(address proposed);

    /// @notice Reverts when executeStablecoinAccepted()/cancelStablecoinProposal() finds no pending proposal.
    /// @param token The token with no pending proposal.
    error MintContract_NoPendingStablecoin(address token);

    /// @notice Reverts when executeStablecoinAccepted() is called before STABLECOIN_DELAY has elapsed.
    /// @param token The token whose delay has not elapsed.
    error MintContract_StablecoinDelayNotElapsed(address token);

    /// @notice Reverts when the Treasury Safe received less than `stableAmount` (fee-on-transfer or
    ///         non-standard token behaviour, finding L-6).
    /// @param expected The amount requested. @param received The amount that actually arrived.
    error MintContract_TransferShortfall(uint256 expected, uint256 received);

    /// @notice Reverts when the SLT that would be minted is below the caller's minSltOut.
    /// @param minted The amount that would be minted. @param minSltOut The caller's floor.
    error MintContract_SlippageExceeded(uint256 minted, uint256 minSltOut);

    /// @notice Reverts when block.timestamp is past the caller's deadline.
    error MintContract_DeadlineExpired();

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /// @notice Deploy and initialize the MintContract.
    /// @param sltToken       SLT token contract address.
    /// @param oracle         IndexOracle contract address.
    /// @param safe           Treasury Safe address that receives all stable deposits.
    /// @param admin          Address granted DEFAULT_ADMIN_ROLE and CONFIG_ROLE (Treasury Safe).
    /// @param pauser         Address granted PAUSER_ROLE (Treasury Safe).
    /// @param _minMintAmount Initial minimum mint amount (6-decimal stable units).
    /// @param _maxMintAmount Initial maximum mint amount (6-decimal stable units).
    /// @param initialStablecoins Stablecoins whitelisted at deploy (USDC, USDT). Each must report 6
    ///        decimals. Later additions require the 24h propose/execute flow (H-1).
    /// @dev    Reverts with MintContract_ZeroAddress for any zero address (sltToken/oracle/safe/admin/
    ///         pauser/any stablecoin), MintContract_InvalidLimits if _minMintAmount == 0 or
    ///         _minMintAmount > _maxMintAmount, or MintContract_UnexpectedDecimals for a non-6-dec token.
    constructor(
        address sltToken,
        address oracle,
        address safe,
        address admin,
        address pauser,
        uint256 _minMintAmount,
        uint256 _maxMintAmount,
        address[] memory initialStablecoins
    ) {
        if (
            sltToken == address(0) || oracle == address(0) || safe == address(0) || admin == address(0)
                || pauser == address(0)
        ) {
            // pauser was previously unchecked — a zero pauser ships a mint contract nobody can pause.
            revert MintContract_ZeroAddress();
        }
        if (_minMintAmount == 0 || _minMintAmount > _maxMintAmount) {
            revert MintContract_InvalidLimits();
        }

        slt = ISLT(sltToken);
        indexOracle = IIndexOracle(oracle);
        treasurySafe = safe;
        minMintAmount = _minMintAmount;
        maxMintAmount = _maxMintAmount;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CONFIG_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);

        emit TreasurySafeUpdated(address(0), safe);
        emit MintLimitsUpdated(_minMintAmount, _maxMintAmount);

        for (uint256 i = 0; i < initialStablecoins.length; i++) {
            address token = initialStablecoins[i];
            if (token == address(0)) revert MintContract_ZeroAddress();
            // slither-disable-next-line calls-loop
            _requireSixDecimals(token);
            acceptedStablecoin[token] = true;
            emit StablecoinWhitelistUpdated(token, true);
        }
    }

    // -----------------------------------------------------------------------
    // Mint
    // -----------------------------------------------------------------------

    /// @notice Mint SLT by depositing an approved stablecoin (no slippage protection).
    /// @param stablecoin   The stablecoin to deposit (must be whitelisted).
    /// @param stableAmount The amount of stablecoin to deposit (6-decimal units).
    /// @return sltMinted   The amount of SLT minted to msg.sender (18-decimal units).
    /// @dev    Kept for interface stability (v1.0 signature). Equivalent to
    ///         mintSLT(stablecoin, stableAmount, 0, type(uint256).max). Front-ends SHOULD use the
    ///         4-argument overload so an oracle update landing before the tx cannot change the
    ///         received amount beyond the caller's tolerance.
    function mintSLT(
        address stablecoin,
        uint256 stableAmount
    ) external nonReentrant whenNotPaused returns (uint256 sltMinted) {
        return _mintSLT(stablecoin, stableAmount, 0, type(uint256).max);
    }

    /// @notice Mint SLT by depositing an approved stablecoin, with slippage and deadline protection.
    /// @param stablecoin   The stablecoin to deposit (must be whitelisted).
    /// @param stableAmount The amount of stablecoin to deposit (6-decimal units).
    /// @param minSltOut    Minimum SLT the caller accepts (18-decimal units); reverts below this.
    /// @param deadline     Latest block.timestamp at which the tx may execute.
    /// @return sltMinted   The amount of SLT minted to msg.sender (18-decimal units).
    /// @dev    Reverts with MintContract_StablecoinNotAccepted, MintContract_AmountOutOfBounds,
    ///         MintContract_OracleStale, MintContract_SlippageExceeded, MintContract_DeadlineExpired,
    ///         MintContract_TransferShortfall (Treasury Safe received less than stableAmount), or any
    ///         underlying SafeERC20/SLT.mint error. Protected by nonReentrant. Subject to Pausable.
    ///         The stablecoin is pulled from msg.sender directly to the Treasury Safe in a single
    ///         safeTransferFrom call (no intermediate balance held by this contract).
    function mintSLT(
        address stablecoin,
        uint256 stableAmount,
        uint256 minSltOut,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 sltMinted) {
        return _mintSLT(stablecoin, stableAmount, minSltOut, deadline);
    }

    /// @dev Shared mint path. Checks → external pull → mint → event (CEI; no state of this contract
    ///      is written, so there is nothing to reorder).
    function _mintSLT(
        address stablecoin,
        uint256 stableAmount,
        uint256 minSltOut,
        uint256 deadline
    ) internal returns (uint256 sltMinted) {
        // slither-disable-next-line timestamp
        if (block.timestamp > deadline) revert MintContract_DeadlineExpired();
        if (!acceptedStablecoin[stablecoin]) revert MintContract_StablecoinNotAccepted(stablecoin);
        if (stableAmount < minMintAmount || stableAmount > maxMintAmount) {
            revert MintContract_AmountOutOfBounds(stableAmount, minMintAmount, maxMintAmount);
        }
        if (!indexOracle.isFresh()) revert MintContract_OracleStale();

        uint256 indexUsed = indexOracle.pricePerShare();
        sltMinted = indexOracle.stableToSLT(stableAmount);
        if (sltMinted < minSltOut) revert MintContract_SlippageExceeded(sltMinted, minSltOut);

        // Pull stablecoin from depositor directly to the Treasury Safe (atomic forward) and verify the
        // Safe actually received the full amount (fee-on-transfer / non-standard token guard, L-6).
        address safe = treasurySafe;
        uint256 balanceBefore = IERC20(stablecoin).balanceOf(safe);
        IERC20(stablecoin).safeTransferFrom(msg.sender, safe, stableAmount);
        uint256 received = IERC20(stablecoin).balanceOf(safe) - balanceBefore;
        if (received != stableAmount) revert MintContract_TransferShortfall(stableAmount, received);

        // Mint SLT after stablecoin transfer succeeds.
        slt.mint(msg.sender, sltMinted);

        emit Minted(msg.sender, stablecoin, stableAmount, sltMinted, indexUsed);
    }

    // -----------------------------------------------------------------------
    // Configuration (CONFIG_ROLE / DEFAULT_ADMIN_ROLE)
    // -----------------------------------------------------------------------

    /// @notice Propose adding a stablecoin to the whitelist (accepted = true), or remove one immediately
    ///         (accepted = false).
    /// @param token    The stablecoin token address.
    /// @param accepted True to PROPOSE whitelisting (effective after executeStablecoinAccepted() once
    ///                 STABLECOIN_DELAY has elapsed), false to delist immediately.
    /// @dev    Restricted to CONFIG_ROLE. Signature kept from v1.0; semantics for `true` are now
    ///         propose-only (finding H-1). Delisting also cancels any pending proposal for the token.
    ///         Reverts with MintContract_ZeroAddress if token is zero, or MintContract_UnexpectedDecimals
    ///         if a proposed token does not report 6 decimals. Re-proposing restarts the clock.
    function setStablecoinAccepted(
        address token,
        bool accepted
    ) external onlyRole(CONFIG_ROLE) {
        if (token == address(0)) revert MintContract_ZeroAddress();
        if (accepted) {
            _requireSixDecimals(token);
            uint256 executableAt = block.timestamp + STABLECOIN_DELAY;
            pendingStablecoinExecutableAt[token] = executableAt;
            emit StablecoinProposed(token, executableAt);
        } else {
            // Delisting is never delayed or blocked, so a mistakenly-listed token can always be removed.
            if (pendingStablecoinExecutableAt[token] != 0) {
                pendingStablecoinExecutableAt[token] = 0;
                emit StablecoinProposalCancelled(token);
            }
            acceptedStablecoin[token] = false;
            emit StablecoinWhitelistUpdated(token, false);
        }
    }

    /// @notice Whitelist a stablecoin whose proposal delay has elapsed.
    /// @param token The proposed stablecoin.
    /// @dev    Restricted to CONFIG_ROLE. Re-checks decimals at execution (tokens are upgradeable).
    ///         Reverts with MintContract_NoPendingStablecoin or MintContract_StablecoinDelayNotElapsed.
    function executeStablecoinAccepted(
        address token
    ) external onlyRole(CONFIG_ROLE) {
        uint256 executableAt = pendingStablecoinExecutableAt[token];
        if (executableAt == 0) revert MintContract_NoPendingStablecoin(token);
        // slither-disable-next-line timestamp
        if (block.timestamp < executableAt) revert MintContract_StablecoinDelayNotElapsed(token);
        _requireSixDecimals(token);
        pendingStablecoinExecutableAt[token] = 0;
        acceptedStablecoin[token] = true;
        emit StablecoinWhitelistUpdated(token, true);
    }

    /// @notice Cancel a pending stablecoin whitelist proposal.
    /// @param token The proposed stablecoin.
    /// @dev    Restricted to CONFIG_ROLE. Reverts with MintContract_NoPendingStablecoin if none pending.
    function cancelStablecoinProposal(
        address token
    ) external onlyRole(CONFIG_ROLE) {
        if (pendingStablecoinExecutableAt[token] == 0) revert MintContract_NoPendingStablecoin(token);
        pendingStablecoinExecutableAt[token] = 0;
        emit StablecoinProposalCancelled(token);
    }

    /// @dev Enforce the 6-decimal assumption the conversion math (SLT_TO_STABLE_SCALE = 1e12) depends on.
    function _requireSixDecimals(
        address token
    ) internal view {
        try IERC20Metadata(token).decimals() returns (uint8 dec) {
            if (dec != EXPECTED_STABLE_DECIMALS) revert MintContract_UnexpectedDecimals(token, dec);
        } catch {
            revert MintContract_UnexpectedDecimals(token, 0);
        }
    }

    /// @notice Propose a new Treasury Safe. Takes effect only after executeTreasurySafe() is called
    ///         once TREASURY_SAFE_DELAY (24h) has elapsed (finding M-03).
    /// @param newSafe Proposed Treasury Safe address.
    /// @dev    Restricted to DEFAULT_ADMIN_ROLE. Re-proposing overwrites the pending proposal and
    ///         restarts the 24h clock. Deposits keep flowing to the current safe until execution.
    ///         Signature kept from v1.0 for interface stability; semantics are now propose-only.
    function setTreasurySafe(
        address newSafe
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newSafe == address(0)) revert MintContract_ZeroAddress();
        // A safe that is this contract, the token, or the current safe would brick or no-op mints (L-5).
        if (newSafe == address(this) || newSafe == address(slt) || newSafe == treasurySafe) {
            revert MintContract_InvalidTreasurySafe(newSafe);
        }
        uint256 executableAt = block.timestamp + TREASURY_SAFE_DELAY;
        pendingTreasurySafe = newSafe;
        pendingTreasurySafeExecutableAt = executableAt;
        emit TreasurySafeProposed(treasurySafe, newSafe, executableAt);
    }

    /// @notice Apply the pending Treasury Safe proposal once the delay has elapsed.
    /// @dev    Restricted to DEFAULT_ADMIN_ROLE. Clears the pending state on success.
    function executeTreasurySafe() external onlyRole(DEFAULT_ADMIN_ROLE) {
        address newSafe = pendingTreasurySafe;
        if (newSafe == address(0)) revert MintContract_NoPendingTreasurySafe();
        // slither-disable-next-line timestamp
        if (block.timestamp < pendingTreasurySafeExecutableAt) revert MintContract_TreasurySafeDelayNotElapsed();
        address previous = treasurySafe;
        treasurySafe = newSafe;
        pendingTreasurySafe = address(0);
        pendingTreasurySafeExecutableAt = 0;
        emit TreasurySafeUpdated(previous, newSafe);
    }

    /// @notice Cancel the pending Treasury Safe proposal.
    /// @dev    Restricted to DEFAULT_ADMIN_ROLE. Reverts if nothing is pending.
    function cancelTreasurySafe() external onlyRole(DEFAULT_ADMIN_ROLE) {
        address cancelled = pendingTreasurySafe;
        if (cancelled == address(0)) revert MintContract_NoPendingTreasurySafe();
        pendingTreasurySafe = address(0);
        pendingTreasurySafeExecutableAt = 0;
        emit TreasurySafeProposalCancelled(cancelled);
    }

    /// @notice Update the per-transaction mint amount limits.
    /// @param newMin New minimum mint amount (6-decimal stable units).
    /// @param newMax New maximum mint amount (6-decimal stable units).
    /// @dev    Restricted to CONFIG_ROLE. Reverts with MintContract_InvalidLimits if newMin == 0
    ///         or newMin > newMax. Emits MintLimitsUpdated.
    function setMintLimits(
        uint256 newMin,
        uint256 newMax
    ) external onlyRole(CONFIG_ROLE) {
        if (newMin == 0 || newMin > newMax) revert MintContract_InvalidLimits();
        minMintAmount = newMin;
        maxMintAmount = newMax;
        emit MintLimitsUpdated(newMin, newMax);
    }

    /// @notice Pause minting. Existing SLT remains transferable. Restricted to PAUSER_ROLE.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resume minting. Restricted to PAUSER_ROLE.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
