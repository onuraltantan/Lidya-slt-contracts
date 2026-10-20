// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title IMintContractView
/// @notice Minimal read surface SLT uses to verify a minter is a MintContract wired to this token.
interface IMintContractView {
    /// @notice The SLT token the MintContract mints into.
    function slt() external view returns (address);
}
