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
        uint256 assetsAfterFee,
        uint256 feeAssets,
        uint256 atBlock
    );

    event VaultHarvested(
        uint256 indexed vaultId,
        uint256 gainAssets,
        uint256 protocolFeeAssets,
        uint256 atBlock
    );

    event CreditLineOpened(
        uint256 indexed lineId,
        address indexed borrower,
        address indexed asset,
        uint256 limit,
        uint256 rateBps,
        uint256 atBlock
    );

    event CreditLineUpdated(
        uint256 indexed lineId,
        uint256 limit,
        uint256 rateBps,
        bool frozen,
        uint256 atBlock
    );

    event CreditDrawn(
        uint256 indexed lineId,
        address indexed borrower,
        uint256 assets,
        uint256 atBlock
    );

    event CreditRepaid(
        uint256 indexed lineId,
        address indexed payer,
        uint256 principalRepaid,
        uint256 interestPaid,
        uint256 atBlock
    );

    event GuardianGlobalPauseSet(bool paused, uint256 atBlock);
    event GuardianSet(address indexed previousGuardian, address indexed newGuardian, uint256 atBlock);
    event RiskCouncilSet(address indexed previous, address indexed current, uint256 atBlock);
    event ProtocolFeesWithdrawn(address indexed to, uint256 amount, uint256 atBlock);
    event UserTagsSet(address indexed user, bytes32 tagsHash, uint256 atBlock);

    // -------------------------------------------------------------------------
    // ERRORS
    // -------------------------------------------------------------------------

    error BFIN_ZeroAddress();
    error BFIN_ZeroAmount();
    error BFIN_VaultNotFound();
    error BFIN_VaultDisabled();
    error BFIN_DepositCapExceeded();
    error BFIN_InsufficientShares();
    error BFIN_InvalidFeeBps();
