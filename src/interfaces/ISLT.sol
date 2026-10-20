// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title ISLT
/// @notice Minimal interface exposing SLT token mint/burn entry points used by trusted callers.
interface ISLT {
    /// @notice Mints SLT to a recipient. Restricted to MINTER_ROLE.
    function mint(
        address to,
        uint256 amount
    ) external;

    /// @notice Burns SLT from an authorized burn source (Treasury Safe). Restricted to BURNER_ROLE.
    ///         Holder balances cannot be burned: `from` must be in `authorizedBurnSource`.
    /// @dev Used only for treasury reconciliation and erroneous-mint correction. Never user-callable.
    function adminBurn(
        address from,
        uint256 amount
    ) external;

    /// @notice Returns the current SLT index from the configured oracle.
    function pricePerShare() external view returns (uint256);

    /// @notice Returns whether the underlying oracle is currently fresh (passthrough).
    /// @dev Integrators pricing off SLT must gate on this; the index reads return last-known values
    ///      even while the oracle is paused or stale.
    function isFresh() external view returns (bool);

    /// @notice Returns the underlying oracle's last index-update timestamp (passthrough).
    function lastUpdateTimestamp() external view returns (uint256);
}
