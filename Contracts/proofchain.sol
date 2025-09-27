// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Weighted-DAO (shortened version)
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
    uint256 private locked;

    // Events
    event ProposalCreated(uint256 id, string title, address proposer, uint256 snapshot, uint8 quorum);
    event VoteCast(uint256 id, address voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 id, bool success);
    event ProposalCancelled(uint256 id, address by);
    event VoterUpdated(address voter, uint256 weight, bool removed);
    event ProposalExtended(uint256 id, uint256 newDeadline);
    event AdminTransferred(address oldAdmin, address newAdmin);

    modifier onlyAdmin() { require(msg.sender == admin, "Not admin"); _; }
    modifier onlyVoter() { require(isVoter[msg.sender], "Not voter"); _; }
    modifier nonReentrant() { require(locked == 0, "Reentrant"); locked = 1; _; locked = 0; }

    constructor(uint8 _quorumPercent) {
        require(_quorumPercent > 0 && _quorumPercent <= 100);
        admin = msg.sender;
        isVoter[msg.sender] = true;
        votingPower[msg.sender] = 1;
        totalVotingPower = 1;
        quorumPercent = _quorumPercent;
    }

    // --- Core ---
    function createProposal(string calldata _title, string calldata _desc, uint256 _days) external onlyVoter {
        require(_days > 0 && totalVotingPower > 0);
        proposals[++proposalCount] = Proposal({
            id: proposalCount, title: _title, description: _desc,
            forVotes: 0, againstVotes: 0,
            deadline: block.timestamp + _days * 1 days,
            executed: false, canceled: false,
            proposer: msg.sender, totalVotingPowerSnapshot: totalVotingPower
        });
        emit ProposalCreated(proposalCount, _title, msg.sender, totalVotingPower, quorumPercent);
    }

    function vote(uint256 id, bool support) external onlyVoter {
        Proposal storage p = proposals[id];
        require(!p.canceled && block.timestamp < p.deadline && !hasVoted[id][msg.sender]);
        uint256 w = votingPower[msg.sender]; require(w > 0);
        hasVoted[id][msg.sender] = true;
        support ? p.forVotes += w : p.againstVotes += w;
        emit VoteCast(id, msg.sender, support, w);
    }

    function executeProposal(uint256 id) external onlyVoter nonReentrant {
        Proposal storage p = proposals[id];
        require(!p.executed && !p.canceled && block.timestamp > p.deadline);
        uint256 cast = p.forVotes + p.againstVotes;
        uint256 quorum = (p.totalVotingPowerSnapshot * quorumPercent + 99) / 100;
        require(cast >= quorum, "No quorum");
        p.executed = true;
        emit ProposalExecuted(id, p.forVotes > p.againstVotes);
    }

    function cancelProposal(uint256 id) external {
        Proposal storage p = proposals[id];
        require(!p.executed && !p.canceled);
        require(msg.sender == p.proposer || msg.sender == admin);
        p.canceled = true;
        emit ProposalCancelled(id, msg.sender);
    }

    // --- Voters ---
    function setVoter(address voter, uint256 weight) external onlyAdmin {
        require(voter != address(0));
        uint256 old = votingPower[voter];
        if (weight == 0) { // remove
            if (isVoter[voter]) {
                totalVotingPower -= old;
                isVoter[voter] = false; votingPower[voter] = 0;
                emit VoterUpdated(voter, 0, true);
            }
        } else {
            if (isVoter[voter]) totalVotingPower = totalVotingPower + weight - old;
            else { isVoter[voter] = true; totalVotingPower += weight; }
            votingPower[voter] = weight;
            emit VoterUpdated(voter, weight, false);
        }
    }

    // --- Utils ---
    function extendProposal(uint256 id, uint256 extraDays) external {
        Proposal storage p = proposals[id];
        require(msg.sender == p.proposer && block.timestamp < p.deadline && !p.canceled);
        p.deadline += extraDays * 1 days;
        emit ProposalExtended(id, p.deadline);
    }

    function setQuorum(uint8 q) external onlyAdmin { require(q > 0 && q <= 100); quorumPercent = q; }
    function transferAdmin(address n) external onlyAdmin { require(n != address(0)); emit AdminTransferred(admin, n); admin = n; }

    // --- Views ---
    function getProposal(uint256 id) external view returns (Proposal memory) { return proposals[id]; }
    function getAllProposals() external view returns (Proposal[] memory arr) {
        arr = new Proposal[](proposalCount);
        for (uint i = 1; i <= proposalCount; i++) arr[i-1] = proposals[i];
    }
}


