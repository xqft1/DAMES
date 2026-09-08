// SPDX-License-Identifier: MIT

/*
    DAMES
    21,000,000 MAX SUPPLY

    Mint DAMES with ETH.
    Stake DAMES/ETH LP.
    Earn ETH from minting rewards.

    Robinhood Chain

    https://nlm4t-jaaaa-aaaab-qhg4a-cai.icp0.io/
*/

pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title DamesBounty
 * @notice Stakes DAMES/ETH LP tokens and distributes ETH received from
 *         DamesBreeches to LP stakers over a 7 day rolling stream.
 *
 * Security design:
 * - Only the immutable DamesBreeches contract can fund rewards.
 * - Rewards are funded atomically using msg.value.
 * - There is no separate "amount" parameter to fake.
 * - No owner function can withdraw staked LP.
 * - No owner function can withdraw reward ETH.
 * - Withdrawals and claims remain available while paused.
 * - Rewards received with zero stakers are queued.
 * - When the final staker leaves, the remaining stream is frozen and queued.
 * - Reentrancy protection applies to all state-changing asset flows.
 */
contract DamesBounty is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant REWARD_DURATION = 7 days;
    uint256 public constant PRECISION = 1e18;

    /// @notice DAMES/ETH Uniswap V2 LP token.
    IERC20 public immutable lpToken;

    /// @notice Sole contract authorised to fund ETH rewards.
    address public immutable damesBreeches;

    /// -----------------------------------------------------------------------
    /// Staking state
    /// -----------------------------------------------------------------------

    uint256 public totalStaked;

    mapping(address => uint256) public balanceOf;

    /// -----------------------------------------------------------------------
    /// Reward state
    /// -----------------------------------------------------------------------

    uint256 public rewardRate;
    uint256 public periodFinish;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    /**
     * @notice Rewards waiting to be streamed.
     *
     * This includes:
     * - rewards received while nobody is staking;
     * - undistributed rewards frozen when the last staker leaves;
     * - tiny rounding remainder from stream calculations.
     */
    uint256 public queuedRewards;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    /// @notice Total ETH ever accepted from DamesBreeches.
    uint256 public totalRewardsFunded;

    /// @notice Total ETH successfully paid to stakers.
    uint256 public totalRewardsClaimed;

    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------

    event Staked(address indexed account, uint256 amount);

    event Withdrawn(address indexed account, uint256 amount);

    event RewardPaid(address indexed account, address indexed recipient, uint256 amount);

    event RewardsFunded(uint256 amount, uint256 totalRewardsFunded);

    event RewardStreamUpdated(uint256 rewardRate, uint256 periodFinish, uint256 queuedRewards);

    event RewardsFrozen(uint256 amountQueued);

    /// -----------------------------------------------------------------------
    /// Errors
    /// -----------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error NotDamesBreeches();
    error InsufficientStake();
    error RewardTransferFailed();
    error RewardAccountingInsolvent();

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------

    constructor(address _lpToken, address _damesBreeches, address _owner) Ownable(_owner) {
        if (_lpToken == address(0) || _damesBreeches == address(0) || _owner == address(0)) {
            revert ZeroAddress();
        }

        lpToken = IERC20(_lpToken);
        damesBreeches = _damesBreeches;
    }

    /// -----------------------------------------------------------------------
    /// Modifiers
    /// -----------------------------------------------------------------------

    modifier onlyDamesBreeches() {
        if (msg.sender != damesBreeches) {
            revert NotDamesBreeches();
        }
        _;
    }

    /// -----------------------------------------------------------------------
    /// Reward views
    /// -----------------------------------------------------------------------

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }

        uint256 applicable = lastTimeRewardApplicable();

        if (applicable <= lastUpdateTime) {
            return rewardPerTokenStored;
        }

        uint256 elapsed = applicable - lastUpdateTime;

        uint256 additionalRewardPerToken = Math.mulDiv(elapsed * rewardRate, PRECISION, totalStaked);

        return rewardPerTokenStored + additionalRewardPerToken;
    }

    function earned(address account) public view returns (uint256) {
        uint256 accrued = Math.mulDiv(balanceOf[account], rewardPerToken() - userRewardPerTokenPaid[account], PRECISION);

        return rewards[account] + accrued;
    }

    /**
     * @notice ETH funded by Breeches that has not yet been claimed.
     *
     * Includes both streamed/unclaimed ETH and undistributed/queued ETH.
     */
    function outstandingRewards() public view returns (uint256) {
        return totalRewardsFunded - totalRewardsClaimed;
    }

    /// -----------------------------------------------------------------------
    /// Funding
    /// -----------------------------------------------------------------------

    /**
     * @notice Receives ETH rewards directly from DamesBreeches.
     *
     * The ETH amount is msg.value itself. There is deliberately no supplied
     * rewardAmount argument.
     */
    function fundRewards() external payable onlyDamesBreeches whenNotPaused nonReentrant {
        if (msg.value == 0) {
            revert ZeroAmount();
        }

        _updateReward(address(0));

        totalRewardsFunded += msg.value;

        /*
         * Nobody staking:
         *
         * Do not let rewards disappear and do not begin a stream that nobody
         * can receive. Hold the entire deposit in queuedRewards.
         */
        if (totalStaked == 0) {
            queuedRewards += msg.value;

            emit RewardsFunded(msg.value, totalRewardsFunded);

            _checkSolvency();
            return;
        }

        uint256 rewardsToStream = msg.value + queuedRewards;

        /*
         * If an existing reward period is running, carry its undistributed
         * ETH into the new 7 day stream.
         */
        if (block.timestamp < periodFinish) {
            uint256 remainingTime = periodFinish - block.timestamp;
            uint256 remainingRewards = remainingTime * rewardRate;

            rewardsToStream += remainingRewards;
        }

        _startRewardStream(rewardsToStream);

        emit RewardsFunded(msg.value, totalRewardsFunded);

        _checkSolvency();
    }

    /// -----------------------------------------------------------------------
    /// Staking
    /// -----------------------------------------------------------------------

    function stake(uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) {
            revert ZeroAmount();
        }

        _updateReward(msg.sender);

        /*
         * Effects before interaction.
         */
        balanceOf[msg.sender] += amount;
        totalStaked += amount;

        /*
         * Standard Uniswap V2 LP tokens do not charge transfer fees.
         */
        lpToken.safeTransferFrom(msg.sender, address(this), amount);

        /*
         * If rewards accumulated while nobody was staking, the first stake
         * starts a fresh 7 day stream instead of receiving them instantly.
         */
        if (rewardRate == 0 && queuedRewards >= REWARD_DURATION) {
            _startRewardStream(queuedRewards);
        }

        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert ZeroAmount();
        }

        if (balanceOf[msg.sender] < amount) {
            revert InsufficientStake();
        }

        _updateReward(msg.sender);

        /*
         * Effects before interaction.
         */
        balanceOf[msg.sender] -= amount;
        totalStaked -= amount;

        /*
         * If the last LP leaves, stop the reward clock.
         *
         * Undistributed ETH is queued until LP is staked again.
         */
        if (totalStaked == 0) {
            _freezeRewardStream();
        }

        lpToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    /// -----------------------------------------------------------------------
    /// Claims
    /// -----------------------------------------------------------------------

    function claim() external nonReentrant returns (uint256 reward) {
        reward = _claim(msg.sender, payable(msg.sender));
    }

    /**
     * @notice Allows contracts that cannot receive ETH themselves to direct
     *         their reward to another address.
     */
    function claimTo(address payable recipient) external nonReentrant returns (uint256 reward) {
        if (recipient == address(0)) {
            revert ZeroAddress();
        }

        reward = _claim(msg.sender, recipient);
    }

    /// -----------------------------------------------------------------------
    /// Emergency controls
    /// -----------------------------------------------------------------------

    /**
     * @notice Pausing blocks new staking and new reward funding.
     *
     * It deliberately does NOT block withdrawals or reward claims.
     *
     * Because DamesBreeches funding is atomic, a paused bounty will also
     * cause a Breeches mint transaction to revert rather than trapping ETH.
     */
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// -----------------------------------------------------------------------
    /// Internal reward accounting
    /// -----------------------------------------------------------------------

    function _updateReward(address account) internal {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();

        if (account != address(0)) {
            rewards[account] = earned(account);

            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
    }

    function _startRewardStream(uint256 amount) internal {
        /*
         * Integer division can leave less than REWARD_DURATION wei behind.
         * Keep that tiny remainder explicitly queued rather than losing track
         * of it.
         */
        uint256 newRewardRate = amount / REWARD_DURATION;

        if (newRewardRate == 0) {
            queuedRewards = amount;
            rewardRate = 0;
            periodFinish = block.timestamp;
            lastUpdateTime = block.timestamp;

            emit RewardStreamUpdated(rewardRate, periodFinish, queuedRewards);

            return;
        }

        uint256 streamAmount = newRewardRate * REWARD_DURATION;

        queuedRewards = amount - streamAmount;
        rewardRate = newRewardRate;

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + REWARD_DURATION;

        emit RewardStreamUpdated(rewardRate, periodFinish, queuedRewards);
    }

    function _freezeRewardStream() internal {
        uint256 remainingRewards;

        if (rewardRate != 0 && block.timestamp < periodFinish) {
            remainingRewards = (periodFinish - block.timestamp) * rewardRate;

            queuedRewards += remainingRewards;
        }

        rewardRate = 0;
        periodFinish = block.timestamp;
        lastUpdateTime = block.timestamp;

        emit RewardsFrozen(remainingRewards);

        emit RewardStreamUpdated(rewardRate, periodFinish, queuedRewards);
    }

    function _claim(address account, address payable recipient) internal returns (uint256 reward) {
        _updateReward(account);

        reward = rewards[account];

        if (reward == 0) {
            return 0;
        }

        uint256 remainingFunded = totalRewardsFunded - totalRewardsClaimed;

        if (reward > remainingFunded) {
            revert RewardAccountingInsolvent();
        }

        /*
         * Checks-effects-interactions:
         *
         * Clear the user's reward and increase claimed accounting BEFORE
         * making the external ETH call.
         */
        rewards[account] = 0;
        totalRewardsClaimed += reward;

        (bool success,) = recipient.call{value: reward}("");

        if (!success) {
            revert RewardTransferFailed();
        }

        _checkSolvency();

        emit RewardPaid(account, recipient, reward);
    }

    function _checkSolvency() internal view {
        uint256 outstanding = totalRewardsFunded - totalRewardsClaimed;

        if (address(this).balance < outstanding) {
            revert RewardAccountingInsolvent();
        }
    }
}
