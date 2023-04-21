// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { AaveLottery } from "../src/AaveLottery.sol";

contract AaveLotteryTest is Test { 
    AaveLottery public main;
    IERC20 public dai;

    address AAVE_POOL_ADDRESS = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address alice = address(1);
    address bob = address(2);
    address charlie = address(3);
    address eve = address(4);

    function setUp() public {
        dai = IERC20(0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063);
        main = new AaveLottery(3600, dai, AAVE_POOL_ADDRESS);
        dai.approve(address(main), type(uint256).max);
    }

    function testLotteryOnlyOne() public { 
        uint256 currentRoundId = main.currentRoundId();
        AaveLottery.Round memory currentRound = main.getRound(currentRoundId);

        // top up alice's account with 10 DAI
        uint256 userStake = 10e18;
        deal(address(dai), alice, userStake);
        // confirms alice has 10 DAI
        assertEq(dai.balanceOf(alice), userStake);
        // switch to alice's account
        vm.startPrank(alice);
        // alice approves 10 DAI to be deposited into AaveLottery
        dai.approve(address(main), userStake);
        // alice enters into the lottery
        main.enter(userStake);
        vm.stopPrank();
        assertEq(dai.balanceOf(alice), 0);

        // Round ends
        vm.warp(currentRound.endTime + 1);

        // Exit 
        vm.prank(alice);
        main.exit(currentRoundId);
        assertEq(dai.balanceOf(alice), userStake);

        // Claim prize
        vm.prank(alice);
        main.claim(currentRoundId);
        assertTrue(dai.balanceOf(alice) > userStake);
    }

    function testLotteryMultiple() public { 
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;

        uint256[] memory usersStake = new uint256[](3);
        usersStake[0] = 10e18;
        usersStake[1] = 200e18;
        usersStake[2] = 30e18;

        uint256 currentRoundId = main.currentRoundId();
        AaveLottery.Round memory currentRound = main.getRound(currentRoundId);

        // Users enter
        for (uint256 i = 0; i < users.length; i++) { 
            vm.startPrank(users[i]);
            deal(address(dai), users[i], usersStake[i]);
            dai.approve(address(main), usersStake[i]);
            main.enter(usersStake[i]);
            vm.stopPrank();
        }

        // Round ends
        vm.warp(currentRound.endTime + 1);

        // Eve enters into next Round
        vm.startPrank(eve);
        deal(address(dai), eve, 10e18);
        dai.approve(address(main), 10e18);
        main.enter(10e18);
        vm.stopPrank();

        // Ensure the next round is triggered once the current round ends
        assertEq(main.currentRoundId(), currentRoundId + 1);

        // Search winner
        AaveLottery.Round memory endedRound = main.getRound(currentRoundId);
        address winner;
        uint256 pointer = 0;
        for (uint256 i = 0; i < users.length; i++) { 
            pointer += usersStake[i];
            if (endedRound.winnerTicket < pointer) { 
                winner = users[i];
                break;
            }
        }

        // Claim prize
        uint256 balanceBefore = dai.balanceOf(winner);
        vm.prank(winner);
        main.claim(currentRoundId);

        // check winner's balance against award
        assertEq(dai.balanceOf(winner) - balanceBefore, endedRound.award);

        // Users exit
        for (uint256 i = 0; i < users.length; i++) { 
            vm.prank(users[i]);
            main.exit(currentRoundId);
            assertTrue(dai.balanceOf(users[i]) >= usersStake[i]);
        }
    }
}