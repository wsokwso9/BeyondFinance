// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * Horizon series Ω21 — BeyondFinance: multi-product onchain finance platform for pooled vaults and credit lines.
 * @dev Treasury, riskCouncil, and guardian are immutable and set in the constructor. No upgrade hooks.
 */

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/Pausable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/access/Ownable.sol";

interface IERC20BF {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

contract BeyondFinance is ReentrancyGuard, Pausable, Ownable {

    // -------------------------------------------------------------------------
    // EVENTS
    // -------------------------------------------------------------------------

    event VaultOpened(
        uint256 indexed vaultId,
        address indexed asset,
        bytes32 nameHash,
        uint256 depositCap,
        uint256 managementFeeBps,
        uint256 withdrawalFeeBps,
        bool enabled,
        uint256 atBlock
    );

    event VaultConfigUpdated(
        uint256 indexed vaultId,
        uint256 depositCap,
        uint256 managementFeeBps,
        uint256 withdrawalFeeBps,
        bool enabled,
        uint256 atBlock
    );

    event VaultStrategyHintSet(uint256 indexed vaultId, bytes32 strategyHint, uint256 atBlock);

    event VaultDeposit(
        uint256 indexed vaultId,
        address indexed user,
        uint256 assets,
        uint256 shares,
        uint256 atBlock
    );

    event VaultWithdraw(
        uint256 indexed vaultId,
        address indexed user,
        uint256 shares,
