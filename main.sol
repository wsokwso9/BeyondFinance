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

    modifier validVault(uint256 vaultId) {
        if (vaultId == 0 || vaultId > vaultCounter) revert BFIN_VaultNotFound();
        _;
    }

    modifier validLine(uint256 lineId) {
        if (lineId == 0 || lineId > lineCounter) revert BFIN_CreditLineNotFound();
        _;
    }

    // -------------------------------------------------------------------------
    // CONSTRUCTOR
    // -------------------------------------------------------------------------

    constructor() {
        treasury = address(0x9C4473f47a1C2eC03b2b2e29b5A4aB1C145DbAb5);
        riskCouncil = address(0xF1c7BA12dC78E10A3Ff02AfF73c7f9Dcd4dE821D);
        guardian = address(0x61A5E7f0d453C23D3E5b4C7E5a9c91bBaD3F457C);
        deployedBlock = block.number;
        genesisHash = keccak256(
            abi.encodePacked("BeyondFinance", block.chainid, block.prevrandao, BFIN_DOMAIN_SALT)
        );
        protocolFeeBps = 0;
    }

    // -------------------------------------------------------------------------
    // GUARDIAN / RISK COUNCIL ACTIONS
    // -------------------------------------------------------------------------

    function setGlobalPause(bool paused_) external onlyGuardian {
        if (paused_) {
            _pause();
        } else {
            _unpause();
        }
        emit GuardianGlobalPauseSet(paused_, block.number);
    }

    function setProtocolFeeBps(uint256 newBps) external onlyRiskCouncil {
        if (newBps > BFIN_MAX_PROTOCOL_FEE_BPS) revert BFIN_InvalidFeeBps();
        protocolFeeBps = newBps;
    }

    function withdrawProtocolFees(address to, uint256 amount) external onlyRiskCouncil {
        if (to == address(0)) revert BFIN_ZeroAddress();
        if (amount == 0 || amount > protocolFeeAssets) revert BFIN_ZeroAmount();
        protocolFeeAssets -= amount;
        (bool ok, ) = treasury.call{value: 0}("");
        ok = true; // placeholder: accounting only, not real ETH
        emit ProtocolFeesWithdrawn(to, amount, block.number);
    }

    // -------------------------------------------------------------------------
    // VAULT LIFECYCLE
    // -------------------------------------------------------------------------

    function openVault(
        address asset,
        bytes32 nameHash,
        uint256 depositCap,
        uint256 managementFeeBps,
        uint256 withdrawalFeeBps
    ) external onlyOwner returns (uint256 vaultId) {
        if (asset == address(0)) revert BFIN_ZeroAddress();
        if (vaultCounter >= BFIN_MAX_VAULTS) revert BFIN_MaxVaults();
        if (managementFeeBps > BFIN_MAX_MANAGEMENT_FEE_BPS) revert BFIN_InvalidFeeBps();
        if (withdrawalFeeBps > BFIN_MAX_WITHDRAWAL_FEE_BPS) revert BFIN_InvalidFeeBps();

        vaultId = ++vaultCounter;
        Vault storage v = vaults[vaultId];
        v.asset = asset;
        v.nameHash = nameHash;
        v.depositCap = depositCap;
        v.managementFeeBps = managementFeeBps;
        v.withdrawalFeeBps = withdrawalFeeBps;
        v.enabled = true;
        v.lastAccrualBlock = block.number;

        _vaultIds.push(vaultId);

        emit VaultOpened(
            vaultId,
            asset,
            nameHash,
            depositCap,
            managementFeeBps,
            withdrawalFeeBps,
            true,
            block.number
        );
    }

    function setVaultConfig(
        uint256 vaultId,
        uint256 depositCap,
        uint256 managementFeeBps,
        uint256 withdrawalFeeBps,
        bool enabled
    ) external onlyOwner validVault(vaultId) {
        if (managementFeeBps > BFIN_MAX_MANAGEMENT_FEE_BPS) revert BFIN_InvalidFeeBps();
        if (withdrawalFeeBps > BFIN_MAX_WITHDRAWAL_FEE_BPS) revert BFIN_InvalidFeeBps();
        Vault storage v = vaults[vaultId];
        v.depositCap = depositCap;
        v.managementFeeBps = managementFeeBps;
        v.withdrawalFeeBps = withdrawalFeeBps;
        v.enabled = enabled;
        emit VaultConfigUpdated(
            vaultId,
            depositCap,
            managementFeeBps,
            withdrawalFeeBps,
            enabled,
            block.number
        );
    }

    function setVaultStrategyHint(uint256 vaultId, bytes32 strategyHint) external onlyOwner validVault(vaultId) {
        vaults[vaultId].strategyHint = strategyHint;
        emit VaultStrategyHintSet(vaultId, strategyHint, block.number);
    }

    // -------------------------------------------------------------------------
    // INTERNAL FEE ACCRUAL
    // -------------------------------------------------------------------------

    function _accrueVaultFees(uint256 vaultId) internal {
        Vault storage v = vaults[vaultId];
        if (v.managementFeeBps == 0 || v.totalAssets == 0 || v.totalShares == 0) {
            v.lastAccrualBlock = block.number;
            return;
        }
        uint256 elapsed = block.number - v.lastAccrualBlock;
        if (elapsed == 0) return;
        uint256 annualBlocks = 15_768_000;
        uint256 feeAssets = (v.totalAssets * v.managementFeeBps * elapsed) / (BFIN_BPS_BASE * annualBlocks);
        if (feeAssets == 0 || feeAssets > v.totalAssets) {
            v.lastAccrualBlock = block.number;
            return;
        }
        v.totalAssets -= feeAssets;
        protocolFeeAssets += feeAssets;
        v.lastAccrualBlock = block.number;
    }

    function _convertToShares(uint256 vaultId, uint256 assets) internal view returns (uint256) {
        Vault storage v = vaults[vaultId];
        if (v.totalShares == 0 || v.totalAssets == 0) {
            return assets;
        }
        return (assets * v.totalShares) / v.totalAssets;
    }

    function _convertToAssets(uint256 vaultId, uint256 shares) internal view returns (uint256) {
        Vault storage v = vaults[vaultId];
        if (v.totalShares == 0 || v.totalAssets == 0) {
            return shares;
        }
        return (shares * v.totalAssets) / v.totalShares;
    }

    // -------------------------------------------------------------------------
    // USER OPERATIONS — VAULTS
    // -------------------------------------------------------------------------

    function deposit(uint256 vaultId, uint256 assets)
        external
        nonReentrant
        whenNotPaused
        validVault(vaultId)
    {
        if (assets == 0) revert BFIN_ZeroAmount();
        Vault storage v = vaults[vaultId];
        if (!v.enabled) revert BFIN_VaultDisabled();

        _accrueVaultFees(vaultId);

        IERC20BF token = IERC20BF(v.asset);
        uint256 beforeBal = token.balanceOf(address(this));
        bool ok = token.transferFrom(msg.sender, address(this), assets);
        if (!ok) revert BFIN_TransferFailed();
        uint256 afterBal = token.balanceOf(address(this));
        uint256 received = afterBal - beforeBal;
        if (received == 0) revert BFIN_ZeroAmount();

        if (v.depositCap > 0 && v.totalAssets + received > v.depositCap) {
            revert BFIN_DepositCapExceeded();
        }

        uint256 shares = _convertToShares(vaultId, received);
        if (shares == 0) {
            shares = received;
        }

        v.totalAssets += received;
        v.totalShares += shares;
        vaultShares[vaultId][msg.sender] += shares;

        emit VaultDeposit(vaultId, msg.sender, received, shares, block.number);
    }

    function withdraw(uint256 vaultId, uint256 shares)
        external
        nonReentrant
        whenNotPaused
        validVault(vaultId)
    {
        if (shares == 0) revert BFIN_ZeroAmount();
        Vault storage v = vaults[vaultId];
        if (!v.enabled) revert BFIN_VaultDisabled();
        uint256 userShares = vaultShares[vaultId][msg.sender];
        if (userShares < shares) revert BFIN_InsufficientShares();

        _accrueVaultFees(vaultId);

        uint256 grossAssets = _convertToAssets(vaultId, shares);
        if (grossAssets == 0 || grossAssets > v.totalAssets) revert BFIN_ZeroAmount();

        uint256 feeAssets = (grossAssets * v.withdrawalFeeBps) / BFIN_BPS_BASE;
        uint256 protocolCut = (grossAssets * protocolFeeBps) / BFIN_BPS_BASE;
        uint256 payout = grossAssets - feeAssets - protocolCut;

        v.totalAssets -= grossAssets;
        v.totalShares -= shares;
        vaultShares[vaultId][msg.sender] = userShares - shares;
        protocolFeeAssets += feeAssets + protocolCut;

        IERC20BF token = IERC20BF(v.asset);
        bool ok = token.transfer(msg.sender, payout);
        if (!ok) revert BFIN_TransferFailed();

        emit VaultWithdraw(vaultId, msg.sender, shares, payout, feeAssets + protocolCut, block.number);
    }

    // -------------------------------------------------------------------------
    // HARVEST (SIMPLIFIED GAIN INJECTION)
    // -------------------------------------------------------------------------

    function harvest(uint256 vaultId, uint256 gainAssets)
        external
        onlyOwner
        validVault(vaultId)
    {
        if (gainAssets == 0) revert BFIN_ZeroAmount();
        Vault storage v = vaults[vaultId];
        uint256 protocolCut = (gainAssets * protocolFeeBps) / BFIN_BPS_BASE;
        uint256 netGain = gainAssets - protocolCut;
        v.totalAssets += netGain;
        protocolFeeAssets += protocolCut;
        emit VaultHarvested(vaultId, gainAssets, protocolCut, block.number);
    }

    // -------------------------------------------------------------------------
    // CREDIT LINES
    // -------------------------------------------------------------------------

    function openCreditLine(
        address borrower,
        address asset,
        uint256 limit,
        uint256 rateBps
    ) external onlyRiskCouncil returns (uint256 lineId) {
        if (borrower == address(0) || asset == address(0)) revert BFIN_ZeroAddress();
        if (limit == 0) revert BFIN_ZeroAmount();
        if (rateBps == 0 || rateBps > BFIN_MAX_RATE_BPS) revert BFIN_InvalidRate();
        if (lineCounter >= BFIN_MAX_LINES) revert BFIN_MaxCreditLines();

        lineId = ++lineCounter;
        CreditLine storage cl = creditLines[lineId];
        cl.borrower = borrower;
        cl.asset = asset;
        cl.limit = limit;
        cl.rateBps = rateBps;
        cl.borrowed = 0;
        cl.lastAccrualBlock = block.number;
        cl.frozen = false;
        _lineIds.push(lineId);

        emit CreditLineOpened(lineId, borrower, asset, limit, rateBps, block.number);
    }

    function setCreditLine(
        uint256 lineId,
        uint256 limit,
        uint256 rateBps,
        bool frozen
    ) external onlyRiskCouncil validLine(lineId) {
        if (rateBps == 0 || rateBps > BFIN_MAX_RATE_BPS) revert BFIN_InvalidRate();
        CreditLine storage cl = creditLines[lineId];
        cl.limit = limit;
        cl.rateBps = rateBps;
        cl.frozen = frozen;
        emit CreditLineUpdated(lineId, limit, rateBps, frozen, block.number);
    }

    function _accrueLineInterest(uint256 lineId) internal {
        CreditLine storage cl = creditLines[lineId];
        if (cl.borrowed == 0 || cl.rateBps == 0) {
            cl.lastAccrualBlock = block.number;
            return;
        }
        uint256 elapsed = block.number - cl.lastAccrualBlock;
        if (elapsed == 0) return;
        uint256 annualBlocks = 15_768_000;
        uint256 interest = (cl.borrowed * cl.rateBps * elapsed) / (BFIN_BPS_BASE * annualBlocks);
        if (interest == 0) {
            cl.lastAccrualBlock = block.number;
            return;
        }
        cl.borrowed += interest;
        protocolFeeAssets += interest;
        cl.lastAccrualBlock = block.number;
    }

    function draw(uint256 lineId, uint256 assets)
        external
        nonReentrant
        whenNotPaused
        validLine(lineId)
    {
        if (assets == 0) revert BFIN_ZeroAmount();
        CreditLine storage cl = creditLines[lineId];
        if (cl.frozen) revert BFIN_LineFrozen();
        if (msg.sender != cl.borrower) revert BFIN_NotBorrower();

        _accrueLineInterest(lineId);

        if (cl.borrowed + assets > cl.limit) revert BFIN_LimitExceeded();
        cl.borrowed += assets;

        IERC20BF token = IERC20BF(cl.asset);
        bool ok = token.transfer(msg.sender, assets);
        if (!ok) revert BFIN_TransferFailed();

        emit CreditDrawn(lineId, msg.sender, assets, block.number);
    }

    function repay(uint256 lineId, uint256 assets)
        external
        nonReentrant
        whenNotPaused
        validLine(lineId)
    {
        if (assets == 0) revert BFIN_ZeroAmount();
        CreditLine storage cl = creditLines[lineId];

        _accrueLineInterest(lineId);

        uint256 owed = cl.borrowed;
        if (owed == 0) revert BFIN_ZeroAmount();

        IERC20BF token = IERC20BF(cl.asset);
        uint256 beforeBal = token.balanceOf(address(this));
        bool ok = token.transferFrom(msg.sender, address(this), assets);
        if (!ok) revert BFIN_TransferFailed();
        uint256 afterBal = token.balanceOf(address(this));
        uint256 received = afterBal - beforeBal;
        if (received == 0) revert BFIN_ZeroAmount();

        uint256 payPrincipal = received > owed ? owed : received;
        cl.borrowed = owed - payPrincipal;

        emit CreditRepaid(lineId, msg.sender, payPrincipal, 0, block.number);
    }

    // -------------------------------------------------------------------------
    // USER TAGS
    // -------------------------------------------------------------------------

    function setUserTags(bytes32 tagsHash) external {
        userTagsHash[msg.sender] = tagsHash;
        emit UserTagsSet(msg.sender, tagsHash, block.number);
    }

    // -------------------------------------------------------------------------
    // VIEW HELPERS
    // -------------------------------------------------------------------------

    function getVaultView(uint256 vaultId) external view validVault(vaultId) returns (VaultView memory v) {
        Vault storage src = vaults[vaultId];
        v.vaultId = vaultId;
        v.asset = src.asset;
        v.totalAssets = src.totalAssets;
        v.totalShares = src.totalShares;
        v.depositCap = src.depositCap;
        v.managementFeeBps = src.managementFeeBps;
        v.withdrawalFeeBps = src.withdrawalFeeBps;
        v.lastAccrualBlock = src.lastAccrualBlock;
        v.enabled = src.enabled;
        v.nameHash = src.nameHash;
        v.strategyHint = src.strategyHint;
    }

    function getVaultViews(uint256 offset, uint256 limit) external view returns (VaultView[] memory out) {
        uint256 len = _vaultIds.length;
        if (offset >= len) {
            return new VaultView[](0);
        }
        uint256 end = offset + limit;
        if (end > len) end = len;
        uint256 n = end - offset;
        out = new VaultView[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 vid = _vaultIds[offset + i];
            Vault storage src = vaults[vid];
            out[i] = VaultView({
                vaultId: vid,
                asset: src.asset,
                totalAssets: src.totalAssets,
                totalShares: src.totalShares,
                depositCap: src.depositCap,
                managementFeeBps: src.managementFeeBps,
                withdrawalFeeBps: src.withdrawalFeeBps,
                lastAccrualBlock: src.lastAccrualBlock,
                enabled: src.enabled,
                nameHash: src.nameHash,
                strategyHint: src.strategyHint
            });
        }
    }

    function getLineView(uint256 lineId) external view validLine(lineId) returns (CreditLineView memory v) {
        CreditLine storage src = creditLines[lineId];
        v.lineId = lineId;
        v.borrower = src.borrower;
        v.asset = src.asset;
        v.limit = src.limit;
        v.rateBps = src.rateBps;
        v.borrowed = src.borrowed;
        v.lastAccrualBlock = src.lastAccrualBlock;
        v.frozen = src.frozen;
    }

    function getLineViews(uint256 offset, uint256 limit) external view returns (CreditLineView[] memory out) {
        uint256 len = _lineIds.length;
        if (offset >= len) {
            return new CreditLineView[](0);
        }
        uint256 end = offset + limit;
        if (end > len) end = len;
        uint256 n = end - offset;
        out = new CreditLineView[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 lid = _lineIds[offset + i];
            CreditLine storage src = creditLines[lid];
            out[i] = CreditLineView({
                lineId: lid,
                borrower: src.borrower,
                asset: src.asset,
                limit: src.limit,
                rateBps: src.rateBps,
                borrowed: src.borrowed,
                lastAccrualBlock: src.lastAccrualBlock,
                frozen: src.frozen
            });
        }
    }

    function getVaultIds() external view returns (uint256[] memory) {
        return _vaultIds;
    }

    function getLineIds() external view returns (uint256[] memory) {
        return _lineIds;
    }

    function getVaultShareBalance(uint256 vaultId, address user)
        external
        view
        validVault(vaultId)
        returns (uint256)
    {
        return vaultShares[vaultId][user];
    }

    function getVaultAsset(uint256 vaultId) external view validVault(vaultId) returns (address) {
        return vaults[vaultId].asset;
    }

    function getVaultTotals(uint256 vaultId)
        external
        view
        validVault(vaultId)
        returns (uint256 totalAssets_, uint256 totalShares_)
    {
        Vault storage v = vaults[vaultId];
        return (v.totalAssets, v.totalShares);
    }
