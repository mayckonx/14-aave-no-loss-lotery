// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import { IPool } from "aave-v3-core/contracts/interfaces/IPool.sol";
import { IAToken } from "aave-v3-core/contracts/interfaces/IAToken.sol";
import { DataTypes } from "aave-v3-core/contracts/protocol/libraries/types/DataTypes.sol";
import { WadRayMath } from "aave-v3-core/contracts/protocol/libraries/math/WadRayMath.sol";

contract AaveLottery { 
    using SafeERC20 for IERC20;
    using WadRayMath for uint256;

    struct Round { 
        uint256 endTime;
        uint256 totalStake;
        uint256 award;
        uint256 winnerTicket;
        uint256 scaledBalanceStake;
        address winner;
    }

    struct Ticket { 
        uint256 stake;
        uint256 segmentStart;
        bool exited;
    }

    uint256 public roundDuration; // seconds
    uint256 public currentRoundId; // starts from 1
    IERC20 public underlying; // asset to be deposited into Aave
    IPool private aave;
    IAToken private aToken;

    // roundId => Round
    mapping(uint256 => Round) public rounds;

    // roundId => userAddress => Ticket
    mapping(uint256 => mapping(address => Ticket)) public tickets;
    
    constructor(
        uint256 _roundDuration,
        IERC20 _underlying,
        address _aavePool
        ) { 
        roundDuration = _roundDuration;
        underlying = IERC20(_underlying);
        aave = IPool(_aavePool);
        DataTypes.ReserveData memory data = aave.getReserveData(address(underlying));
        require(data.aTokenAddress != address(0), 'INVALID_AAVE_POOL');
        aToken = IAToken(data.aTokenAddress);

        underlying.approve(address(_aavePool), type(uint256).max);

        // Init the first round
        rounds[currentRoundId] = Round({
            endTime: block.timestamp + roundDuration,
            totalStake: 0,
            award: 0,
            winnerTicket: 0,
            scaledBalanceStake: 0,
            winner: address(0)
        });
    }

    function getRound(uint256 roundId) external view returns (Round memory) { 
        return rounds[roundId];
    }

    function getTicket(uint256 roundId, address user) external view returns (Ticket memory) { 
        return tickets[roundId][user];
    }

    function enter(uint256 amount) external { 
        // Checks
        require(tickets[currentRoundId][msg.sender].stake == 0, 'USER_ALREADY_PARTICIPATED');

        // Update
        _updateState();
        // User enters
        // range: [totalStake, totalStake + amount]
        tickets[currentRoundId][msg.sender].segmentStart = rounds[currentRoundId].totalStake;
        tickets[currentRoundId][msg.sender].stake = amount;
        rounds[currentRoundId].totalStake += amount;

        // Transfer funds in - user must approve this contract
        underlying.safeTransferFrom(msg.sender, address(this), amount);

        // Deposit funds into Aaave Pool
        uint256 scaledBalanceStakeBefore = aToken.scaledBalanceOf(address(this));
        aave.deposit(address(underlying), amount, address(this), 0);
        uint256 scaledBalanceStakeAfter = aToken.scaledBalanceOf(address(this));

        rounds[currentRoundId].scaledBalanceStake += scaledBalanceStakeAfter - scaledBalanceStakeBefore;
    }

    function exit(uint256 roundId) external {
        // Checks
        require(tickets[currentRoundId][msg.sender].exited == false, 'USER_ALREADY_EXITED'); 

        _updateState();

        require(roundId < currentRoundId, 'CURRENT_LOTTERY');

        // User exits 
        uint256 amount = tickets[roundId][msg.sender].stake;
        tickets[roundId][msg.sender].exited = true;

        rounds[roundId].totalStake -= amount;

        // Transfer funds from the contract to the user
        underlying.safeTransfer(msg.sender, amount);

    }

    function claim(uint256 roundId) external { 
        // Checks
        require(roundId < currentRoundId, 'CURRENT_LOTTERY');
        Ticket memory ticket = tickets[roundId][msg.sender];
        Round memory round = rounds[roundId];

        // check if the user is within the segment of the winner
        require(round.winnerTicket - ticket.segmentStart < ticket.stake, 'NOT_WINNER');
        require(round.winner == address(0), 'ALREADY_CLAIMED');
        round.winner = msg.sender;

        // Checks winner
        // Transfer jackpot to the winner
        underlying.safeTransfer(msg.sender, round.award);
    }

    function _drawWinner(uint256 total) internal view returns(uint256) { 
        uint256 random = uint256(keccak256(
            abi.encodePacked(
                block.timestamp,
                rounds[currentRoundId].totalStake,
                currentRoundId))
            );
        
        return random % total;
    }

    function _updateState() internal { 
        if (block.timestamp > rounds[currentRoundId].endTime) { 
            // award - aave withdraw
            // scaledBalance * index = total amount of aTokens
            uint256 index = aave.getReserveNormalizedIncome(address(underlying));
            uint256 aTokenBalance = rounds[currentRoundId].scaledBalanceStake.rayMul(index);
            uint256 aaveAmount = aave.withdraw(address(underlying), aTokenBalance, address(this));

            rounds[currentRoundId].award = aaveAmount - rounds[currentRoundId].totalStake;

            // Lottery draw
           rounds[currentRoundId].winnerTicket = _drawWinner(rounds[currentRoundId].totalStake);

            // Create a new round
            currentRoundId += 1;
            rounds[currentRoundId].endTime = block.timestamp + roundDuration;
        }
    }
}