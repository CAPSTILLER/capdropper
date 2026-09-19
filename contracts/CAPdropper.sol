// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function name() external view returns (string memory);
}

/**
 * @dev Interface of the ERC721 standard for token ownership verification.
 */
interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address owner);
}

/**
 * @dev Interface for Midas Gate / xCAPunicated Gate registry on Base.
 */
interface IMidasGate {
    struct ERC721Gate {
        address collection;
        uint256 displayTokenId;
        bool active;
    }

    function getAllERC721Gates() external view returns (ERC721Gate[] memory);
    function isUserAuthorized(address user) external view returns (bool);
}

/**
 * @title CAPdropper
 * @notice Multi-tenant, game-ready ERC-20 airdrop vault gated by Midas Gate on Base.
 * @author CAPSTILLER
 */
contract CAPdropper {
    // -------------------------------------------------------------
    // Custom Errors
    // -------------------------------------------------------------
    error ZeroAddress();
    error ZeroAmount();
    error ZeroNFTCount();
    error InvalidDuration();
    error NoActiveCollections();
    error DropNotFound();
    error DropExpired();
    error DropNotExpired();
    error DropAlreadyFinalized();
    error CollectionNotEligible();
    error NotNFTOwner();
    error AlreadyClaimed();
    error InsufficientPendingBalance();
    error TransferFailed();
    error ReentrancyGuard();
    error ArrayLengthMismatch();

    // -------------------------------------------------------------
    // Data Structures
    // -------------------------------------------------------------
    struct Drop {
        address creator;
        address token;
        uint256 totalAmount;        // Net tokens deposited
        uint256 remainingBalance;   // Current unclaimed pool
        uint256 amountPerNFT;       // Payout per eligible token ID
        uint256 totalEligibleNFTs;  // Total eligible NFT supply declared
        uint256 claimedCount;       // Total number of NFTs claimed so far
        uint256 createdAt;          // Unix timestamp
        uint256 expiresAt;          // Unix timestamp
        bool finalized;             // True if expired settlement processed
        address treasury;           // Treasury recipient for 10% fee
        address gateRegistry;       // Gate contract used (or address(0) for custom)
    }

    // -------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------
    address public owner;
    address public immutable defaultGateRegistry;
    address public defaultTreasury;
    uint256 public dropCounter;

    // Drop ID => Drop Metadata
    mapping(uint256 => Drop) public drops;

    // Drop ID => Snapshotted Collections
    mapping(uint256 => address[]) private dropCollections;
    mapping(uint256 => mapping(address => bool)) public isDropCollection;

    // Drop ID => Collection => TokenId => Claimed
    mapping(uint256 => mapping(address => mapping(uint256 => bool))) public isTokenClaimed;

    // Pull-based settlements: User => Token => Pending Claimable Balance
    mapping(address => mapping(address => uint256)) public pendingBalances;

    // Simple Reentrancy Guard
    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // -------------------------------------------------------------
    // Events
    // -------------------------------------------------------------
    event DropCreated(
        uint256 indexed dropId,
        address indexed creator,
        address indexed token,
        uint256 totalAmount,
        uint256 amountPerNFT,
        uint256 totalEligibleNFTs,
        uint256 expiresAt,
        address gateRegistry
    );
    event Claimed(
        uint256 indexed dropId,
        address indexed claimer,
        address indexed collection,
        uint256 tokenId,
        uint256 amount
    );
    event DropFinalized(
        uint256 indexed dropId,
        uint256 creatorRefund,
        uint256 treasuryFee
    );
    event PendingWithdrawn(
        address indexed user,
        address indexed token,
        uint256 amount
    );
    event DefaultTreasuryUpdated(address indexed newTreasury);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    // -------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------
    modifier nonReentrant() {
        if (_status == _ENTERED) revert ReentrancyGuard();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert ZeroAddress();
        _;
    }

    // -------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------
    constructor(
        address _owner,
        address _defaultGateRegistry,
        address _defaultTreasury
    ) {
        if (_owner == address(0)) revert ZeroAddress();
        if (_defaultGateRegistry == address(0)) revert ZeroAddress();
        if (_defaultTreasury == address(0)) revert ZeroAddress();

        owner = _owner;
        defaultGateRegistry = _defaultGateRegistry;
        defaultTreasury = _defaultTreasury;
        _status = _NOT_ENTERED;
    }

    // -------------------------------------------------------------
    // Drop Creation Methods
    // -------------------------------------------------------------

    /**
     * @notice Funds a drop by automatically snapshotting the active ERC721 collections in Midas Gate.
     * @param token Address of the ERC20 token to airdrop (e.g. CAP, BNKR, USDC).
     * @param totalAmount Total amount of tokens to distribute.
     * @param totalEligibleNFTs Total count of eligible NFTs across active gate collections.
     * @param durationSeconds Lifespan of the drop before expiration.
     * @param treasury Destination for the 10% fee if expired (or address(0) to use defaultTreasury).
     */
    function fundDropWithMidasGate(
        address token,
        uint256 totalAmount,
        uint256 totalEligibleNFTs,
        uint256 durationSeconds,
        address treasury
    ) external nonReentrant returns (uint256 dropId) {
        return _fundDropWithGate(token, totalAmount, defaultGateRegistry, totalEligibleNFTs, durationSeconds, treasury);
    }

    /**
     * @notice Funds a drop with a custom Gate Registry implementing getAllERC721Gates().
     */
    function fundDropWithGate(
        address token,
        uint256 totalAmount,
        address gateRegistry,
        uint256 totalEligibleNFTs,
        uint256 durationSeconds,
        address treasury
    ) external nonReentrant returns (uint256 dropId) {
        if (gateRegistry == address(0)) revert ZeroAddress();
        return _fundDropWithGate(token, totalAmount, gateRegistry, totalEligibleNFTs, durationSeconds, treasury);
    }

    /**
     * @notice Funds a drop with an explicit list of eligible ERC721 collection contracts.
     */
    function fundDropCustom(
        address token,
        uint256 totalAmount,
        address[] calldata collections,
        uint256 totalEligibleNFTs,
        uint256 durationSeconds,
        address treasury
    ) external nonReentrant returns (uint256 dropId) {
        if (collections.length == 0) revert NoActiveCollections();
        return _createDropRecord(token, totalAmount, collections, address(0), totalEligibleNFTs, durationSeconds, treasury);
    }

    // -------------------------------------------------------------
    // Internal Drop Creation Engine
    // -------------------------------------------------------------
    function _fundDropWithGate(
        address token,
        uint256 totalAmount,
        address gateRegistry,
        uint256 totalEligibleNFTs,
        uint256 durationSeconds,
        address treasury
    ) internal returns (uint256) {
        IMidasGate.ERC721Gate[] memory gates = IMidasGate(gateRegistry).getAllERC721Gates();
        
        // Count active collections
        uint256 activeCount = 0;
        for (uint256 i = 0; i < gates.length; i++) {
            if (gates[i].active && gates[i].collection != address(0)) {
                activeCount++;
            }
        }
        if (activeCount == 0) revert NoActiveCollections();

        address[] memory activeCollections = new address[](activeCount);
        uint256 idx = 0;
        for (uint256 i = 0; i < gates.length; i++) {
            if (gates[i].active && gates[i].collection != address(0)) {
                activeCollections[idx] = gates[i].collection;
                idx++;
            }
        }

        return _createDropRecord(token, totalAmount, activeCollections, gateRegistry, totalEligibleNFTs, durationSeconds, treasury);
    }

    function _createDropRecord(
        address token,
        uint256 totalAmount,
        address[] memory collections,
        address gateRegistry,
        uint256 totalEligibleNFTs,
        uint256 durationSeconds,
        address treasury
    ) internal returns (uint256) {
        if (token == address(0)) revert ZeroAddress();
        if (totalAmount == 0) revert ZeroAmount();
        if (totalEligibleNFTs == 0) revert ZeroNFTCount();
        if (durationSeconds < 60) revert InvalidDuration();

        address resolvedTreasury = treasury == address(0) ? defaultTreasury : treasury;

        // Measure net received tokens to guard against fee-on-transfer / rebasing tokens
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        _safeTransferFrom(token, msg.sender, address(this), totalAmount);
        uint256 netReceived = IERC20(token).balanceOf(address(this)) - balBefore;
        if (netReceived == 0) revert ZeroAmount();

        uint256 perNFT = netReceived / totalEligibleNFTs;
        if (perNFT == 0) revert ZeroAmount();

        unchecked {
            dropCounter++;
        }
        uint256 dropId = dropCounter;

        drops[dropId] = Drop({
            creator: msg.sender,
            token: token,
            totalAmount: netReceived,
            remainingBalance: netReceived,
            amountPerNFT: perNFT,
            totalEligibleNFTs: totalEligibleNFTs,
            claimedCount: 0,
            createdAt: block.timestamp,
            expiresAt: block.timestamp + durationSeconds,
            finalized: false,
            treasury: resolvedTreasury,
            gateRegistry: gateRegistry
        });

        // Snapshot collections
        uint256 cLen = collections.length;
        for (uint256 i = 0; i < cLen; ) {
            address col = collections[i];
            dropCollections[dropId].push(col);
            isDropCollection[dropId][col] = true;
            unchecked { ++i; }
        }

        emit DropCreated(
            dropId,
            msg.sender,
            token,
            netReceived,
            perNFT,
            totalEligibleNFTs,
            block.timestamp + durationSeconds,
            gateRegistry
        );

        return dropId;
    }

    // -------------------------------------------------------------
    // Claiming Methods
    // -------------------------------------------------------------

    /**
     * @notice Claims airdrop for a specific token ID in an eligible collection.
     */
    function claim(
        uint256 dropId,
        address collection,
        uint256 tokenId
    ) external nonReentrant {
        _claim(dropId, collection, tokenId, msg.sender);
    }

    /**
     * @notice Batch claims rewards across multiple token IDs and collections.
     */
    function batchClaim(
        uint256 dropId,
        address[] calldata collections,
        uint256[] calldata tokenIds
    ) external nonReentrant {
        if (collections.length != tokenIds.length) revert ArrayLengthMismatch();
        uint256 len = collections.length;
        for (uint256 i = 0; i < len; ) {
            _claim(dropId, collections[i], tokenIds[i], msg.sender);
            unchecked { ++i; }
        }
    }

    function _claim(
        uint256 dropId,
        address collection,
        uint256 tokenId,
        address claimer
    ) internal {
        if (dropId == 0 || dropId > dropCounter) revert DropNotFound();

        Drop storage drop = drops[dropId];
        if (block.timestamp > drop.expiresAt) revert DropExpired();
        if (drop.finalized) revert DropAlreadyFinalized();
        if (!isDropCollection[dropId][collection]) revert CollectionNotEligible();

        // Verify NFT ownership
        if (IERC721(collection).ownerOf(tokenId) != claimer) revert NotNFTOwner();

        // Verify not claimed
        if (isTokenClaimed[dropId][collection][tokenId]) revert AlreadyClaimed();

        // Effects
        isTokenClaimed[dropId][collection][tokenId] = true;
        drop.claimedCount++;
        uint256 payout = drop.amountPerNFT;
        drop.remainingBalance -= payout;

        // Interaction
        _safeTransfer(drop.token, claimer, payout);

        emit Claimed(dropId, claimer, collection, tokenId, payout);
    }

    // -------------------------------------------------------------
    // Expiration & Settlement Methods (Pull-Over-Push)
    // -------------------------------------------------------------

    /**
     * @notice Finalizes an expired drop. Splits remaining tokens 90% to creator and 10% to treasury.
     */
    function finalizeDrop(uint256 dropId) external nonReentrant {
        if (dropId == 0 || dropId > dropCounter) revert DropNotFound();

        Drop storage drop = drops[dropId];
        if (drop.finalized) revert DropAlreadyFinalized();
        if (block.timestamp <= drop.expiresAt) revert DropNotExpired();

        drop.finalized = true;
        uint256 remaining = drop.remainingBalance;

        if (remaining > 0) {
            uint256 treasuryFee = (remaining * 10) / 100;
            uint256 creatorRefund = remaining - treasuryFee;

            drop.remainingBalance = 0;
            pendingBalances[drop.treasury][drop.token] += treasuryFee;
            pendingBalances[drop.creator][drop.token] += creatorRefund;

            emit DropFinalized(dropId, creatorRefund, treasuryFee);
        }
    }

    /**
     * @notice Withdraws accumulated claimable balances (creator refunds or treasury fees).
     */
    function withdrawPending(address token) external nonReentrant {
        uint256 amount = pendingBalances[msg.sender][token];
        if (amount == 0) revert InsufficientPendingBalance();

        pendingBalances[msg.sender][token] = 0;
        _safeTransfer(token, msg.sender, amount);

        emit PendingWithdrawn(msg.sender, token, amount);
    }

    // -------------------------------------------------------------
    // View Functions
    // -------------------------------------------------------------

    function getDropCollections(uint256 dropId) external view returns (address[] memory) {
        return dropCollections[dropId];
    }

    function getDropDetails(uint256 dropId) external view returns (
        address creator,
        address token,
        uint256 totalAmount,
        uint256 remainingBalance,
        uint256 amountPerNFT,
        uint256 totalEligibleNFTs,
        uint256 claimedCount,
        uint256 createdAt,
        uint256 expiresAt,
        bool finalized,
        address treasury,
        address gateRegistry
    ) {
        Drop storage d = drops[dropId];
        return (
            d.creator,
            d.token,
            d.totalAmount,
            d.remainingBalance,
            d.amountPerNFT,
            d.totalEligibleNFTs,
            d.claimedCount,
            d.createdAt,
            d.expiresAt,
            d.finalized,
            d.treasury,
            d.gateRegistry
        );
    }

    // -------------------------------------------------------------
    // Admin Functions
    // -------------------------------------------------------------

    function setDefaultTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        defaultTreasury = newTreasury;
        emit DefaultTreasuryUpdated(newTreasury);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address old = owner;
        owner = newOwner;
        emit OwnershipTransferred(old, newOwner);
    }

    // -------------------------------------------------------------
    // Safe Transfer Helpers
    // -------------------------------------------------------------
    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert TransferFailed();
        }
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount)
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert TransferFailed();
        }
    }
}
