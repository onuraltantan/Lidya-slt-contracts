// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title IIndexOracle
/// @notice Read-only interface for the SLT performance index oracle.
/// @dev Consumers (MintContract, DeFi integrators, risk engines) call pricePerShare() to value SLT.
interface IIndexOracle {
    /// @notice Returns the current SLT index value, scaled to 1e18.
    /// @dev Index represents performance accrual since inception. Initialized at 1e18.
    function pricePerShare() external view returns (uint256);

    /// @notice Returns the timestamp of the last index update.
    function lastUpdateTimestamp() external view returns (uint256);

    /// @notice Returns whether the oracle is currently considered fresh.
    /// @dev If staleness exceeds graceperiod, integrations should treat the oracle as paused.
    function isFresh() external view returns (bool);

    /// @notice Convert a stablecoin amount (in 6-decimal units) to SLT amount (18-decimal units) at current index.
    function stableToSLT(uint256 stableAmount) external view returns (uint256);

    /// @notice Convert an SLT amount (18-decimal units) to stablecoin amount (6-decimal units) at current index.
    function sltToStable(uint256 sltAmount) external view returns (uint256);

    event IndexUpdated(uint256 indexed newIndex, uint256 indexed previousIndex, int256 deltaBps, uint256 timestamp);
    event OraclePaused(address indexed by, string reason);
    event OracleResumed(address indexed by);
}
