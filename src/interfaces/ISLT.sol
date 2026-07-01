// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title ISLT
/// @notice Minimal interface exposing SLT token mint/burn entry points used by trusted callers.
interface ISLT {
    /// @notice Mints SLT to a recipient. Restricted to MINTER_ROLE.
    function mint(address to, uint256 amount) external;

    /// @notice Burns SLT from a holder. Restricted to BURNER_ROLE.
    /// @dev Used only for treasury reconciliation and erroneous-mint correction. Never user-callable.
    function adminBurn(address from, uint256 amount) external;

    /// @notice Returns the current SLT index from the configured oracle.
    function pricePerShare() external view returns (uint256);
}
