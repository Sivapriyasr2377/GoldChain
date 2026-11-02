// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title GoldChain
 * @dev Blockchain-based gold jewellery authentication and ownership tracking system.
 *      Authorized jewellers register items; owners transfer them; lifecycle events are recorded.
 */
contract GoldChain {

    // ─── Enums ────────────────────────────────────────────────────────────────

    enum PledgeStatus { None, Pledged, Released }

    // ─── Structs ──────────────────────────────────────────────────────────────

    struct JewelleryItem {
        string  itemId;           // Unique jewellery ID (e.g., hallmark serial)
        string  name;             // Human-readable name (e.g., "22K Gold Necklace")
        uint256 weightMg;         // Weight in milligrams (avoids decimals)
        string  purity;           // e.g., "22K", "18K", "916"
        string  hallmarkDetails;  // Hallmark authority + certificate number
        string  docHash;          // SHA-256 hash of off-chain certificate/invoice
        address currentOwner;     // Current owner's wallet address
        address registeredBy;     // Jeweller who originally registered the item
        uint256 registeredAt;     // Unix timestamp of registration
        bool    exists;           // Existence guard for duplicate check
        PledgeStatus pledgeStatus;
    }

    struct OwnershipRecord {
        address from;
        address to;
        uint256 timestamp;
        string  note;
    }

    struct LifecycleEvent {
        string  eventType;   // "repair", "alteration", "pledge", "release", etc.
        string  description;
        address recordedBy;
        uint256 timestamp;
    }

    // ─── State ────────────────────────────────────────────────────────────────

    struct PendingTransfer {
        address to;
        string  note;
        uint256 proposedAt;
        bool    active;
    }

    address public admin;

    mapping(address => bool)   public authorizedJewellers;
    mapping(string  => JewelleryItem) private items;          // itemId → item
    mapping(string  => OwnershipRecord[]) private ownershipHistory;
    mapping(string  => LifecycleEvent[])  private lifecycleHistory;

    string[] private allItemIds;   // for enumeration

    mapping(string => PendingTransfer) private pendingTransfers;  // itemId → proposed transfer
    address[] private jewellerList;                               // every address ever authorized
    mapping(address => bool) private isListed;

    // ─── Events ───────────────────────────────────────────────────────────────

    event JewellerAuthorized(address indexed jeweller);
    event JewellerRevoked(address indexed jeweller);
    event ItemRegistered(string indexed itemId, address indexed owner, address indexed jeweller);
    event OwnershipTransferred(string indexed itemId, address indexed from, address indexed to);
    event ItemPledged(string indexed itemId, address indexed owner);
    event PledgeReleased(string indexed itemId, address indexed owner);
    event LifecycleEventRecorded(string indexed itemId, string eventType);
    event TransferProposed(string indexed itemId, address indexed from, address indexed to);
    event TransferCancelled(string indexed itemId, address indexed owner);

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    modifier onlyAuthorizedJeweller() {
        require(authorizedJewellers[msg.sender], "Not an authorized jeweller");
        _;
    }

    modifier itemExists(string memory itemId) {
        require(items[itemId].exists, "Item not registered");
        _;
    }

    modifier onlyOwner(string memory itemId) {
        require(items[itemId].currentOwner == msg.sender, "Not the item owner");
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor() {
        admin = msg.sender;
        // Admin is also an authorized jeweller by default
        authorizedJewellers[msg.sender] = true;
        jewellerList.push(msg.sender);
        isListed[msg.sender] = true;
        emit JewellerAuthorized(msg.sender);
    }

    // ─── Admin functions ──────────────────────────────────────────────────────

    function authorizeJeweller(address jeweller) external onlyAdmin {
        require(jeweller != address(0), "Invalid address");
        require(!authorizedJewellers[jeweller], "Already authorized");
        authorizedJewellers[jeweller] = true;
        if (!isListed[jeweller]) {
            isListed[jeweller] = true;
            jewellerList.push(jeweller);
        }
        emit JewellerAuthorized(jeweller);
    }

    function revokeJeweller(address jeweller) external onlyAdmin {
        require(jeweller != admin, "Cannot revoke the admin");
        require(authorizedJewellers[jeweller], "Not an authorized jeweller");
        authorizedJewellers[jeweller] = false;
        emit JewellerRevoked(jeweller);
    }

    // ─── Registration ─────────────────────────────────────────────────────────

    /**
     * @dev Register a new jewellery item on-chain.
     * @param itemId       Unique identifier (e.g., hallmark serial number)
     * @param name         Human-friendly label
     * @param weightMg     Weight in milligrams
     * @param purity       Gold purity ("22K", "916", etc.)
     * @param hallmark     Hallmark authority and certificate details
     * @param docHash      SHA-256 hex hash of the supporting certificate/invoice
     * @param initialOwner Wallet address of the first owner
     */
    function registerItem(
        string  memory itemId,
        string  memory name,
        uint256        weightMg,
        string  memory purity,
        string  memory hallmark,
        string  memory docHash,
        address        initialOwner
    ) external onlyAuthorizedJeweller {
        require(!items[itemId].exists, "Item already registered");
        require(initialOwner != address(0), "Invalid owner address");
        require(bytes(itemId).length > 0, "Item ID required");
        require(weightMg > 0, "Weight must be positive");

        items[itemId] = JewelleryItem({
            itemId:        itemId,
            name:          name,
            weightMg:      weightMg,
            purity:        purity,
            hallmarkDetails: hallmark,
            docHash:       docHash,
            currentOwner:  initialOwner,
            registeredBy:  msg.sender,
            registeredAt:  block.timestamp,
            exists:        true,
            pledgeStatus:  PledgeStatus.None
        });

        allItemIds.push(itemId);

        // Seed ownership history with registration event
        ownershipHistory[itemId].push(OwnershipRecord({
            from:      address(0),
            to:        initialOwner,
            timestamp: block.timestamp,
            note:      "Initial registration"
        }));

        emit ItemRegistered(itemId, initialOwner, msg.sender);
    }

    // ─── Ownership transfer ───────────────────────────────────────────────────

    /**
     * @dev Step 1: the current owner proposes a transfer. Ownership does not
     *      change until the recipient accepts. Proposing again replaces any
     *      earlier proposal for the same item.
     */
    function proposeTransfer(
        string  memory itemId,
        address        newOwner,
        string  memory note
    ) external itemExists(itemId) onlyOwner(itemId) {
        require(newOwner != address(0), "Invalid new owner");
        require(newOwner != msg.sender, "Cannot transfer to yourself");
        require(
            items[itemId].pledgeStatus != PledgeStatus.Pledged,
            "Cannot transfer a pledged item"
        );

        pendingTransfers[itemId] = PendingTransfer({
            to:         newOwner,
            note:       note,
            proposedAt: block.timestamp,
            active:     true
        });

        emit TransferProposed(itemId, msg.sender, newOwner);
    }

    /**
     * @dev Step 2: the proposed recipient accepts and becomes the owner.
     */
    function acceptTransfer(string memory itemId) external itemExists(itemId) {
        PendingTransfer memory p = pendingTransfers[itemId];
        require(p.active, "No pending transfer");
        require(p.to == msg.sender, "Not the intended recipient");
        require(
            items[itemId].pledgeStatus != PledgeStatus.Pledged,
            "Cannot accept a pledged item"
        );

        address previousOwner = items[itemId].currentOwner;
        items[itemId].currentOwner = msg.sender;
        delete pendingTransfers[itemId];

        ownershipHistory[itemId].push(OwnershipRecord({
            from:      previousOwner,
            to:        msg.sender,
            timestamp: block.timestamp,
            note:      p.note
        }));

        emit OwnershipTransferred(itemId, previousOwner, msg.sender);
    }

    /**
     * @dev The current owner withdraws a pending transfer proposal.
     */
    function cancelTransfer(string memory itemId) external itemExists(itemId) onlyOwner(itemId) {
        require(pendingTransfers[itemId].active, "No pending transfer");
        delete pendingTransfers[itemId];
        emit TransferCancelled(itemId, msg.sender);
    }

    // ─── Pledge management ────────────────────────────────────────────────────

    function pledgeItem(string memory itemId) external itemExists(itemId) onlyOwner(itemId) {
        require(items[itemId].pledgeStatus != PledgeStatus.Pledged, "Item already pledged");
        items[itemId].pledgeStatus = PledgeStatus.Pledged;

        lifecycleHistory[itemId].push(LifecycleEvent({
            eventType:   "pledge",
            description: "Item pledged as collateral",
            recordedBy:  msg.sender,
            timestamp:   block.timestamp
        }));

        emit ItemPledged(itemId, msg.sender);
    }

    function releasePledge(string memory itemId) external itemExists(itemId) onlyOwner(itemId) {
        require(items[itemId].pledgeStatus == PledgeStatus.Pledged, "Item is not pledged");
        items[itemId].pledgeStatus = PledgeStatus.Released;

        lifecycleHistory[itemId].push(LifecycleEvent({
            eventType:   "pledge_release",
            description: "Pledge released",
            recordedBy:  msg.sender,
            timestamp:   block.timestamp
        }));

        emit PledgeReleased(itemId, msg.sender);
    }

    // ─── Lifecycle events ─────────────────────────────────────────────────────

    /**
     * @dev Record a lifecycle event (repair, alteration, inspection, etc.)
     *      Can be called by the current owner or an authorized jeweller.
     */
    function recordLifecycleEvent(
        string memory itemId,
        string memory eventType,
        string memory description
    ) external itemExists(itemId) {
        require(
            msg.sender == items[itemId].currentOwner || authorizedJewellers[msg.sender],
            "Not authorized to record events"
        );

        lifecycleHistory[itemId].push(LifecycleEvent({
            eventType:   eventType,
            description: description,
            recordedBy:  msg.sender,
            timestamp:   block.timestamp
        }));

        emit LifecycleEventRecorded(itemId, eventType);
    }

    // ─── View functions ───────────────────────────────────────────────────────

    function getItem(string memory itemId)
        external view itemExists(itemId)
        returns (
            string  memory name,
            uint256        weightMg,
            string  memory purity,
            string  memory hallmarkDetails,
            string  memory docHash,
            address        currentOwner,
            address        registeredBy,
            uint256        registeredAt,
            uint8          pledgeStatus
        )
    {
        JewelleryItem storage item = items[itemId];
        return (
            item.name,
            item.weightMg,
            item.purity,
            item.hallmarkDetails,
            item.docHash,
            item.currentOwner,
            item.registeredBy,
            item.registeredAt,
            uint8(item.pledgeStatus)
        );
    }

    function getOwnershipHistory(string memory itemId)
        external view itemExists(itemId)
        returns (OwnershipRecord[] memory)
    {
        return ownershipHistory[itemId];
    }

    function getLifecycleHistory(string memory itemId)
        external view itemExists(itemId)
        returns (LifecycleEvent[] memory)
    {
        return lifecycleHistory[itemId];
    }

    function getAllItemIds() external view returns (string[] memory) {
        return allItemIds;
    }

    function isItemRegistered(string memory itemId) external view returns (bool) {
        return items[itemId].exists;
    }

    function getPendingTransfer(string memory itemId)
        external view itemExists(itemId)
        returns (bool active, address to, string memory note, uint256 proposedAt)
    {
        PendingTransfer storage p = pendingTransfers[itemId];
        return (p.active, p.to, p.note, p.proposedAt);
    }

    /// @dev Returns only the jewellers that are currently authorized.
    function getJewellers() external view returns (address[] memory) {
        uint256 count;
        for (uint256 i = 0; i < jewellerList.length; i++) {
            if (authorizedJewellers[jewellerList[i]]) count++;
        }
        address[] memory active = new address[](count);
        uint256 j;
        for (uint256 i = 0; i < jewellerList.length; i++) {
            if (authorizedJewellers[jewellerList[i]]) active[j++] = jewellerList[i];
        }
        return active;
    }
}
