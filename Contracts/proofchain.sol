// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract Project {
    struct Proposal {
        uint256 id;
        string title;
        string description;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 deadline;
        bool executed;
        address proposer;
    }
    
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(address => bool) public isVoter;
    
    uint256 public proposalCount;
    address public admin;
    uint256 public quorum; // minimum total votes required

    event ProposalCreated(uint256 indexed proposalId, string title, address proposer);
    event VoteCast(uint256 indexed proposalId, address voter, bool support);
    event ProposalExecuted(uint256 indexed proposalId, bool success, uint256 forVotes, uint256 againstVotes);
    event VoterRegistered(address voter);
    event VoterRemoved(address voter);
    
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
        isVoter[msg.sender] = true; // Admin is automatically a voter
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
    
    // Core Function 2: Cast Vote
    function vote(uint256 _proposalId, bool _support) external onlyVoter {
        require(_proposalId > 0 && _proposalId <= proposalCount, "Invalid proposal ID");
        require(!hasVoted[_proposalId][msg.sender], "Already voted");
        require(block.timestamp < proposals[_proposalId].deadline, "Voting period ended");
        
        hasVoted[_proposalId][msg.sender] = true;
        
        if (_support) {
            proposals[_proposalId].forVotes++;
        } else {
            proposals[_proposalId].againstVotes++;
        }
        
        emit VoteCast(_proposalId, msg.sender, _support);
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

    // Modified Utility: Get All Proposals (full details)
    function getAllProposals() external view returns (Proposal[] memory) {
        Proposal[] memory allProposals = new Proposal[](proposalCount);
        for (uint256 i = 1; i <= proposalCount; i++) {
            allProposals[i - 1] = proposals[i];
        }
        return allProposals;
    }
    
    // Core Function 4: Execute Proposal
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

    // Admin: Register voter
    function registerVoter(address _voter) external onlyAdmin {
        isVoter[_voter] = true;
        emit VoterRegistered(_voter);
    }

    // Admin: Remove voter
    function removeVoter(address _voter) external onlyAdmin {
        isVoter[_voter] = false;
        emit VoterRemoved(_voter);
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
