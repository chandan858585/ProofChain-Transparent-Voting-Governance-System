// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Weighted-DAO (snapshot per-proposal, quorum, proposal cancellation, admin controls)
/// @notice Improved version of the user's Project contract:
///         - snapshots per-proposal voter weights at creation (so weights cannot be changed mid-vote)
///         - pause/unpause for emergencies
///         - small safety & API improvements
contract Project {
    struct Proposal {
        uint256 id;
        string title;
        string description;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 deadline;
        bool executed;
        bool canceled;
        address proposer;
        uint256 totalVotingPowerSnapshot; // sum of snapshotWeights for that proposal
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    // Current live voting power and voter list
    mapping(address => uint256) public votingPower;
    mapping(address => bool) public isVoter;
    address[] private votersList;
    mapping(address => uint256) private voterIndex; // 1-based index into votersList (0 = not present)

    // Per-proposal snapshot of each voter's weight (set at proposal creation)
    // WARNING: snapshotting iterates current votersList and writes to storage per voter.
    // For very large voter lists this will be gas-expensive. Consider batched snapshotting
    // or optimistic quorum checks if you expect thousands of voters.
    mapping(uint256 => mapping(address => uint256)) public proposalVotingPowerSnapshot;
    mapping(uint256 => address[]) private proposalVoters; // stored list of voters snapshot for that proposal (for view)

    uint256 public proposalCount;
    uint256 public totalVotingPower;
    address public admin;
    uint8 public quorumPercent;

    // Pause flag
    bool public paused;

    // Reentrancy guard (OpenZeppelin-style)
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    // Events
    event ProposalCreated(uint256 indexed id, string title, address indexed proposer, uint256 snapshot, uint8 quorum);
    event VoteCast(uint256 indexed id, address indexed voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed id, bool success);
    event ProposalCancelled(uint256 indexed id, address by);
    event VoterUpdated(address indexed voter, uint256 weight, bool removed);
    event BatchVotersUpdated(address indexed by, uint256 count);
    event ProposalExtended(uint256 indexed id, uint256 newDeadline);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event QuorumChanged(uint8 oldQuorum, uint8 newQuorum);
    event Paused(address by);
    event Unpaused(address by);
    event RecoveredERC20(address token, uint256 amount, address to);
    event RecoveredETH(uint256 amount, address to);

    modifier onlyAdmin() { require(msg.sender == admin, "Not admin"); _; }
    modifier onlyVoter() { require(isVoter[msg.sender], "Not voter"); _; }
    modifier nonReentrant() {
        require(_status != _ENTERED, "Reentrant");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
    modifier proposalExists(uint256 id) {
        require(id > 0 && id <= proposalCount, "Proposal not found");
        _; 
    }
    modifier notPaused() {
        require(!paused, "Paused");
        _; 
    }

    /// @param _quorumPercent quorum percent (1..100)
    constructor(uint8 _quorumPercent) {
        require(_quorumPercent > 0 && _quorumPercent <= 100, "Invalid quorum");
        admin = msg.sender;

        // bootstrap admin as a voter with weight 1
        isVoter[msg.sender] = true;
        votingPower[msg.sender] = 1;
        totalVotingPower = 1;

        // initialize voters list
        votersList.push(msg.sender);
        voterIndex[msg.sender] = 1; // 1-based

        quorumPercent = _quorumPercent;
        _status = _NOT_ENTERED;
        proposalCount = 0;
        paused = false;
    }

    // --- Core ---

    /// @notice Create a proposal. Snapshot of per-voter voting power (and total) is taken at creation.
    /// @dev Snapshotting writes one storage slot per voter. For large voter lists this is gas-costly.
    ///      If you expect very large voter lists, consider implementing a batched snapshot or
    ///      snapshot only total voting power (but that allows weight changes to affect votes).
    /// @param _title short title (non-empty)
    /// @param _desc longer description
    /// @param _days duration in days (>0)
    function createProposal(string calldata _title, string calldata _desc, uint256 _days) external onlyVoter notPaused {
        require(bytes(_title).length > 0, "Title required");
        require(_days > 0, "Days must be > 0");
        require(totalVotingPower > 0, "No voting power in system");

        proposalCount++;
        uint256 snapshotTotal = 0;

        // Snapshot every current voter weight
        // Note: this loops through `votersList`. Be mindful of gas cost for big lists.
        for (uint256 i = 0; i < votersList.length; i++) {
            address v = votersList[i];
            uint256 w = votingPower[v];
            if (w == 0) continue; // skip zero weights
            proposalVotingPowerSnapshot[proposalCount][v] = w;
            proposalVoters[proposalCount].push(v);
            snapshotTotal += w;
        }

        // Defensive: snapshotTotal should be equal to totalVotingPower if no zero-weights exist.
        // However if some voters have weight 0 but are still in list, snapshotTotal may be < totalVotingPower.
        // We still allow creation but record exactly what's snapshotted.
        proposals[proposalCount] = Proposal({
            id: proposalCount,
            title: _title,
            description: _desc,
            forVotes: 0,
            againstVotes: 0,
            deadline: block.timestamp + (_days * 1 days),
            executed: false,
            canceled: false,
            proposer: msg.sender,
            totalVotingPowerSnapshot: snapshotTotal
        });

        emit ProposalCreated(proposalCount, _title, msg.sender, snapshotTotal, quorumPercent);
    }

    /// @notice Cast your weighted vote on a proposal (one address, one vote per proposal).
    /// @dev Uses the voter's weight as recorded in the proposal snapshot — weight changes after snapshot do not affect this vote.
    /// @param id proposal id
    /// @param support true = for, false = against
    function vote(uint256 id, bool support) external onlyVoter proposalExists(id) notPaused {
        Proposal storage p = proposals[id];
        require(!p.canceled, "Canceled");
        require(block.timestamp < p.deadline, "Voting closed");
        require(!hasVoted[id][msg.sender], "Already voted");

        uint256 w = proposalVotingPowerSnapshot[id][msg.sender];
        require(w > 0, "No voting weight in snapshot");

        hasVoted[id][msg.sender] = true;
        if (support) {
            p.forVotes += w;
        } else {
            p.againstVotes += w;
        }

        emit VoteCast(id, msg.sender, support, w);
    }

    /// @notice Finalize (execute) a proposal if quorum met and voting finished. Execution here is logical (emits result).
    /// @param id proposal id
    function executeProposal(uint256 id) external onlyVoter nonReentrant proposalExists(id) notPaused {
        Proposal storage p = proposals[id];
        require(!p.executed, "Already executed");
        require(!p.canceled, "Canceled");
        require(block.timestamp > p.deadline, "Voting still active");

        uint256 cast = p.forVotes + p.againstVotes;
        uint256 quorumNeeded = quorumFor(id);
        require(quorumNeeded > 0, "Quorum undefined");
        require(cast >= quorumNeeded, "No quorum");

        p.executed = true;
        bool success = p.forVotes > p.againstVotes;

        emit ProposalExecuted(id, success);
    }

    /// @notice Cancel a proposal (by proposer or admin) before execution.
    /// @param id proposal id
    function cancelProposal(uint256 id) external proposalExists(id) {
        Proposal storage p = proposals[id];
        require(!p.executed, "Already executed");
        require(!p.canceled, "Already canceled");
        require(msg.sender == p.proposer || msg.sender == admin, "Not authorized");
        p.canceled = true;
        emit ProposalCancelled(id, msg.sender);
    }

    // --- Voters management ---

    /// @notice Add/update/remove voter weight. Admin only.
    /// @param voter address to set
    /// @param weight new weight (0 to remove)
    function setVoter(address voter, uint256 weight) public onlyAdmin {
        require(voter != address(0), "Zero address");

        uint256 old = votingPower[voter];

        // No-op if weight unchanged
        if (old == weight) {
            emit VoterUpdated(voter, weight, weight == 0);
            return;
        }

        if (weight == 0) {
            // remove voter
            require(isVoter[voter], "Not a voter");
            require(totalVotingPower >= old, "Invariant"); // safe-guard
            totalVotingPower -= old;
            votingPower[voter] = 0;
            isVoter[voter] = false;
            _removeVoterFromList(voter);
            emit VoterUpdated(voter, 0, true);
        } else {
            if (isVoter[voter]) {
                // adjust existing
                if (weight > old) {
                    totalVotingPower += (weight - old);
                } else {
                    totalVotingPower -= (old - weight);
                }
                votingPower[voter] = weight;
            } else {
                // new voter
                isVoter[voter] = true;
                votingPower[voter] = weight;
                totalVotingPower += weight;
                _addVoterToList(voter);
            }
            emit VoterUpdated(voter, weight, false);
        }
    }

    /// @notice Batch add/update/remove multiple voters in one call. Admin only.
    /// @dev Arrays must match lengths.
    /// @param voters list of addresses
    /// @param weights corresponding weights (0 removes)
    function batchSetVoters(address[] calldata voters, uint256[] calldata weights) external onlyAdmin {
        require(voters.length == weights.length, "Length mismatch");
        for (uint256 i = 0; i < voters.length; i++) {
            setVoter(voters[i], weights[i]);
        }
        emit BatchVotersUpdated(msg.sender, voters.length);
    }

    // --- Utilities ---

    /// @notice Extend a proposal's deadline (only proposer, before deadline).
    /// @param id proposal id
    /// @param extraDays additional days to add (>0)
    function extendProposal(uint256 id, uint256 extraDays) external proposalExists(id) {
        require(extraDays > 0, "Extra days > 0");
        Proposal storage p = proposals[id];
        require(msg.sender == p.proposer, "Only proposer");
        require(block.timestamp < p.deadline, "Already closed");
        require(!p.canceled, "Canceled");

        p.deadline += extraDays * 1 days;
        emit ProposalExtended(id, p.deadline);
    }

    /// @notice Change quorum percent (admin).
    /// @param q new quorum percent (1..100)
    function setQuorum(uint8 q) external onlyAdmin {
        require(q > 0 && q <= 100, "Invalid quorum");
        uint8 old = quorumPercent;
        quorumPercent = q;
        emit QuorumChanged(old, q);
    }

    /// @notice Transfer admin rights.
    /// @param n new admin address
    function transferAdmin(address n) external onlyAdmin {
        require(n != address(0), "Zero address");
        emit AdminTransferred(admin, n);
        admin = n;
    }

    /// @notice Pause core functions (create, vote, execute) in an emergency. Admin only.
    function pause() external onlyAdmin {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpause contract. Admin only.
    function unpause() external onlyAdmin {
        paused = false;
        emit Unpaused(msg.sender);
    }

    // --- Rescue funds (admin only) ---

    /// @notice Recover ERC20 tokens accidentally sent to this contract.
    /// @param token ERC20 token address
    /// @param to destination address
    /// @param amount amount to recover
    function recoverERC20(address token, address to, uint256 amount) external onlyAdmin {
        require(to != address(0), "Zero address");
        require(token != address(0), "Zero token");
        // minimal ERC20 transfer interface
        (bool success, bytes memory data) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "ERC20 transfer failed");
        emit RecoveredERC20(token, amount, to);
    }

    /// @notice Recover ETH accidentally sent to this contract.
    /// @param to destination address
    /// @param amount amount to send
    function recoverETH(address to, uint256 amount) external onlyAdmin {
        require(to != address(0), "Zero address");
        (bool success, ) = to.call{value: amount}("");
        require(success, "ETH transfer failed");
        emit RecoveredETH(amount, to);
    }

    // --- Views / helpers ---

    /// @notice Returns the voting power required for quorum for a proposal (uses snapshot).
    /// @dev Ceil(snapshot * quorumPercent / 100)
    function quorumFor(uint256 id) public view proposalExists(id) returns (uint256) {
        Proposal storage p = proposals[id];
        if (p.totalVotingPowerSnapshot == 0) return 0;
        // ceil(snapshot * quorumPercent / 100)
        return (p.totalVotingPowerSnapshot * quorumPercent + 100 - 1) / 100;
    }

    /// @notice Short helper to inspect proposal outcome & stats after voting closed.
    /// @param id proposal id
    /// @return passed true if forVotes > againstVotes (only meaningful once executed or after voting)
    /// @return forVotes count
    /// @return againstVotes count
    /// @return cast total cast votes
    /// @return quorumNeeded quorum threshold based on snapshot
    /// @return snapshot snapshot of total voting power at creation
    function proposalResult(uint256 id) external view proposalExists(id) returns (
        bool passed,
        uint256 forVotes,
        uint256 againstVotes,
        uint256 cast,
        uint256 quorumNeeded,
        uint256 snapshot
    ) {
        Proposal storage p = proposals[id];
        forVotes = p.forVotes;
        againstVotes = p.againstVotes;
        cast = forVotes + againstVotes;
        quorumNeeded = quorumFor(id);
        snapshot = p.totalVotingPowerSnapshot;
        passed = forVotes > againstVotes;
    }

    function votingPowerOf(address who) external view returns (uint256) {
        return votingPower[who];
    }

    function hasProposal(uint256 id) external view returns (bool) {
        return (id > 0 && id <= proposalCount);
    }

    /// @notice Get a proposal
    function getProposal(uint256 id) external view proposalExists(id) returns (Proposal memory) {
        return proposals[id];
    }

    /// @notice Get all proposals (1..proposalCount).
    function getAllProposals() external view returns (Proposal[] memory arr) {
        arr = new Proposal[](proposalCount);
        for (uint256 i = 1; i <= proposalCount; i++) {
            arr[i - 1] = proposals[i];
        }
    }

    /// @notice Get current voters list (addresses)
    function getVoters() external view returns (address[] memory) {
        return votersList;
    }

    /// @notice Get the list of voters that were snapshotted for a given proposal
    function getProposalVoters(uint256 id) external view proposalExists(id) returns (address[] memory) {
        return proposalVoters[id];
    }

    /// @notice Get the snapshot weight of a voter for a specific proposal
    function getSnapshotWeight(uint256 id, address who) external view proposalExists(id) returns (uint256) {
        return proposalVotingPowerSnapshot[id][who];
    }

    /// @notice Get total number of proposals created so far.
    function getProposalCount() external view returns (uint256) {
        return proposalCount;
    }

    // --- Internal helpers for voter list management (O(1) removal via swap-pop) ---

    function _addVoterToList(address who) internal {
        // assume not present
        votersList.push(who);
        voterIndex[who] = votersList.length; // 1-based
    }

    function _removeVoterFromList(address who) internal {
        uint256 idx = voterIndex[who];
        require(idx != 0, "Not in list");
        uint256 lastIndex = votersList.length;
        if (idx != lastIndex) {
            address last = votersList[lastIndex - 1];
            votersList[idx - 1] = last;
            voterIndex[last] = idx;
        }
        votersList.pop();
        voterIndex[who] = 0;
    }

    // Allow contract to receive ETH (in case someone sends by mistake)
    receive() external payable {}
    fallback() external payable {}
}
