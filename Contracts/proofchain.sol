
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
    
    event ProposalCreated(uint256 indexed proposalId, string title, address proposer);
    event VoteCast(uint256 indexed proposalId, address voter, bool support);
    event ProposalExecuted(uint256 indexed proposalId);
    
    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can perform this action");
        _;
    }
    
    modifier onlyVoter() {
        require(isVoter[msg.sender], "Only registered voters can vote");
        _;
    }
    
    constructor() {
        admin = msg.sender;
        isVoter[msg.sender] = true; // Admin is automatically a voter
    }
    
    // Core Function 1: Create Proposal
    function createProposal(
        string memory _title,
        string memory _description,
        uint256 _durationInDays
    ) external onlyVoter {
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
    
    // Additional utility functions
    function registerVoter(address _voter) external onlyAdmin {
        isVoter[_voter] = true;
    }
    
    function getAllProposals() external view returns (uint256[] memory) {
        uint256[] memory proposalIds = new uint256[](proposalCount);
        for (uint256 i = 1; i <= proposalCount; i++) {
            proposalIds[i - 1] = i;
        }
        return proposalIds;
    }
}
