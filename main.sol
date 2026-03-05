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
    error BFIN_TransferFailed();
    error BFIN_MaxVaults();
    error BFIN_MaxCreditLines();
    error BFIN_CreditLineNotFound();
    error BFIN_NotBorrower();
    error BFIN_LineFrozen();
    error BFIN_LimitExceeded();
    error BFIN_Reentrancy();
    error BFIN_NotGuardian();
    error BFIN_NotRiskCouncil();
    error BFIN_ArrayLengthMismatch();
    error BFIN_BatchTooLarge();
    error BFIN_InvalidRate();
    error BFIN_TooManyTags();
    error BFIN_InvalidIndex();

    // -------------------------------------------------------------------------
    // CONSTANTS
    // -------------------------------------------------------------------------

    uint256 public constant BFIN_BPS_BASE = 10_000;
    uint256 public constant BFIN_MAX_MANAGEMENT_FEE_BPS = 700;   // 7%
    uint256 public constant BFIN_MAX_WITHDRAWAL_FEE_BPS = 350;   // 3.5%
    uint256 public constant BFIN_MAX_PROTOCOL_FEE_BPS = 1500;    // 15%
    uint256 public constant BFIN_MAX_RATE_BPS = 3_000;           // 30% simple APR
    uint256 public constant BFIN_MAX_VAULTS = 72;
    uint256 public constant BFIN_MAX_LINES = 128;
    uint256 public constant BFIN_MAX_BATCH = 24;
    bytes32 public constant BFIN_DOMAIN = keccak256("BeyondFinance.Core.v1");
    uint256 public constant BFIN_DOMAIN_SALT = 0xC4A9E7B2D3F15489A602B1D7C8F0E36A952C47F1E3A8B5D6C0E49A7B3D5C29F7;

    // -------------------------------------------------------------------------
    // IMMUTABLES
    // -------------------------------------------------------------------------

    address public immutable treasury;
    address public immutable riskCouncil;
    address public immutable guardian;
    uint256 public immutable deployedBlock;
    bytes32 public immutable genesisHash;

    // -------------------------------------------------------------------------
    // STATE
    // -------------------------------------------------------------------------

    struct Vault {
        address asset;
        bytes32 nameHash;
        bytes32 strategyHint;
        uint256 totalAssets;
        uint256 totalShares;
        uint256 depositCap;
        uint256 managementFeeBps;
        uint256 withdrawalFeeBps;
        uint256 lastAccrualBlock;
        bool enabled;
    }

    struct CreditLine {
        address borrower;
        address asset;
        uint256 limit;
        uint256 rateBps;
        uint256 borrowed;
        uint256 lastAccrualBlock;
        bool frozen;
    }

    struct VaultView {
        uint256 vaultId;
        address asset;
        uint256 totalAssets;
        uint256 totalShares;
        uint256 depositCap;
        uint256 managementFeeBps;
        uint256 withdrawalFeeBps;
        uint256 lastAccrualBlock;
        bool enabled;
        bytes32 nameHash;
        bytes32 strategyHint;
    }

    struct CreditLineView {
        uint256 lineId;
        address borrower;
        address asset;
        uint256 limit;
        uint256 rateBps;
        uint256 borrowed;
        uint256 lastAccrualBlock;
        bool frozen;
    }

    // vaultId => Vault
    mapping(uint256 => Vault) public vaults;
    // vaultId => user => shares
    mapping(uint256 => mapping(address => uint256)) public vaultShares;
    // lineId => CreditLine
    mapping(uint256 => CreditLine) public creditLines;
    // user => tags
    mapping(address => bytes32) public userTagsHash;

    uint256[] private _vaultIds;
    uint256[] private _lineIds;
    uint256 public vaultCounter;
    uint256 public lineCounter;
    uint256 public protocolFeeBps;
    uint256 public protocolFeeAssets; // accumulated fees in native accounting units (sum across vaults/assets, conceptual)

    // -------------------------------------------------------------------------
    // MODIFIERS
    // -------------------------------------------------------------------------

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert BFIN_NotGuardian();
        _;
    }

    modifier onlyRiskCouncil() {
        if (msg.sender != riskCouncil) revert BFIN_NotRiskCouncil();
        _;
    }
