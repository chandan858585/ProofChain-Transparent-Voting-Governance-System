// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract Project {
    struct Proposal {
        uint256 id;
        string title;
        string description;
        uint256 forVotes;       // total weighted "for" votes
        uint256 againstVotes;   // total weighted "against" votes
        uint256 deadline;
        bool executed;
        address proposer;
    }
    
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(address => bool) public isVoter;
    mapping(address => uint256) public votingPower; // weighted votes
    
    uint256 public proposalCount;
    address public admin;
    uint256 public quorum; // minimum total weighted votes required

    event ProposalCreated(uint256 indexed proposalId, string title, address proposer);
    event VoteCast(uint256 indexed proposalId, address voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed proposalId, bool success, uint256 forVotes, uint256 againstVotes);
    event VoterRegistered(address voter, uint256 weight);
    event VoterRemoved(address voter);
    event VoterWeightUpdated(address voter, uint256 newWeight);
    
    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can perform this action");
        _;
    }
    
    modifier onlyVoter() {
        require(isVoter[msg.sender], "Only registered voters can vote");
        _;
    }
    
    constructor(uint256 _quorum) {
        admin = msg.sender;
        isVoter[msg.sender] = true; 
        votingPower[msg.sender] = 1; // Admin starts with 1 voting power
        quorum = _quorum;
    }
    
    // Core Function 1: Create Proposal
    function createProposal(
        string memory _title,
        string memory _description,
        uint256 _durationInDays
    ) external onlyVoter {
        require(_durationInDays > 0, "Duration must be greater than zero");
        
        proposalCount++;
        
        proposals[proposalCount] = Proposal({
            id: proposalCount,
            title: _title,
            description: _description,
            forVotes: 0,
            againstVotes: 0,
            deadline: block.timestamp + (_durationInDays * 1 days),
            executed: false,
            proposer: msg.sender
        });
        
        emit ProposalCreated(proposalCount, _title, msg.sender);
    }
    
    // Core Function 2: Cast Weighted Vote
    function vote(uint256 _proposalId, bool _support) external onlyVoter {
        require(_proposalId > 0 && _proposalId <= proposalCount, "Invalid proposal ID");
        require(!hasVoted[_proposalId][msg.sender], "Already voted");
        require(block.timestamp < proposals[_proposalId].deadline, "Voting period ended");
        
        uint256 weight = votingPower[msg.sender];
        require(weight > 0, "No voting power assigned");
        
        hasVoted[_proposalId][msg.sender] = true;
        
        if (_support) {
            proposals[_proposalId].forVotes += weight;
        } else {
            proposals[_proposalId].againstVotes += weight;
        }
        
        emit VoteCast(_proposalId, msg.sender, _support, weight);
    }
    
    // Core Function 3: Get Proposal Details
    function getProposal(uint256 _proposalId) external view returns (
        uint256 id,
        string memory title,
        string memory description,
        uint256 forVotes,
        uint256 againstVotes,
        uint256 deadline,
        bool executed,
        address proposer
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
            proposal.proposer
        );
    }

    // Utility: Get All Proposals
    function getAllProposals() external view returns (Proposal[] memory) {
        Proposal[] memory allProposals = new Proposal[](proposalCount);
        for (uint256 i = 1; i <= proposalCount; i++) {
            allProposals[i - 1] = proposals[i];
        }
        return allProposals;
    }
    
    // Core Function 4: Execute Proposal (with weighted quorum)
    function executeProposal(uint256 _proposalId) external onlyVoter {
        require(_proposalId > 0 && _proposalId <= proposalCount, "Invalid proposal ID");
        Proposal storage proposal = proposals[_proposalId];
        
        require(!proposal.executed, "Proposal already executed");
        require(block.timestamp > proposal.deadline, "Voting period not ended yet");
        
        uint256 totalVotes = proposal.forVotes + proposal.againstVotes;
        require(totalVotes >= quorum, "Not enough votes to reach quorum");

        bool success = proposal.forVotes > proposal.againstVotes;

        proposal.executed = true;
        
        emit ProposalExecuted(_proposalId, success, proposal.forVotes, proposal.againstVotes);
    }

    // Admin: Register voter with voting weight
    function registerVoter(address _voter, uint256 _weight) external onlyAdmin {
        require(_weight > 0, "Weight must be > 0");
        isVoter[_voter] = true;
        votingPower[_voter] = _weight;
        emit VoterRegistered(_voter, _weight);
    }

    // Admin: Remove voter
    function removeVoter(address _voter) external onlyAdmin {
        isVoter[_voter] = false;
        votingPower[_voter] = 0;
        emit VoterRemoved(_voter);
    }

    // Admin: Update voter weight
    function updateVoterWeight(address _voter, uint256 _newWeight) external onlyAdmin {
        require(isVoter[_voter], "Not a registered voter");
        votingPower[_voter] = _newWeight;
        emit VoterWeightUpdated(_voter, _newWeight);
    }

    // Proposer: Update proposal duration before voting ends
    function updateProposalDuration(uint256 _proposalId, uint256 _extraDays) external {
        Proposal storage proposal = proposals[_proposalId];
        require(msg.sender == proposal.proposer, "Only proposer can extend deadline");
        require(block.timestamp < proposal.deadline, "Voting period already ended");
        proposal.deadline += (_extraDays * 1 days);
    }

    // Admin: Update quorum
    function updateQuorum(uint256 _newQuorum) external onlyAdmin {
        require(_newQuorum > 0, "Quorum must be greater than zero");
        quorum = _newQuorum;
    }
}

