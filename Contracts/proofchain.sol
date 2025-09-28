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

    constructor(uint8 _quorumPercent) {
        require(_quorumPercent > 0 && _quorumPercent <= 100, "Invalid quorum");
        admin = msg.sender;
        isVoter[msg.sender] = true;
        votingPower[msg.sender] = 1;
        totalVotingPower = 1;
        quorumPercent = _quorumPercent;
        locked = false;
    }

    // --- Core ---
    /// @notice Create a proposal. Snapshot of total voting power is taken at creation.
    function createProposal(string calldata _title, string calldata _desc, uint256 _days) external onlyVoter {
        require(_days > 0, "Days must be > 0");
        require(totalVotingPower > 0, "No voting power in system");

        proposalCount++;
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
            totalVotingPowerSnapshot: totalVotingPower
        });

        emit ProposalCreated(proposalCount, _title, msg.sender, totalVotingPower, quorumPercent);
    }

    /// @notice Cast your weighted vote on a proposal (one address, one vote per proposal).
    function vote(uint256 id, bool support) external onlyVoter {
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
    function executeProposal(uint256 id) external onlyVoter nonReentrant {
        Proposal storage p = proposals[id];
        require(!p.executed, "Already executed");
        require(!p.canceled, "Canceled");
        require(block.timestamp > p.deadline, "Voting still active");

        uint256 cast = p.forVotes + p.againstVotes;
        uint256 quorumNeeded = quorumFor(id);
        require(cast >= quorumNeeded, "No quorum");

        p.executed = true;
        bool success = p.forVotes > p.againstVotes;

        emit ProposalExecuted(id, success);
    }

    /// @notice Cancel a proposal (by proposer or admin) before execution.
    function cancelProposal(uint256 id) external {
        Proposal storage p = proposals[id];
        require(!p.executed, "Already executed");
        require(!p.canceled, "Already canceled");
        require(msg.sender == p.proposer || msg.sender == admin, "Not authorized");
        p.canceled = true;
        emit ProposalCancelled(id, msg.sender);
    }

    // --- Voters management ---
    /// @notice Add/update/remove voter weights. Admin only.
    function setVoter(address voter, uint256 weight) external onlyAdmin {
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
            isVoter[voter] = false;
            votingPower[voter] = 0;
            emit VoterUpdated(voter, 0, true);
        } else {
            if (isVoter[voter]) {
                // adjust existing
                // total = total - old + weight
                if (weight > old) {
                    totalVotingPower += (weight - old);
                } else {
                    totalVotingPower -= (old - weight);
                }
            } else {
                isVoter[voter] = true;
                totalVotingPower += weight;
            }
            votingPower[voter] = weight;
            emit VoterUpdated(voter, weight, false);
        }
    }

    // --- Utilities ---
    /// @notice Extend a proposal's deadline (only proposer, before deadline).
    function extendProposal(uint256 id, uint256 extraDays) external {
        require(extraDays > 0, "Extra days > 0");
        Proposal storage p = proposals[id];
        require(msg.sender == p.proposer, "Only proposer");
        require(block.timestamp < p.deadline, "Already closed");
        require(!p.canceled, "Canceled");

        p.deadline += extraDays * 1 days;
        emit ProposalExtended(id, p.deadline);
    }

    /// @notice Change quorum percent (admin).
    function setQuorum(uint8 q) external onlyAdmin {
        require(q > 0 && q <= 100, "Invalid quorum");
        uint8 old = quorumPercent;
        quorumPercent = q;
        emit QuorumChanged(old, q);
    }

    /// @notice Transfer admin rights.
    function transferAdmin(address n) external onlyAdmin {
        require(n != address(0), "Zero address");
        emit AdminTransferred(admin, n);
        admin = n;
    }

    // --- Views / helpers ---
    /// @notice Returns the voting power required for quorum for a proposal (uses snapshot).
    function quorumFor(uint256 id) public view returns (uint256) {
        Proposal storage p = proposals[id];
        // ceil(snapshot * quorumPercent / 100)
        if (p.totalVotingPowerSnapshot == 0) return 0;
        return (p.totalVotingPowerSnapshot * quorumPercent + 99) / 100;
    }

    function votingPowerOf(address who) external view returns (uint256) {
        return votingPower[who];
    }

    function hasProposal(uint256 id) external view returns (bool) {
        return proposals[id].id != 0;
    }

    /// @notice Get a proposal
    function getProposal(uint256 id) external view returns (Proposal memory) {
        return proposals[id];
    }

    /// @notice Get all proposals (1..proposalCount). If some ids were never created they will be zeroed structs.
    function getAllProposals() external view returns (Proposal[] memory arr) {
        arr = new Proposal[](proposalCount);
        for (uint256 i = 1; i <= proposalCount; i++) {
            arr[i - 1] = proposals[i];
        }
    }
}

