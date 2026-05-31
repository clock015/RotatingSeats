// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/governance/utils/IVotes.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/Nonces.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./interfaces/ISeatToken.sol";
import "./interfaces/ISeatTokenFactory.sol";

/**
 * @title ProportionalElection
 * @notice 动态权重治理聚合器：
 * 1. 每一年的总治理权重被归一化为 100 票。
 * 2. 采用 5 年滑动窗口，总治理权上限为 500 票。
 * 3. 每一轮次（365天）的前 30 天为“积累缓冲期”，该轮次的权重暂不计入总投票权。
 */
contract ProportionalElection is IVotes, EIP712, Nonces {
    // --- 常量定义 ---
    uint256 public constant CYCLE_DURATION = 365 days;
    uint256 public constant BUFFER_DURATION = 30 days;
    uint256 public constant WEIGHT_PER_YEAR = 100 * 1e18; // 归一化基准
    uint256 public constant MAX_ACTIVE_ROUNDS = 5; // 活跃窗口长度

    // --- 状态变量 ---
    ISeatTokenFactory public immutable seatFactory;
    uint256 public immutable genesisTime;
    address public immutable minter; // 权限：铸造执行者

    struct Round {
        address seatToken;
        bool initialized;
    }

    mapping(uint256 => Round) public rounds;
    mapping(address => address) private _userDelegates;

    bytes32 private constant DELEGATION_TYPEHASH =
        keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

    // --- 事件 ---
    event RoundInitialized(uint256 indexed roundId, address tokenAddress);
    event SeatMinted(
        uint256 indexed roundId,
        address indexed to,
        uint256 amount
    );

    constructor(
        address _factory,
        address _minter
    ) EIP712("ProportionalElection", "1") {
        seatFactory = ISeatTokenFactory(_factory);
        minter = _minter;
        genesisTime = block.timestamp;
    }

    // =============================================================
    //                      核心 Mint 逻辑
    // =============================================================

    /**
     * @notice 在当前轮次铸造席位
     * @param to 接收者地址
     * @param amount 原始份额数量（将被归一化）
     */
    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "ProportionalElection: only minter");
        uint256 rId = currentRoundId();

        if (!rounds[rId].initialized) {
            _initializeRound(rId);
        }

        ISeatToken(rounds[rId].seatToken).mint(to, amount);

        // 同步用户在聚合层设置的委派选择
        address currentDel = _userDelegates[to];
        if (currentDel != address(0) && currentDel != to) {
            ISeatToken(rounds[rId].seatToken).forceDelegate(to, currentDel);
        }

        emit SeatMinted(rId, to, amount);
    }

    function _initializeRound(uint256 rId) internal {
        address newToken = seatFactory.createSeatToken(
            string(abi.encodePacked("Council Seat ", _uintToString(rId))),
            "CS",
            address(this)
        );
        rounds[rId].seatToken = newToken;
        rounds[rId].initialized = true;
        emit RoundInitialized(rId, newToken);
    }

    // =============================================================
    //                      滑动窗口与权重数学
    // =============================================================

    /**
     * @notice 计算指定时间点下起效的轮次区间
     * @dev 逻辑：
     * 1. 确定时间点所属的 rId 和 周期内偏移。
     * 2. 若在每年的前 30 天，则不计入当前 rId，使用 (rId-1) 作为窗口末端。
     * 3. 窗口大小固定为最近的 5 届有效合约。
     * @return startId 窗口起始轮次
     * @return endId 窗口结束轮次
     */
    function getActiveRange(
        uint256 timepoint
    ) public view returns (uint256 startId, uint256 endId) {
        if (timepoint < genesisTime) return (1, 0); // 返回无效区间

        uint256 elapsed = timepoint - genesisTime;
        uint256 rId = elapsed / CYCLE_DURATION;
        uint256 offset = elapsed % CYCLE_DURATION;

        // 处理缓冲期偏移
        if (offset < BUFFER_DURATION) {
            // 系统启动的前 30 天，没有任何席位生效
            if (rId == 0) return (1, 0);
            endId = rId - 1;
        } else {
            endId = rId;
        }

        // 追溯过去 4 届，总共包含 5 届
        startId = endId >= (MAX_ACTIVE_ROUNDS - 1)
            ? endId - (MAX_ACTIVE_ROUNDS - 1)
            : 0;
    }

    /**
     * @dev 核心数学公式：(原始票数 * 100) / 年度总发行量
     */
    function _normalize(
        uint256 amount,
        uint256 supply
    ) internal pure returns (uint256) {
        if (supply == 0 || amount == 0) return 0;
        return (amount * WEIGHT_PER_YEAR) / supply;
    }

    // =============================================================
    //                      IVotes 聚合实现
    // =============================================================

    function getVotes(address account) public view override returns (uint256) {
        (uint256 start, uint256 end) = getActiveRange(block.timestamp);
        if (start > end) return 0;

        uint256 totalWeight = 0;
        for (uint256 r = start; r <= end; r++) {
            address token = rounds[r].seatToken;
            if (token != address(0)) {
                totalWeight += _normalize(
                    IVotes(token).getVotes(account),
                    IERC20(token).totalSupply()
                );
            }
        }
        return totalWeight;
    }

    function getPastVotes(
        address account,
        uint256 timepoint
    ) public view override returns (uint256) {
        (uint256 start, uint256 end) = getActiveRange(timepoint);
        if (start > end) return 0;

        uint256 totalWeight = 0;
        for (uint256 r = start; r <= end; r++) {
            address token = rounds[r].seatToken;
            if (token != address(0)) {
                totalWeight += _normalize(
                    IVotes(token).getPastVotes(account, timepoint),
                    IVotes(token).getPastTotalSupply(timepoint)
                );
            }
        }
        return totalWeight;
    }

    function getPastTotalSupply(
        uint256 timepoint
    ) public view override returns (uint256) {
        (uint256 start, uint256 end) = getActiveRange(timepoint);
        if (start > end) return 0;

        uint256 activeCount = 0;
        for (uint256 r = start; r <= end; r++) {
            if (rounds[r].initialized) activeCount++;
        }
        return activeCount * WEIGHT_PER_YEAR;
    }

    // =============================================================
    //                      委派与签名传播
    // =============================================================

    function delegate(address delegatee) public override {
        _delegate(msg.sender, delegatee);
    }

    function delegates(address account) public view override returns (address) {
        return _userDelegates[account];
    }

    function delegateBySig(
        address delegatee,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public override {
        require(block.timestamp <= expiry, "Signature expired");
        bytes32 structHash = keccak256(
            abi.encode(DELEGATION_TYPEHASH, delegatee, nonce, expiry)
        );
        bytes32 hash = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(hash, v, r, s);
        _useCheckedNonce(signer, nonce);
        _delegate(signer, delegatee);
    }

    function _delegate(address delegator, address delegatee) internal {
        address oldDelegate = _userDelegates[delegator];
        _userDelegates[delegator] = delegatee;

        uint256 cur = currentRoundId();
        // 路由至可能活跃的最近 6 轮，确保在缓冲期和正式期交替时委派均有效
        uint256 start = cur >= MAX_ACTIVE_ROUNDS ? cur - MAX_ACTIVE_ROUNDS : 0;

        for (uint256 r = start; r <= cur; r++) {
            address token = rounds[r].seatToken;
            if (token != address(0)) {
                ISeatToken(token).forceDelegate(delegator, delegatee);
            }
        }
        emit DelegateChanged(delegator, oldDelegate, delegatee);
    }

    // =============================================================
    //                      工具函数与治理接口
    // =============================================================

    function currentRoundId() public view returns (uint256) {
        return (block.timestamp - genesisTime) / CYCLE_DURATION;
    }

    function clock() public view returns (uint48) {
        return uint48(block.timestamp);
    }

    function CLOCK_MODE() public view returns (string memory) {
        return "mode=timestamp";
    }

    function nonces(address owner) public view override returns (uint256) {
        return super.nonces(owner);
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
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
