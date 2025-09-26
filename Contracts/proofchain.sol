// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title  Weighted-DAO with improved safety, quorum snapshot and utility functions
/// @notice Updated version of the user's Project contract with:
///         - total voting power tracking and snapshot per-proposal (quorum checked vs snapshot)
///         - quorum expressed as percentage (0..100)
///         - proposal cancellation
///         - admin ownership transfer
///         - reentrancy guard for execute
///         - safer voter registration/update that keeps totalVotingPower consistent
///         - events for new actions
contract Project {
    // ------------------------
    // Data structures & state
    // ------------------------
    struct Proposal {
        uint256 id;
        string title;
        string description;
        uint256 forVotes;            // total weighted "for" votes (accumulated)
        uint256 againstVotes;        // total weighted "against" votes (accumulated)
        uint256 deadline;            // timestamp
        bool executed;
        bool canceled;
        address proposer;
        uint256 totalVotingPowerSnapshot; // snapshot of total voting power when proposal was created
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(address => bool) public isVoter;
    mapping(address => uint256) public votingPower; // current voting power per voter

    uint256 public proposalCount;
    address public admin;

    // quorumPercent: required percentage (0-100) of snapshot totalVotingPower needed (e.g., 20 means 20%)
    uint8 public quorumPercent;

    // Running total of voting power of all currently-registered voters.
    uint256 public totalVotingPower;

    // Reentrancy guard
    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // ------------------------
    // Events
    // ------------------------
    event ProposalCreated(uint256 indexed proposalId, string title, address proposer, uint256 snapshotTotalVotingPower, uint8 quorumPercent);
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed proposalId, bool success, uint256 forVotes, uint256 againstVotes);
    event VoterRegistered(address indexed voter, uint256 weight);
    event VoterRemoved(address indexed voter);
    event VoterWeightUpdated(address indexed voter, uint256 newWeight);
    event ProposalExtended(uint256 indexed proposalId, uint256 newDeadline);
    event ProposalCancelled(uint256 indexed proposalId, address cancelledBy);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    // ------------------------
    // Modifiers
    // ------------------------
    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can perform this action");
        _;
    }

    modifier onlyVoter() {
        require(isVoter[msg.sender], "Only registered voters can vote");
        _;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "Reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    // ------------------------
    // Constructor
    // ------------------------
    /// @param _quorumPercent percentage of snapshot voting power required for quorum (0..100)
    constructor(uint8 _quorumPercent) {
        require(_quorumPercent > 0 && _quorumPercent <= 100, "quorumPercent must be 1..100");
        admin = msg.sender;
        isVoter[msg.sender] = true;
        votingPower[msg.sender] = 1; // admin starts with 1 voting power
        totalVotingPower = 1;
        quorumPercent = _quorumPercent;
        _status = _NOT_ENTERED;
    }

    // ------------------------
    // Core functions
    // ------------------------

    /// @notice Create a new proposal. Snapshot totalVotingPower for quorum checks.
    /// @param _title short title for proposal
    /// @param _description long description
    /// @param _durationInDays voting duration in days (>0)
    function createProposal(
        string memory _title,
        string memory _description,
        uint256 _durationInDays
    ) external onlyVoter {
        require(_durationInDays > 0, "Duration must be > 0");
        require(totalVotingPower > 0, "No voting power in system");

        proposalCount++;

        proposals[proposalCount] = Proposal({
            id: proposalCount,
            title: _title,
            description: _description,
            forVotes: 0,
            againstVotes: 0,
            deadline: block.timestamp + (_durationInDays * 1 days),
            executed: false,
            canceled: false,
            proposer: msg.sender,
            totalVotingPowerSnapshot: totalVotingPower
        });

        emit ProposalCreated(proposalCount, _title, msg.sender, totalVotingPower, quorumPercent);
    }

    /// @notice Cast a weighted vote. A voter's current votingPower is used at the time of voting.
    /// @param _proposalId id of the proposal
    /// @param _support true for "for", false for "against"
    function vote(uint256 _proposalId, bool _support) external onlyVoter {
        require(_proposalId > 0 && _proposalId <= proposalCount, "Invalid proposal ID");
        Proposal storage proposal = proposals[_proposalId];
        require(!proposal.canceled, "Proposal canceled");
        require(block.timestamp < proposal.deadline, "Voting period ended");
        require(!hasVoted[_proposalId][msg.sender], "Already voted");

        uint256 weight = votingPower[msg.sender];
        require(weight > 0, "No voting power assigned");

        hasVoted[_proposalId][msg.sender] = true;

        if (_support) {
            proposal.forVotes += weight;
        } else {
            proposal.againstVotes += weight;
        }

        emit VoteCast(_proposalId, msg.sender, _support, weight);
    }

    /// @notice Execute a proposal after deadline if quorum met and not already executed/canceled.
    /// @dev Uses snapshot totalVotingPower recorded at creation and quorumPercent to validate quorum.
    function executeProposal(uint256 _proposalId) external onlyVoter nonReentrant {
        require(_proposalId > 0 && _proposalId <= proposalCount, "Invalid proposal ID");
        Proposal storage proposal = proposals[_proposalId];

        require(!proposal.executed, "Proposal already executed");
        require(!proposal.canceled, "Proposal canceled");
        require(block.timestamp > proposal.deadline, "Voting period not ended yet");

        uint256 totalCastVotes = proposal.forVotes + proposal.againstVotes;

        // Compute required quorum: (snapshot * quorumPercent + 99) / 100 for rounding up
        uint256 requiredQuorum = (proposal.totalVotingPowerSnapshot * uint256(quorumPercent) + 99) / 100;
        require(totalCastVotes >= requiredQuorum, "Quorum not reached");

        bool success = proposal.forVotes > proposal.againstVotes;

        proposal.executed = true;

        emit ProposalExecuted(_proposalId, success, proposal.forVotes, proposal.againstVotes);
    }

    /// @notice Cancel a proposal. Can be called by admin or proposer before execution.
    /// @param _proposalId id of the proposal
    function cancelProposal(uint256 _proposalId) external {
        require(_proposalId > 0 && _proposalId <= proposalCount, "Invalid proposal ID");
        Proposal storage proposal = proposals[_proposalId];
        require(!proposal.executed, "Already executed");
        require(!proposal.canceled, "Already canceled");
        require(msg.sender == proposal.proposer || msg.sender == admin, "Only proposer or admin can cancel");

        proposal.canceled = true;
        emit ProposalCancelled(_proposalId, msg.sender);
    }

    // ------------------------
    // Admin / Voter management
    // ------------------------

    /// @notice Register or update a voter with weight. Only admin can call.
    /// @dev If an address is already a voter, their weight will be replaced (and totalVotingPower adjusted).
    /// @param _voter address of voter
    /// @param _weight voting weight (must be > 0)
    function registerVoter(address _voter, uint256 _weight) external onlyAdmin {
        require(_voter != address(0), "Zero address");
        require(_weight > 0, "Weight must be > 0");

        if (isVoter[_voter]) {
            // updating existing voter via registerVoter: adjust totals accordingly
            uint256 old = votingPower[_voter];
            votingPower[_voter] = _weight;
            if (old >= _weight) {
                totalVotingPower -= (old - _weight);
            } else {
                totalVotingPower += (_weight - old);
            }
            emit VoterWeightUpdated(_voter, _weight);
        } else {
            isVoter[_voter] = true;
            votingPower[_voter] = _weight;
            totalVotingPower += _weight;
            emit VoterRegistered(_voter, _weight);
        }
    }

    /// @notice Remove a voter entirely. Only admin can call.
    /// @param _voter address to remove
    function removeVoter(address _voter) external onlyAdmin {
        require(_voter != address(0), "Zero address");
        require(isVoter[_voter], "Not a voter");

        uint256 weight = votingPower[_voter];
        // update state
        isVoter[_voter] = false;
        votingPower[_voter] = 0;

        // adjust running total safely
        if (totalVotingPower >= weight) {
            totalVotingPower -= weight;
        } else {
            totalVotingPower = 0;
        }

        emit VoterRemoved(_voter);
    }

    /// @notice Update a voter's weight. Only admin can call.
    /// @param _voter address
    /// @param _newWeight new voting power (can be zero to effectively remove power but keep registered)
    function updateVoterWeight(address _voter, uint256 _newWeight) external onlyAdmin {
        require(_voter != address(0), "Zero address");
        require(isVoter[_voter], "Not a registered voter");

        uint256 old = votingPower[_voter];
        votingPower[_voter] = _newWeight;

        if (old >= _newWeight) {
            totalVotingPower -= (old - _newWeight);
        } else {
            totalVotingPower += (_newWeight - old);
        }

        emit VoterWeightUpdated(_voter, _newWeight);
    }

    // ------------------------
    // Utility / admin setters
    // ------------------------

    /// @notice Extend proposal deadline by extra days. Only proposer can extend and only before deadline.
    /// @param _proposalId id
    /// @param _extraDays number of extra days to add (must be > 0)
    function updateProposalDuration(uint256 _proposalId, uint256 _extraDays) external {
        require(_proposalId > 0 && _proposalId <= proposalCount, "Invalid proposal ID");
        require(_extraDays > 0, "Extra days must be > 0");

        Proposal storage proposal = proposals[_proposalId];
        require(msg.sender == proposal.proposer, "Only proposer can extend");
        require(block.timestamp < proposal.deadline, "Voting period already ended");
        require(!proposal.canceled, "Proposal canceled");

        proposal.deadline += (_extraDays * 1 days);
        emit ProposalExtended(_proposalId, proposal.deadline);
    }

    /// @notice Update quorum percent (1..100). Only admin.
    /// @param _newQuorumPercent new quorum percentage
    function updateQuorumPercent(uint8 _newQuorumPercent) external onlyAdmin {
        require(_newQuorumPercent > 0 && _newQuorumPercent <= 100, "quorumPercent must be 1..100");
        quorumPercent = _newQuorumPercent;
    }

    /// @notice Transfer admin to a new address
    /// @param _newAdmin new admin address
    function transferAdmin(address _newAdmin) external onlyAdmin {
        require(_newAdmin != address(0), "Zero address");
        address previous = admin;
        admin = _newAdmin;
        emit AdminTransferred(previous, _newAdmin);
    }

    // ------------------------
    // Views
    // ------------------------

    /// @notice Get proposal details (includes snapshot total voting power)
    function getProposal(uint256 _proposalId) external view returns (
        uint256 id,
        string memory title,
        string memory description,
        uint256 forVotes,
        uint256 againstVotes,
        uint256 deadline,
        bool executed,
        bool canceled,
        address proposer,
        uint256 totalVotingPowerSnapshot
    ) {
        require(_proposalId > 0 && _proposalId <= proposalCount, "Invalid proposal ID");
        Proposal memory proposal = proposals[_proposalId];

        return (
            proposal.id,
            proposal.title,
            proposal.description,
            proposal.forVotes,
            proposal.againstVotes,
            proposal.deadline,
            proposal.executed,
            proposal.canceled,
            proposal.proposer,
            proposal.totalVotingPowerSnapshot
        );
    }

    /// @notice Return all proposals (warning: can be gas heavy in on-chain contexts; intended for small sets or off-chain calls)
    function getAllProposals() external view returns (Proposal[] memory) {
        Proposal[] memory allProposals = new Proposal[](proposalCount);
        for (uint256 i = 1; i <= proposalCount; i++) {
            allProposals[i - 1] = proposals[i];
        }
        return allProposals;
    }

    /// @notice Get the total voting power currently registered in the system
    function getTotalVotingPower() external view returns (uint256) {
        return totalVotingPower;
    }
}

