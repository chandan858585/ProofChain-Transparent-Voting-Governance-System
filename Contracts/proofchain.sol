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
        bool canceled;
        address proposer;
        uint256 totalVotingPowerSnapshot;
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(address => uint256) public votingPower;
    mapping(address => bool) public isVoter;
    mapping(address => uint256) private voterIndex;
    address[] private votersList;

    mapping(uint256 => mapping(address => uint256)) public snapshot;
    mapping(uint256 => address[]) private proposalVoters;

    uint256 public proposalCount;
    uint256 public totalVotingPower;
    address public admin;
    uint8 public quorumPercent;
    bool public paused;

    event ProposalCreated(uint256 id, string title);
    event VoteCast(uint256 id, address voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 id, bool passed);
    event ProposalCancelled(uint256 id);
    event VoterUpdated(address voter, uint256 weight);

    modifier onlyAdmin() { require(msg.sender == admin, "Not admin"); _; }
    modifier onlyVoter() { require(isVoter[msg.sender], "Not voter"); _; }
    modifier proposalExists(uint256 id){ require(id>0&&id<=proposalCount,"No proposal"); _; }
    modifier notPaused(){ require(!paused,"Paused"); _; }

    constructor(uint8 _q){ 
        require(_q>0&&_q<=100);
        admin=msg.sender;
        isVoter[msg.sender]=true;
        votingPower[msg.sender]=1;
        totalVotingPower=1;
        votersList.push(msg.sender);
        voterIndex[msg.sender]=1;
        quorumPercent=_q;
    }

    function createProposal(string calldata t,string calldata d,uint256 days_) external onlyVoter notPaused {
        require(bytes(t).length>0&&days_>0);
        proposalCount++;
        uint256 total;
        for(uint i; i<votersList.length; i++){
            address v=votersList[i]; uint w=votingPower[v];
            if(w==0) continue;
            snapshot[proposalCount][v]=w;
            proposalVoters[proposalCount].push(v);
            total+=w;
        }
        proposals[proposalCount]=Proposal(proposalCount,t,d,0,0,block.timestamp+days_*1 days,false,false,msg.sender,total);
        emit ProposalCreated(proposalCount,t);
    }

    function vote(uint256 id,bool support) external onlyVoter proposalExists(id) notPaused {
        Proposal storage p=proposals[id];
        require(block.timestamp<p.deadline&&!p.canceled&&!hasVoted[id][msg.sender]);
        uint256 w=snapshot[id][msg.sender];
        require(w>0,"No weight");
        hasVoted[id][msg.sender]=true;
        if(support)p.forVotes+=w; else p.againstVotes+=w;
        emit VoteCast(id,msg.sender,support,w);
    }

    function executeProposal(uint256 id) external onlyVoter proposalExists(id) notPaused {
        Proposal storage p=proposals[id];
        require(!p.executed&&!p.canceled&&block.timestamp>p.deadline);
        require(p.forVotes+p.againstVotes>=quorumFor(id),"No quorum");
        p.executed=true;
        emit ProposalExecuted(id,p.forVotes>p.againstVotes);
    }

    function cancelProposal(uint256 id) external proposalExists(id){
        Proposal storage p=proposals[id];
        require(!p.executed&&!p.canceled&&(msg.sender==p.proposer||msg.sender==admin));
        p.canceled=true;
        emit ProposalCancelled(id);
    }

    function setVoter(address v,uint256 w) public onlyAdmin {
        require(v!=address(0));
        uint old=votingPower[v];
        if(w==0){ if(isVoter[v]){totalVotingPower-=old;isVoter[v]=false;_remove(v);} }
        else { 
            if(!isVoter[v]){isVoter[v]=true;votersList.push(v);voterIndex[v]=votersList.length;}
            totalVotingPower=totalVotingPower+ w - old; votingPower[v]=w;
        }
        emit VoterUpdated(v,w);
    }

    function batchSetVoters(address[] calldata a,uint256[] calldata w) external onlyAdmin {
        require(a.length==w.length);
        for(uint i;i<a.length;i++) setVoter(a[i],w[i]);
    }

    function setQuorum(uint8 q) external onlyAdmin { require(q>0&&q<=100); quorumPercent=q; }
    function transferAdmin(address n) external onlyAdmin { require(n!=address(0)); admin=n; }
    function pause() external onlyAdmin { paused=true; }
    function unpause() external onlyAdmin { paused=false; }

    function quorumFor(uint256 id) public view returns(uint256){
        Proposal storage p=proposals[id];
        return (p.totalVotingPowerSnapshot*quorumPercent+99)/100;
    }

    function _remove(address who) internal {
        uint idx=voterIndex[who]; if(idx==0)return;
        uint last=votersList.length;
        if(idx!=last){ address l=votersList[last-1]; votersList[idx-1]=l; voterIndex[l]=idx; }
        votersList.pop(); voterIndex[who]=0;
    }
}
