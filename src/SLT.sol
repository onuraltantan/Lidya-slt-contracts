// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IIndexOracle} from "./interfaces/IIndexOracle.sol";
import {ISLT} from "./interfaces/ISLT.sol";

/// @title SLT — Synthetic Liquidity Token
/// @author Blockxell
/// @notice Permissionless ERC-20 token whose value tracks an off-chain performance index via oracle.
/// @dev    Exposes index-based read-only metadata (pricePerShare, syntheticTotalValue,
///         sltForIndexValue, indexValueForSLT) for DeFi integrations — deliberately NOT the
///         ERC-4626 function names, to avoid 18-dec index values being read as a 6-dec asset
///         surface. Deposits/withdrawals are NOT handled by this
///         contract — minting occurs through MintContract, and exit is via secondary markets only.
///         No redemption rights. Holders have no claim on treasury assets at the contract layer;
///         the underlying economic exposure is governed off-chain by the BVI Issuer SPV.
contract SLT is ERC20, AccessControl, Pausable, ISLT {
    // -----------------------------------------------------------------------
    // Role identifiers
    // -----------------------------------------------------------------------

    /// @notice Role allowed to mint new SLT supply. Granted to MintContract only.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Role allowed to perform restricted administrative burns
    ///         (treasury reconciliation, erroneous-mint correction). Granted to Treasury Safe only.
    /// @dev    Burns do NOT pay out anything to the holder. They are a state-correction tool only.
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @notice Role allowed to pause/unpause transfers, mints, and burns in emergencies.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Sentinel role used to permanently lock MINTER_ROLE administration.
    /// @dev    Never granted to any address, and set as its own role-admin when
    ///         lockMinterRole() is called. Once it becomes MINTER_ROLE's admin, no address
    ///         can ever grant or revoke MINTER_ROLE again (members may still renounce).
    bytes32 public constant MINTER_ADMIN_LOCK = keccak256("MINTER_ADMIN_LOCK");

    // -----------------------------------------------------------------------
    // Immutables / constants
    // -----------------------------------------------------------------------

    /// @notice Index oracle contract used for ERC-4626-style metadata.
    /// @dev    Set at deployment, immutable thereafter.
    IIndexOracle public immutable indexOracle;

    /// @notice Index precision constant (1e18).
    uint256 public constant INDEX_PRECISION = 1e18;

    // -----------------------------------------------------------------------
    // Mutable state
    // -----------------------------------------------------------------------

    /// @notice Addresses adminBurn may burn from (treasury-controlled addresses only).
    /// @dev    Managed by DEFAULT_ADMIN_ROLE via setBurnSource(). The issuer can NEVER burn
    ///         from an address outside this list — holder balances are untouchable by design.
    mapping(address => bool) public authorizedBurnSource;

    /// @notice True once lockMinterRole() has been called. Irreversible.
    bool public minterRoleLocked;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    /// @notice Emitted when a burn-source authorization changes.
    event BurnSourceSet(address indexed source, bool authorized);

    /// @notice Emitted once when MINTER_ROLE administration is permanently locked.
    event MinterRoleLocked(address indexed caller);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    /// @notice Reverts when a constructor or function argument is the zero address.
    error SLT_ZeroAddress();

    /// @notice Reverts when a mint or burn amount is zero.
    error SLT_ZeroAmount();

    /// @notice Reverts when adminBurn targets an address not on the authorized burn-source list.
    /// @param from The unauthorized address.
    error SLT_BurnSourceNotAuthorized(address from);

    /// @notice Reverts when lockMinterRole() is called more than once.
    error SLT_MinterRoleAlreadyLocked();

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /// @notice Deploy SLT with initial admin, pauser, and oracle wiring.
    /// @param admin  Address granted DEFAULT_ADMIN_ROLE and BURNER_ROLE (Treasury Safe).
    /// @param pauser Address granted PAUSER_ROLE (Treasury Safe).
    /// @param oracle IndexOracle contract address used for ERC-4626 metadata.
    /// @dev    MINTER_ROLE is intentionally NOT granted in the constructor. It must be granted
    ///         to the MintContract via a post-deployment Safe transaction.
    constructor(address admin, address pauser, address oracle)
        ERC20("Synthetic Liquidity Token", "SLT")
    {
        if (admin == address(0) || pauser == address(0) || oracle == address(0)) {
            revert SLT_ZeroAddress();
        }
        indexOracle = IIndexOracle(oracle);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);
        _grantRole(BURNER_ROLE, admin); // Admin (Treasury Safe) is the burner.
        // MINTER_ROLE granted later, post-deployment, to the MintContract.

        // Seal the MINTER_ADMIN_LOCK sentinel at construction: make it its own role-admin so it
        // can never be granted to any address. Without this, DEFAULT_ADMIN could grant the sentinel
        // to an address BEFORE lockMinterRole() runs, creating a permanent, unrevocable authority to
        // grant MINTER_ROLE that survives the lock. Sealing here closes that window (finding H-01).
        _setRoleAdmin(MINTER_ADMIN_LOCK, MINTER_ADMIN_LOCK);
    }

    // -----------------------------------------------------------------------
    // Mint / burn
    // -----------------------------------------------------------------------

    /// @inheritdoc ISLT
    /// @dev Reverts with SLT_ZeroAddress if `to` is zero, SLT_ZeroAmount if `amount` is zero,
    ///      AccessControl error if caller lacks MINTER_ROLE, or Pausable error if paused.
    function mint(address to, uint256 amount) external override onlyRole(MINTER_ROLE) whenNotPaused {
        if (to == address(0)) revert SLT_ZeroAddress();
        if (amount == 0) revert SLT_ZeroAmount();
        _mint(to, amount);
    }

    /// @inheritdoc ISLT
    /// @dev Does NOT pay out anything. Intended for treasury reconciliation only.
    ///      `from` MUST be on the authorized burn-source list (treasury-controlled addresses) —
    ///      the issuer cannot burn from arbitrary holder addresses.
    ///      Reverts with SLT_ZeroAddress if `from` is zero, SLT_ZeroAmount if `amount` is zero,
    ///      SLT_BurnSourceNotAuthorized if `from` is not authorized, or AccessControl error if
    ///      caller lacks BURNER_ROLE. Note: not gated by Pausable — reconciliation must be
    ///      possible even when transfers are paused.
    function adminBurn(address from, uint256 amount) external override onlyRole(BURNER_ROLE) {
        if (from == address(0)) revert SLT_ZeroAddress();
        if (amount == 0) revert SLT_ZeroAmount();
        if (!authorizedBurnSource[from]) revert SLT_BurnSourceNotAuthorized(from);
        _burn(from, amount);
    }

    /// @notice Authorize or de-authorize an address as a valid adminBurn source.
    /// @param source     Address to update (expected: Treasury Safe or other treasury-controlled address).
    /// @param authorized True to allow adminBurn from `source`, false to disallow.
    /// @dev    Restricted to DEFAULT_ADMIN_ROLE (Treasury Safe). This list is the code-level
    ///         guarantee that holder balances are untouchable: burns can only ever originate
    ///         from addresses the treasury itself controls and has explicitly listed.
    function setBurnSource(address source, bool authorized) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (source == address(0)) revert SLT_ZeroAddress();
        authorizedBurnSource[source] = authorized;
        emit BurnSourceSet(source, authorized);
    }

    /// @notice Permanently lock MINTER_ROLE administration. One-way; callable once.
    /// @dev    Intended deployment sequence: (1) deploy SLT, (2) grant MINTER_ROLE to
    ///         MintContract, (3) call lockMinterRole(). After locking, MINTER_ROLE's role-admin
    ///         is MINTER_ADMIN_LOCK — a sentinel role that is its own admin and is never granted —
    ///         so no address (including DEFAULT_ADMIN_ROLE) can ever grant or revoke MINTER_ROLE.
    ///         This makes the WP claim "a compromised admin multisig cannot bypass the mint flow"
    ///         true at the code level. Trade-off: MintContract can never be replaced without
    ///         deploying a new token.
    function lockMinterRole() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (minterRoleLocked) revert SLT_MinterRoleAlreadyLocked();
        minterRoleLocked = true;
        _setRoleAdmin(MINTER_ROLE, MINTER_ADMIN_LOCK);
        _setRoleAdmin(MINTER_ADMIN_LOCK, MINTER_ADMIN_LOCK);
        emit MinterRoleLocked(msg.sender);
    }

    // -----------------------------------------------------------------------
    // Pause / unpause
    // -----------------------------------------------------------------------

    /// @notice Pause all transfers, mints, and burns triggered through `_update`.
    /// @dev    Restricted to PAUSER_ROLE. Note: adminBurn is intentionally NOT gated by paused
    ///         state so reconciliation remains possible during emergencies.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resume transfers, mints, and burns. Restricted to PAUSER_ROLE.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // -----------------------------------------------------------------------
    // Index-based read-only metadata.
    // NOT an ERC-4626 vault — does not implement deposit/withdraw/mint/redeem,
    // and deliberately does NOT reuse the ERC-4626 function names (totalAssets/
    // convertToShares/convertToAssets) so that integrators cannot mistake these
    // 18-decimal index values for a real 6-decimal stablecoin asset surface.
    // All values below are expressed in 18-decimal index units, NOT in the
    // underlying stablecoin's 6-decimal units. For stablecoin<->SLT conversion at
    // the current index, use IndexOracle.stableToSLT / sltToStable.
    // -----------------------------------------------------------------------

    /// @inheritdoc ISLT
    function pricePerShare() external view override returns (uint256) {
        return indexOracle.pricePerShare();
    }

    /// @inheritdoc ISLT
    /// @notice Freshness passthrough. Integrators that read pricePerShare()/the metadata below off
    ///         SLT directly (rather than off IndexOracle) MUST gate on this: the metadata functions
    ///         return the last-known index even while the oracle is paused or stale (finding M-05).
    function isFresh() external view override returns (bool) {
        return indexOracle.isFresh();
    }

    /// @inheritdoc ISLT
    /// @notice Timestamp of the oracle's last index update, exposed for integrator staleness checks.
    function lastUpdateTimestamp() external view override returns (uint256) {
        return indexOracle.lastUpdateTimestamp();
    }

    /// @notice Synthetic total value of supply in 18-decimal index units: totalSupply * index / 1e18.
    /// @return Mathematical representation of the indexed value of all SLT in circulation.
    /// @dev    NOT a custody balance and NOT a 6-decimal stablecoin figure. Treasury assets are
    ///         owned by the BVI Issuer SPV off-contract. Purely a pricing-model input.
    function syntheticTotalValue() external view returns (uint256) {
        return (totalSupply() * indexOracle.pricePerShare()) / INDEX_PRECISION;
    }

    /// @notice How many SLT correspond to a given 18-decimal index-value amount, at the current index.
    /// @param indexValue Value amount in 18-decimal index units (NOT 6-decimal stablecoin units).
    /// @return Equivalent SLT amount in 18-decimal units.
    function sltForIndexValue(uint256 indexValue) external view returns (uint256) {
        return (indexValue * INDEX_PRECISION) / indexOracle.pricePerShare();
    }

    /// @notice The 18-decimal index value of a given SLT amount, at the current index.
    /// @param sltAmount SLT amount in 18-decimal units.
    /// @return Equivalent value in 18-decimal index units (NOT 6-decimal stablecoin units).
    function indexValueForSLT(uint256 sltAmount) external view returns (uint256) {
        return (sltAmount * indexOracle.pricePerShare()) / INDEX_PRECISION;
    }

    // -----------------------------------------------------------------------
    // ERC-20 transfer hook with pause check.
    // -----------------------------------------------------------------------

    /// @dev OpenZeppelin v5 hook overridden so that a pause halts holder-to-holder TRANSFERS only.
    ///      New mints are gated independently by mint()'s whenNotPaused + MINTER_ROLE; admin
    ///      reconciliation burns (adminBurn) must remain possible while paused. Mints have
    ///      from == address(0); burns have to == address(0) — neither is treated as a transfer here.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            _requireNotPaused();
        }
        super._update(from, to, value);
    }
}
