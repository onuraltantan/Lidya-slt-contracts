// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
    /// @dev    Updatable by DEFAULT_ADMIN_ROLE via setTreasurySafe().
    address public treasurySafe;

    /// @notice Whitelist of accepted stablecoin token addresses.
    /// @dev    Toggled via setStablecoinAccepted() (CONFIG_ROLE).
    mapping(address => bool) public acceptedStablecoin;

    /// @notice Minimum mint amount in stablecoin units (6 decimals). Default $1,000.
    uint256 public minMintAmount;

    /// @notice Maximum mint amount per single transaction in stablecoin units. Default $5,000,000.
    uint256 public maxMintAmount;

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
        address indexed user,
        address indexed stablecoin,
        uint256 stableAmount,
        uint256 sltAmount,
        uint256 indexUsed
    );

    /// @notice Emitted when a stablecoin is added to or removed from the whitelist.
    event StablecoinWhitelistUpdated(address indexed token, bool accepted);

    /// @notice Emitted when the Treasury Safe address is updated (constructor or setTreasurySafe).
    event TreasurySafeUpdated(address indexed previous, address indexed updated);

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
    /// @dev    Reverts with MintContract_ZeroAddress for any zero address (sltToken/oracle/safe/admin)
    ///         or MintContract_InvalidLimits if _minMintAmount == 0 or _minMintAmount > _maxMintAmount.
    constructor(
        address sltToken,
        address oracle,
        address safe,
        address admin,
        address pauser,
        uint256 _minMintAmount,
        uint256 _maxMintAmount
    ) {
        if (sltToken == address(0) || oracle == address(0) || safe == address(0) || admin == address(0)) {
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
    }

    // -----------------------------------------------------------------------
    // Mint
    // -----------------------------------------------------------------------

    /// @notice Mint SLT by depositing an approved stablecoin.
    /// @param stablecoin   The stablecoin to deposit (must be whitelisted via setStablecoinAccepted).
    /// @param stableAmount The amount of stablecoin to deposit (6-decimal units).
    /// @return sltMinted   The amount of SLT minted to msg.sender (18-decimal units).
    /// @dev    Reverts with MintContract_StablecoinNotAccepted if stablecoin is not whitelisted,
    ///         MintContract_AmountOutOfBounds if stableAmount is outside [min, max],
    ///         MintContract_OracleStale if the oracle isFresh() returns false, or any underlying
    ///         SafeERC20/SLT.mint error. Protected by nonReentrant. Subject to Pausable.
    ///         The stablecoin is pulled from msg.sender directly to the Treasury Safe in a single
    ///         safeTransferFrom call (no intermediate balance held by this contract).
    function mintSLT(address stablecoin, uint256 stableAmount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 sltMinted)
    {
        if (!acceptedStablecoin[stablecoin]) revert MintContract_StablecoinNotAccepted(stablecoin);
        if (stableAmount < minMintAmount || stableAmount > maxMintAmount) {
            revert MintContract_AmountOutOfBounds(stableAmount, minMintAmount, maxMintAmount);
        }
        if (!indexOracle.isFresh()) revert MintContract_OracleStale();

        uint256 indexUsed = indexOracle.pricePerShare();
        sltMinted = indexOracle.stableToSLT(stableAmount);

        // Pull stablecoin from depositor directly to the Treasury Safe (atomic forward).
        IERC20(stablecoin).safeTransferFrom(msg.sender, treasurySafe, stableAmount);

        // Mint SLT after stablecoin transfer succeeds.
        slt.mint(msg.sender, sltMinted);

        emit Minted(msg.sender, stablecoin, stableAmount, sltMinted, indexUsed);
    }

    // -----------------------------------------------------------------------
    // Configuration (CONFIG_ROLE / DEFAULT_ADMIN_ROLE)
    // -----------------------------------------------------------------------

    /// @notice Add or remove a stablecoin from the mint whitelist.
    /// @param token    The stablecoin token address.
    /// @param accepted True to whitelist, false to delist.
    /// @dev    Restricted to CONFIG_ROLE. Reverts with MintContract_ZeroAddress if token is zero.
    ///         Emits StablecoinWhitelistUpdated.
    function setStablecoinAccepted(address token, bool accepted) external onlyRole(CONFIG_ROLE) {
        if (token == address(0)) revert MintContract_ZeroAddress();
        acceptedStablecoin[token] = accepted;
        emit StablecoinWhitelistUpdated(token, accepted);
    }

    /// @notice Update the Treasury Safe address that receives stablecoin deposits.
    /// @param newSafe The new Treasury Safe address.
    /// @dev    Restricted to DEFAULT_ADMIN_ROLE. Reverts with MintContract_ZeroAddress if zero.
    ///         Emits TreasurySafeUpdated.
    function setTreasurySafe(address newSafe) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newSafe == address(0)) revert MintContract_ZeroAddress();
        emit TreasurySafeUpdated(treasurySafe, newSafe);
        treasurySafe = newSafe;
    }

    /// @notice Update the per-transaction mint amount limits.
    /// @param newMin New minimum mint amount (6-decimal stable units).
    /// @param newMax New maximum mint amount (6-decimal stable units).
    /// @dev    Restricted to CONFIG_ROLE. Reverts with MintContract_InvalidLimits if newMin == 0
    ///         or newMin > newMax. Emits MintLimitsUpdated.
    function setMintLimits(uint256 newMin, uint256 newMax) external onlyRole(CONFIG_ROLE) {
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
