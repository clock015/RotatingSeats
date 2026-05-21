// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/governance/utils/IVotes.sol";
import "./interfaces/ITokenA.sol";
import "./interfaces/ISeatToken.sol";
import "./interfaces/ISeatTokenFactory.sol";

contract ProportionalElection is IVotes {
    ITokenA public immutable tokenA;
    ISeatTokenFactory public immutable seatFactory;

    uint256 public immutable genesisTime; // 项目启动时间
    uint256 public constant ELECTION_CYCLE = 360 days;
    uint256 public constant VOTING_DURATION = 7 days;
    uint256 public constant SEATS_PER_ROUND = 200 * 1e18;

    struct RoundInfo {
        uint256 totalVotes;
        uint256 finalizedTime; // 只有 finalized 后才记录，用于历史溯源
        address seatToken;
        bool finalized;
        mapping(address => uint256) candidateVotes;
        mapping(address => bool) hasClaimed;
    }

    mapping(uint256 => RoundInfo) public rounds;
    // 聚合 5 个活跃槽位
    address[5] public activeSeatTokens;

    constructor(address _tokenA, address _factory) {
        tokenA = ITokenA(_tokenA);
        seatFactory = ISeatTokenFactory(_factory);
        genesisTime = block.timestamp;
    }

    // =====================================================
    // Epoch 计算逻辑
    // =====================================================

    function currentRoundId() public view returns (uint256) {
        return (block.timestamp - genesisTime) / ELECTION_CYCLE;
    }

    /**
     * @dev 检查当前是否在投票窗口内（每个周期的前 7 天）
     */
    function isVotingPeriod() public view returns (bool) {
        return
            (block.timestamp - genesisTime) % ELECTION_CYCLE < VOTING_DURATION;
    }

    // =====================================================
    // 核心业务逻辑
    // =====================================================

    /**
     * @dev 投票：只能在投票窗口内进行
     */
    function vote(address candidate, uint256 amount) external {
        require(isVotingPeriod(), "Voting closed");

        uint256 roundId = currentRoundId();
        tokenA.burnFrom(msg.sender, amount);

        rounds[roundId].candidateVotes[candidate] += amount;
        rounds[roundId].totalVotes += amount;
    }

    /**
     * @dev 结算：投票窗口结束后可调用。
     * 该函数实现了“精准轮换”：只有此时才会替换掉 5 年前的旧合约，
     * 保证了选举期间投票权不会从 100% 掉到 80%。
     */
    function finalizeRound(uint256 roundId) external {
        // 只能结算过去或者已经结束投票的轮次
        if (roundId == currentRoundId()) {
            require(!isVotingPeriod(), "Voting still active");
        }
        require(!rounds[roundId].finalized, "Already finalized");

        // 部署新合约
        address newToken = seatFactory.createSeatToken(
            string(abi.encodePacked("Council ", _uintToString(roundId))),
            "CS",
            address(this)
        );

        rounds[roundId].seatToken = newToken;
        rounds[roundId].finalized = true;
        rounds[roundId].finalizedTime = block.timestamp;

        // 核心：轮替 5 年前的旧席位
        activeSeatTokens[roundId % 5] = newToken;
    }

    /**
     * @dev 领奖：按比例 Mint 席位
     */
    function claimSeats(uint256 roundId, address candidate) external {
        RoundInfo storage round = rounds[roundId];
        require(round.finalized, "Not finalized");
        require(!round.hasClaimed[candidate], "Already claimed");

        uint256 votes = round.candidateVotes[candidate];
        require(votes > 0, "No votes cast");

        uint256 amount = (votes * SEATS_PER_ROUND) / round.totalVotes;
        round.hasClaimed[candidate] = true;

        ISeatToken(round.seatToken).mint(candidate, amount);
    }

    // =====================================================
    // IVotes 聚合与历史修复
    // =====================================================

    /**
     * @dev 实时票数聚合
     */
    function getVotes(address account) public view override returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < 5; i++) {
            address token = activeSeatTokens[i];
            if (token != address(0)) {
                total += IVotes(token).getVotes(account);
            }
        }
        return total;
    }

    /**
     * @dev 历史票数修复：利用 finalizedTime 寻找 timepoint 当时有效的合约
     */
    function getPastVotes(
        address account,
        uint256 timepoint
    ) public view override returns (uint256) {
        uint256 targetRoundId = type(uint256).max;

        // 1. 寻找在该 timepoint 之前最后一次 finalize 的 roundId
        // 因为 roundId 随时间递增，我们从当前 round 向前找
        uint256 startSearch = currentRoundId();
        for (uint256 i = startSearch + 1; i > 0; i--) {
            uint256 rId = i - 1;
            if (
                rounds[rId].finalized && rounds[rId].finalizedTime <= timepoint
            ) {
                targetRoundId = rId;
                break;
            }
        }

        if (targetRoundId == type(uint256).max) return 0;

        // 2. 聚合 targetRoundId 及其前 4 轮的合约
        uint256 total = 0;
        uint256 fromRound = targetRoundId > 4 ? targetRoundId - 4 : 0;
        for (uint256 r = fromRound; r <= targetRoundId; r++) {
            address token = rounds[r].seatToken;
            if (token != address(0)) {
                total += IVotes(token).getPastVotes(account, timepoint);
            }
        }
        return total;
    }

    // 实现 IVotes 要求的其他接口
    function getPastTotalSupply(
        uint256 timepoint
    ) public view override returns (uint256) {
        uint256 targetRoundId = type(uint256).max;
        // 寻找 timepoint 对应的最新轮次
        for (uint256 i = currentRoundId() + 1; i > 0; i--) {
            uint256 rId = i - 1;
            if (
                rounds[rId].finalized && rounds[rId].finalizedTime <= timepoint
            ) {
                targetRoundId = rId;
                break;
            }
        }

        if (targetRoundId == type(uint256).max) return 0;

        uint256 total = 0;
        uint256 fromRound = targetRoundId > 4 ? targetRoundId - 4 : 0;

        // 动态累加当时有效的合约的总供应量
        for (uint256 r = fromRound; r <= targetRoundId; r++) {
            address token = rounds[r].seatToken;
            if (token != address(0)) {
                total += IVotes(token).getPastTotalSupply(timepoint);
            }
        }
        return total;
    }

    function delegates(address account) public view override returns (address) {
        return account;
    }
    function delegate(address delegatee) public override {}
    function delegateBySig(
        address d,
        uint256 n,
        uint256 e,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public override {}

    // =====================================================
    // 辅助函数
    // =====================================================

    function getRoundSeatToken(
        uint256 roundId
    ) external view returns (address) {
        return rounds[roundId].seatToken;
    }

    function _uintToString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 j = v;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (v != 0) {
            k--;
            bstr[k] = bytes1(uint8(48 + (v % 10)));
            v /= 10;
        }
        return string(bstr);
    }
}
