// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/SeatToken.sol";
import "../src/SeatTokenFactory.sol";
import "../src/ProportionalElection.sol";
import "../src/interfaces/ISeatToken.sol";

contract ProportionalElectionTest is Test {
    SeatTokenFactory factory;
    ProportionalElection election;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant WEIGHT_PER_YEAR = 100 * 1e18;
    uint256 constant E18 = 1e18;
    uint256 constant CYCLE = 365 days;
    uint256 constant BUFFER = 30 days;

    function setUp() public {
        factory = new SeatTokenFactory();

        // 更新点：构造函数现在需要两个参数。
        // 将测试合约本身 (address(this)) 设置为 minter，以便后续直接调用 election.mint
        election = new ProportionalElection(address(factory), address(this));

        factory.setElectionContract(address(election));
    }

    // =====================================================
    // 1. 缓冲期逻辑测试
    // =====================================================
    function test_BufferPeriodGovernanceDelay() public {
        // --- 第一年 (Round 0) ---
        // 调用者是 address(this)，即 minter，权限检查通过
        election.mint(alice, 100 * E18);

        // 在前30天内，结果应为 0
        assertEq(election.getVotes(alice), 0);

        // 跳到第31天，Round 0 正式生效
        vm.warp(election.genesisTime() + BUFFER + 1 days);
        assertEq(election.getVotes(alice), 100 * E18);

        // --- 第二年 (Round 1) ---
        vm.warp(election.genesisTime() + CYCLE + 10 days);

        // minter 继续为 Alice 铸造
        election.mint(alice, 500 * E18);

        // 验证缓冲期内第二年不产生权重
        assertEq(election.getVotes(alice), 100 * E18);

        // 跳到第二年第31天
        vm.warp(election.genesisTime() + CYCLE + BUFFER + 1 days);

        // 权重上线，总计 200 票
        assertEq(election.getVotes(alice), 200 * E18);
    }

    // =====================================================
    // 2. 跨年抗稀释与轮替测试 (带缓冲期偏移)
    // =====================================================
    function test_RollingWindowWithBuffer() public {
        // 模拟连续 6 年的 Mint
        for (uint256 i = 0; i < 6; i++) {
            vm.warp(election.genesisTime() + (i * CYCLE) + 31 days);
            election.mint(alice, 100 * E18);
        }

        // 第 6 年第 31 天，活跃轮次应为 1-5，总票数 500
        assertEq(election.getVotes(alice), 500 * E18);

        // 回退到第 6 年的第 10 天（缓冲期内）
        uint256 timeInSixYearBuffer = election.genesisTime() +
            (5 * CYCLE) +
            10 days;
        vm.warp(timeInSixYearBuffer);

        // 验证：在缓冲期内，权力仍由旧届 [0-4] 组成
        assertEq(election.getVotes(alice), 500 * E18);

        // 验证过去的时间点（确保避开未来的 Checkpoint）
        assertEq(
            election.getPastVotes(alice, timeInSixYearBuffer - 1),
            500 * E18
        );
    }

    // =====================================================
    // 3. 历史溯源测试
    // =====================================================
    function test_PastVotesHistoricalRange() public {
        // 第一年 Mint
        vm.warp(election.genesisTime() + 40 days);
        election.mint(alice, 100 * E18);
        uint256 timeAliceOnly = block.timestamp;

        // 让时间流逝，确保 timeAliceOnly 变为“过去”
        vm.warp(block.timestamp + 1);

        // 第二年 Mint
        vm.warp(election.genesisTime() + CYCLE + 40 days);
        election.mint(bob, 100 * E18);

        // 验证实时
        assertEq(election.getVotes(alice), 100 * E18);
        assertEq(election.getVotes(bob), 100 * E18);

        // 验证历史
        assertEq(election.getPastVotes(alice, timeAliceOnly), 100 * E18);
        assertEq(election.getPastVotes(bob, timeAliceOnly), 0);
    }

    // =====================================================
    // 4. 委派同步测试
    // =====================================================
    function test_DelegateSyncAcrossSixRounds() public {
        for (uint256 i = 0; i < 6; i++) {
            vm.warp(election.genesisTime() + (i * CYCLE) + 40 days);
            election.mint(alice, 10 * E18);
        }

        // Alice 委派给 Bob（delegate 函数不限制调用者，仅限制 delegator 身份）
        vm.prank(alice);
        election.delegate(bob);

        assertEq(election.getVotes(alice), 0);
        assertEq(election.getVotes(bob), 500 * E18);

        (address token0, ) = election.rounds(0);
        assertEq(IVotes(token0).delegates(alice), bob);
    }

    // =====================================================
    // 5. 归一化稀释测试
    // =====================================================
    function test_NormalizationInSameYear() public {
        vm.warp(election.genesisTime() + 40 days);

        election.mint(alice, 100 * E18);
        assertEq(election.getVotes(alice), 100 * E18);

        election.mint(bob, 300 * E18);

        assertEq(election.getVotes(alice), 25 * E18);
        assertEq(election.getVotes(bob), 75 * E18);
    }

    // =====================================================
    // 6. 签名委派测试 (EIP-712)
    // =====================================================
    function test_DelegateBySig() public {
        uint256 pk = 0xA11CE;
        address user = vm.addr(pk);

        vm.warp(election.genesisTime() + 40 days);
        election.mint(user, 100 * E18);

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Delegation(address delegatee,uint256 nonce,uint256 expiry)"
                ),
                bob,
                election.nonces(user),
                block.timestamp + 1 days
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                election.DOMAIN_SEPARATOR(),
                structHash
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        // 任何地址都可以提交签名交易
        election.delegateBySig(
            bob,
            election.nonces(user),
            block.timestamp + 1 days,
            v,
            r,
            s
        );

        assertEq(election.delegates(user), bob);
        assertEq(election.getVotes(bob), 100 * E18);
    }

    // =====================================================
    // 7. 权限测试 (新增)
    // =====================================================
    function test_MintUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert("ProportionalElection: only minter");
        election.mint(bob, 100 * E18);
    }
}
