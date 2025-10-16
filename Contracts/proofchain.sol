          // SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Simple DAO-style Proposal & Snapshot Voting (improved)
/// @notice Improvements: fixes around voter removal, bookkeeping, helpers, safer events and small gas/logic tweaks
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
        uint256 totalVotingPowerSnapshot; // snapshot of total voting power when proposal created
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(address => uint256) public votingPower;
    mapping(address => bool) public isVoter;
    mapping(address => uint256) private voterIndex; // 1-based index into votersList
    address[] private votersList;

    mapping(uint256 => mapping(address => uint256)) public snapshot; // proposalId => voter => weight
    mapping(uint256 => address[]) private proposalVoters;

    uint256 public proposalCount;
    uint256 public totalVotingPower;
    address public admin;
    uint8 public quorumPercent;
    bool public paused;

    // ---- Events ----
    event ProposalCreated(uint256 indexed id, string title, address indexed proposer, uint256 deadline, uint256 totalVotingPowerSnapshot);
    event VoteCast(uint256 indexed id, address indexed voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed id, bool passed);
    event ProposalCancelled(uint256 indexed id);
    event VoterUpdated(address indexed voter, uint256 weight);
    event VoterRemoved(address indexed voter);
    event ParameterUpdated(string parameter, uint256 newValue);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event Paused(address by);
    event Unpaused(address by);
    event ProposalSnapshotsCleared(uint256 indexed id, address by);

    // ---- Modifiers ----
    modifier onlyAdmin() { require(msg.sender == admin, "Not admin"); _; }
    modifier onlyVoter() { require(isVoter[msg.sender], "Not voter"); _; }
    modifier proposalExists(uint256 id){ require(proposals[id].id != 0, "No proposal"); _; }
    modifier notPaused(){ require(!paused,"Paused"); _; }

    // ---- Constructor ----
    constructor(uint8 _q){ 
        require(_q>0 && _q<=100,"Invalid quorum");
        admin = msg.sender;
        // initial admin is also a voter with weight 1
        _addNewVoter(msg.sender, 1);
        quorumPercent = _q;
    }

    // ---- Core DAO Functions ----
    /// @notice Create a proposal and snapshot current voter weights (non-zero only)
    function createProposal(string calldata t,string calldata d,uint256 days_) external onlyVoter notPaused {
        require(bytes(t).length>0 && days_>0,"Invalid input");
        proposalCount++;
        uint256 pid = proposalCount;
        uint256 total;

        // take per-voter snapshot and compute total snapshot voting power
        // only store non-zero weights to reduce storage
        uint256 len = votersList.length;
        for (uint256 i = 0; i < len; ) {
            address v = votersList[i];
            uint256 w = votingPower[v];
            if (w != 0) {
                snapshot[pid][v] = w;
                proposalVoters[pid].push(v);
                total += w;
            }
            unchecked { ++i; }
        }

        proposals[pid] = Proposal({
            id: pid,
            title: t,
            description: d,
            forVotes: 0,
            againstVotes: 0,
            deadline: block.timestamp + (days_ * 1 days),
            executed: false,
            canceled: false,
            proposer: msg.sender,
            totalVotingPowerSnapshot: total
        });

        emit ProposalCreated(pid, t, msg.sender, proposals[pid].deadline, total);
    }

    function vote(uint256 id,bool support) external onlyVoter proposalExists(id) notPaused {
        Proposal storage p = proposals[id];
        require(block.timestamp < p.deadline && !p.canceled && !hasVoted[id][msg.sender],"Cannot vote");
        uint256 w = snapshot[id][msg.sender];
        require(w>0,"No weight");
        hasVoted[id][msg.sender] = true;
        if(support) p.forVotes += w; else p.againstVotes += w;
        emit VoteCast(id, msg.sender, support, w);
    }

    function executeProposal(uint256 id) external onlyVoter proposalExists(id) notPaused {
        Proposal storage p = proposals[id];
        require(!p.executed && !p.canceled && block.timestamp > p.deadline,"Cannot execute");
        require(p.forVotes + p.againstVotes >= quorumFor(id),"No quorum");
        p.executed = true;
        bool passed = p.forVotes > p.againstVotes;
        emit ProposalExecuted(id, passed);
    }

    function cancelProposal(uint256 id) external proposalExists(id){
        Proposal storage p = proposals[id];
        require(!p.executed && !p.canceled && (msg.sender == p.proposer || msg.sender == admin),"Not allowed");
        p.canceled = true;
        emit ProposalCancelled(id);
    }

    // ---- Admin Controls ----
    /// @notice Set or update a voter's weight. Weight 0 removes the voter.
    function setVoter(address v,uint256 w) public onlyAdmin {
        require(v!=address(0),"Zero addr");
        uint256 old = votingPower[v];

        if (w == 0) {
            // remove voter if present
            if (isVoter[v]) {
                // reduce totalVotingPower by their old weight (defensive)
                if (old > 0 && totalVotingPower >= old) {
                    totalVotingPower -= old;
                }
                // keep voterIndex intact until _remove reads it
                votingPower[v] = 0;
                isVoter[v] = false;
                _remove(v);
                emit VoterRemoved(v);
            } else {
                // not a voter -> nothing to do, but ensure weight is zero
                votingPower[v] = 0;
            }
            emit VoterUpdated(v, 0);
            return;
        }

        // adding or updating a voter
        if (!isVoter[v]) {
            isVoter[v] = true;
            votersList.push(v);
            voterIndex[v] = votersList.length; // 1-based
        }
        // update totalVotingPower safely
        if (w >= old) {
            totalVotingPower += (w - old);
        } else {
            // w < old
            // old - w won't underflow because old >= w
            totalVotingPower -= (old - w);
        }
        votingPower[v] = w;
        emit VoterUpdated(v, w);
    }

    function batchSetVoters(address[] calldata a,uint256[] calldata w) external onlyAdmin {
        require(a.length==w.length,"Length mismatch");
        for(uint i = 0; i < a.length; ){
            setVoter(a[i], w[i]);
            unchecked { ++i; }
        }
    }

    // ---- Parameter Update Functions ----

    function updateQuorum(uint8 q) external onlyAdmin {
        require(q>0&&q<=100,"Invalid quorum");
        quorumPercent = q;
        emit ParameterUpdated("quorumPercent", q);
    }

    function extendProposalDeadline(uint256 id, uint256 extraDays) external onlyAdmin proposalExists(id) {
        Proposal storage p = proposals[id];
        require(!p.executed && !p.canceled, "Inactive proposal");
        p.deadline += extraDays * 1 days;
        emit ParameterUpdated("proposalDeadline", p.deadline);
    }

    function updateProposalDetails(uint256 id, string calldata newTitle, string calldata newDesc) external onlyAdmin proposalExists(id) {
        Proposal storage p = proposals[id];
        require(!p.executed && !p.canceled, "Already processed");
        if(bytes(newTitle).length > 0) p.title = newTitle;
        if(bytes(newDesc).length > 0) p.description = newDesc;
        emit ParameterUpdated("proposalDetails", id);
    }

    function transferAdmin(address n) external onlyAdmin { 
        require(n!=address(0),"Zero addr"); 
        emit AdminTransferred(admin, n); 
        admin = n; 
    }

    function pause() external onlyAdmin { paused = true; emit Paused(msg.sender); }
    function unpause() external onlyAdmin { paused = false; emit Unpaused(msg.sender); }

    // ---- Utility Views ----
    function quorumFor(uint256 id) public view returns(uint256){
        Proposal storage p = proposals[id];
        // rounding up: (total * quorum + 100 - 1) / 100
        return (p.totalVotingPowerSnapshot * quorumPercent + 99) / 100;
    }

    /// @notice Return the full voters list (careful: can be large)
    function getVoters() external view returns(address[] memory) { return votersList; }

    /// @notice Get voter list who were snapshotted for a given proposal
    function getProposalVoters(uint256 id) external view proposalExists(id) returns(address[] memory) {
        return proposalVoters[id];
    }

    function getSnapshotWeight(uint256 id, address who) external view proposalExists(id) returns(uint256) {
        return snapshot[id][who];
    }

    /// @notice Convenience: return the Proposal struct
    function getProposal(uint256 id) external view proposalExists(id) returns (Proposal memory) {
        return proposals[id];
    }

    // ---- Storage-cleanup helper ----
    /// @notice Clears stored per-proposal snapshots and voters list for a processed proposal.
    /// Use to reclaim storage after a proposal is executed or cancelled.
    /// Can be called by admin or the original proposer to allow DAO-opposed cleanups.
    function clearProposalSnapshots(uint256 id) external proposalExists(id) {
        Proposal storage p = proposals[id];
        require(p.executed || p.canceled, "Only processed proposals");
        require(msg.sender == admin || msg.sender == p.proposer, "Not allowed");

        address[] storage pv = proposalVoters[id];
        uint256 len = pv.length;
        for (uint256 i = 0; i < len; ) {
            address v = pv[i];
            // delete snapshot weight (sets to 0)
            delete snapshot[id][v];
            unchecked { ++i; }
        }
        // delete the array of voters
        delete proposalVoters[id];
        emit ProposalSnapshotsCleared(id, msg.sender);
    }

    // ---- Internal ----
    function _remove(address who) internal {
        uint256 idx = voterIndex[who];
        if (idx == 0) return; // not present
        uint256 last = votersList.length;
        if (idx != last){
            address lastAddr = votersList[last-1];
            votersList[idx-1] = lastAddr;
            voterIndex[lastAddr] = idx;
        }
        votersList.pop();
        voterIndex[who] = 0;
    }

    function _addNewVoter(address who, uint256 weight) internal {
        if(!isVoter[who]){
            isVoter[who] = true;
            votersList.push(who);
            voterIndex[who] = votersList.length;
        }
        votingPower[who] = weight;
        totalVotingPower += weight;
        emit VoterUpdated(who, weight);
    }
}      
