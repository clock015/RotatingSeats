// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/TokenA.sol";
import "../src/SeatToken.sol";
import "../src/SeatTokenFactory.sol";
import "../src/ProportionalElection.sol";

contract ProportionalElectionTest is Test {
    TokenA tokenA;
    SeatTokenFactory factory;
    ProportionalElection election;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    uint256 constant E18 = 1e18;
    uint256 constant SEATS_PER_ROUND = 200 * E18;

    function setUp() public {
        // 1. 部署 TokenA
        tokenA = new TokenA(); // 默认给部署者(this) 100万个

        // 2. 部署工厂
        factory = new SeatTokenFactory();

        // 3. 部署选举合约
        election = new ProportionalElection(address(tokenA), address(factory));

        // 4. 重要：给工厂授权
        factory.setElectionContract(address(election));

        // 5. 给测试角色分发 TokenA
        tokenA.transfer(alice, 10000 * E18);
        tokenA.transfer(bob, 10000 * E18);
        tokenA.transfer(charlie, 10000 * E18);

        // 6. 预授权
        vm.prank(alice);
        tokenA.approve(address(election), type(uint256).max);
        vm.prank(bob);
        tokenA.approve(address(election), type(uint256).max);
    }

    // --- 基础逻辑测试 ---

    function test_InitialState() public {
        assertEq(election.currentRoundId(), 0);
        assertTrue(election.isVotingPeriod());
    }

    function test_VoteAndBurn() public {
        uint256 initialBal = tokenA.balanceOf(alice);

        vm.prank(alice);
        election.vote(alice, 100 * E18);

        assertEq(tokenA.balanceOf(alice), initialBal - 100 * E18);
        // 总供应量也应下降
    }

    // --- 比例分配测试 ---

    function test_ProportionalClaim() public {
        // Alice 投 100 票给自己
        vm.prank(alice);
        election.vote(alice, 100 * E18);

        // Bob 投 300 票给自己
        vm.prank(bob);
        election.vote(bob, 300 * E18);

        // 结束投票期 (7天后)
        vm.warp(block.timestamp + 8 days);

        // 结算第 0 轮
        election.finalizeRound(0);

        // Alice 领取
        election.claimSeats(0, alice);
        // Bob 领取
        election.claimSeats(0, bob);

        address seatToken0 = election.getRoundSeatToken(0);

        // 总票数 400，Alice 占 1/4 = 50 席，Bob 占 3/4 = 150 席
        assertEq(SeatToken(seatToken0).balanceOf(alice), 50 * E18);
        assertEq(SeatToken(seatToken0).balanceOf(bob), 150 * E18);

        // 检查自动 Delegate 是否生效
        assertEq(SeatToken(seatToken0).getVotes(alice), 50 * E18);
    }

    // --- 聚合投票权测试 ---

    function test_AggregationAcrossRounds() public {
        // 第一年：Alice 获得 200 席
        _oneFullElection(alice, 100 * E18);

        // 跳到第二年
        vm.warp(election.genesisTime() + 360 days);

        // 第二年：Alice 再次获得 200 席
        _oneFullElection(alice, 100 * E18);

        // 此时 Alice 总投票权应为 400
        assertEq(election.getVotes(alice), 400 * E18);
    }

    // --- 5年轮替测试 (核心) ---

    function test_RotationAfterFiveYears() public {
        // 循环 6 年
        for (uint256 i = 0; i < 6; i++) {
            vm.warp(election.genesisTime() + (i * 360 days));
            _oneFullElection(alice, 100 * E18);
        }

        // 第 6 年选举结束后，第 1 年 (Round 0) 的席位应该被踢出聚合范围
        // Alice 在每一轮都拿满 200 席。
        // 第 6 年时，她手里有 Round 0, 1, 2, 3, 4, 5。
        // 但聚合器只认 1, 2, 3, 4, 5。
        // 所以总票数应为 1000 * E18，而不是 1200。
        assertEq(election.getVotes(alice), 1000 * E18);
    }

    // --- 历史查询修复测试 (最难的部分) ---

    function test_PastVotesHistoryAware() public {
        // 1. 第一年选举 (Round 0)
        _oneFullElection(alice, 100 * E18);
        uint256 snapshotTime1 = block.timestamp;

        // 2. 第二年选举 (Round 1)
        // 修复点：直接跳转到 genesisTime + 360 days，确保落在窗口起始点
        vm.warp(election.genesisTime() + 360 days);
        _oneFullElection(alice, 100 * E18);

        // 3. 此时实时票数是 400
        assertEq(election.getVotes(alice), 400 * E18);

        // 4. 查询第一年快照时的票数，应该是 200
        assertEq(election.getPastVotes(alice, snapshotTime1), 200 * E18);

        // 5. 模拟后续 4 年
        for (uint256 i = 2; i < 6; i++) {
            // 修复点：同样使用绝对路径跳转
            vm.warp(election.genesisTime() + (i * 360 days));
            _oneFullElection(alice, 100 * E18);
        }

        // 6. 验证 6 年后的历史追溯
        assertEq(election.getPastVotes(alice, snapshotTime1), 200 * E18);
    }

    // --- 异常情况测试 ---

    function test_CannotVoteOutsideWindow() public {
        vm.warp(block.timestamp + 10 days); // 超过 7 天
        vm.prank(alice);
        vm.expectRevert("Voting closed");
        election.vote(alice, 100 * E18);
    }

    function test_OnlyFactoryAuthorized() public {
        // 尝试绕过选举合约直接调工厂
        vm.prank(alice);
        vm.expectRevert();
        factory.createSeatToken("Fake", "FK", alice);
    }

    // --- 工具函数：完成一轮完整的选举流程 ---
    function _oneFullElection(address winner, uint256 amount) internal {
        uint256 rId = election.currentRoundId();

        vm.prank(winner);
        election.vote(winner, amount);

        vm.warp(block.timestamp + 8 days);
        election.finalizeRound(rId);
        election.claimSeats(rId, winner);
    }
}
