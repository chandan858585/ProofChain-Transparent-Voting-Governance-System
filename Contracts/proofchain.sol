// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Weighted-DAO (shortened & improved)
/// @notice Weighted voting with per-proposal voting power snapshot, quorum (percent), proposal cancellation and basic admin controls.
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
        uint256 totalVotingPowerSnapshot;
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(address => uint256) public votingPower;
    mapping(address => bool) public isVoter;

    // For enumerating voters
    address[] private votersList;
    mapping(address => uint256) private voterIndex; // 1-based index into votersList (0 = not present)

    uint256 public proposalCount;
    uint256 public totalVotingPower;
    address public admin;
    uint8 public quorumPercent;

    // Reentrancy guard
    bool private locked;

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

    modifier onlyAdmin() { require(msg.sender == admin, "Not admin"); _; }
    modifier onlyVoter() { require(isVoter[msg.sender], "Not voter"); _; }
    modifier nonReentrant() {
        require(!locked, "Reentrant");
        locked = true;
        _;
        locked = false;
    }
    modifier proposalExists(uint256 id) {
        require(id > 0 && id <= proposalCount, "Proposal not found");
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
        locked = false;
        proposalCount = 0;
    }

    // --- Core ---

    /// @notice Create a proposal. Snapshot of total voting power is taken at creation.
    /// @param _title short title (non-empty)
    /// @param _desc longer description
    /// @param _days duration in days (>0)
    function createProposal(string calldata _title, string calldata _desc, uint256 _days) external onlyVoter {
        require(bytes(_title).length > 0, "Title required");
        require(_days > 0, "Days must be > 0");
        require(totalVotingPower > 0, "No voting power in system");

        proposalCount++;
        uint256 snapshot = totalVotingPower;
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
            totalVotingPowerSnapshot: snapshot
        });

        emit ProposalCreated(proposalCount, _title, msg.sender, snapshot, quorumPercent);
    }

    /// @notice Cast your weighted vote on a proposal (one address, one vote per proposal).
    /// @param id proposal id
    /// @param support true = for, false = against
    function vote(uint256 id, bool support) external onlyVoter proposalExists(id) {
        Proposal storage p = proposals[id];
        require(!p.canceled, "Canceled");
        require(block.timestamp < p.deadline, "Voting closed");
        require(!hasVoted[id][msg.sender], "Already voted");

        uint256 w = votingPower[msg.sender];
        require(w > 0, "No voting weight");

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
    function executeProposal(uint256 id) external onlyVoter nonReentrant proposalExists(id) {
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
    /// @dev If some ids were never created they would be zeroed structs. In this implementation proposals are created sequentially.
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
}

