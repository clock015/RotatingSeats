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
    uint256 constant CYCLE = 360 days;
    uint256 constant BUFFER = 30 days;

    function setUp() public {
        factory = new SeatTokenFactory();
        election = new ProportionalElection(address(factory));
        factory.setElectionContract(address(election));
    }

    // =====================================================
    // 1. 缓冲期逻辑测试 (核心新增)
    // =====================================================
    function test_BufferPeriodGovernanceDelay() public {
        // --- 第一年 (Round 0) ---
        // 初始第1天 Mint
        election.mint(alice, 100 * E18);

        // 在前30天内，因为还没有“旧轮次”，且新轮次在缓冲期，此时 getVotes 应为 0
        assertEq(election.getVotes(alice), 0);

        // 跳到第31天，Round 0 正式生效
        vm.warp(election.genesisTime() + BUFFER + 1 days);
        assertEq(election.getVotes(alice), 100 * E18);

        // --- 第二年 (Round 1) ---
        // 跳到第二年第10天 (此时处于第二年的缓冲期)
        vm.warp(election.genesisTime() + CYCLE + 10 days);

        // Alice 在新的一年 Mint 更多
        election.mint(alice, 500 * E18);

        // 验证：在缓冲期内，第二年的 Mint 不产生权重，治理权仍完全由第一年提供
        // Alice 只有第一年的 100 票
        assertEq(election.getVotes(alice), 100 * E18);

        // 跳到第二年第31天
        vm.warp(election.genesisTime() + CYCLE + BUFFER + 1 days);

        // 验证：此时第二年权重上线。
        // Alice 在第一年占 100% (100票)，在第二年也占 100% (100票) -> 总 200 票
        assertEq(election.getVotes(alice), 200 * E18);
    }

    // =====================================================
    // 2. 跨年抗稀释与轮替测试 (带缓冲期偏移)
    // =====================================================
    function test_RollingWindowWithBuffer() public {
        // 模拟连续 6 年的 Mint (每年 Alice 100% 份额)
        for (uint256 i = 0; i < 6; i++) {
            vm.warp(election.genesisTime() + (i * CYCLE) + 31 days);
            election.mint(alice, 100 * E18);
        }

        // 此时是第 6 年第 31 天。
        // 活跃轮次应该是：Round 5, 4, 3, 2, 1 (Round 0 应该被踢出)
        // 总票数应为 500
        assertEq(election.getVotes(alice), 500 * E18);

        // 回退到第 6 年的第 10 天（缓冲期内）
        vm.warp(election.genesisTime() + (5 * CYCLE) + 10 days);

        // 验证：在第 6 年的缓冲期，权力结构应该还没变，仍由 [4, 3, 2, 1, 0] 组成
        assertEq(election.getVotes(alice), 500 * E18);

        // 我们可以通过查询 PastVotes 来验证这一点
        uint256 timeInSixYearBuffer = election.genesisTime() +
            (5 * CYCLE) +
            10 days;
        assertEq(
            election.getPastVotes(alice, timeInSixYearBuffer - 1),
            500 * E18
        );
    }

    // =====================================================
    // 3. 历史溯源测试 (验证 Range 计算是否准确)
    // =====================================================
    function test_PastVotesHistoricalRange() public {
        // 第一年 Mint 并生效
        vm.warp(election.genesisTime() + 40 days);
        election.mint(alice, 100 * E18);
        uint256 timeAliceOnly = block.timestamp;

        // 第二年 Mint 并生效
        vm.warp(election.genesisTime() + CYCLE + 40 days);
        election.mint(bob, 100 * E18);

        // 此时：Alice 100, Bob 100
        assertEq(election.getVotes(alice), 100 * E18);
        assertEq(election.getVotes(bob), 100 * E18);

        // 查回第一年的时间点
        assertEq(election.getPastVotes(alice, timeAliceOnly), 100 * E18);
        assertEq(election.getPastVotes(bob, timeAliceOnly), 0);
    }

    // =====================================================
    // 4. 委派同步测试 (覆盖 6 轮同步)
    // =====================================================
    function test_DelegateSyncAcrossSixRounds() public {
        // Alice 在 6 个轮次里都有代币（为了测试同步逻辑是否覆盖了足够范围）
        for (uint256 i = 0; i < 6; i++) {
            vm.warp(election.genesisTime() + (i * CYCLE) + 40 days);
            election.mint(alice, 10 * E18);
        }

        // Alice 委派给 Bob
        vm.prank(alice);
        election.delegate(bob);

        // 验证当前活跃的 5 届全部同步了委派
        assertEq(election.getVotes(alice), 0);
        assertEq(election.getVotes(bob), 500 * E18);

        // 验证即便最老的那一届（已不在 active 范围，但在 current-5 范围内）也同步了
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

        // Bob 进入同一年，Mint 了 300
        election.mint(bob, 300 * E18);

        // 总 400. Alice 占 1/4 -> 25 票，Bob 占 3/4 -> 75 票
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
}
