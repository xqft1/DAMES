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

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Dames} from "../src/Dames.sol";
import {DamesBreeches} from "../src/DamesBreeches.sol";
import {DamesBounty} from "../src/DamesBounty.sol";

/*//////////////////////////////////////////////////////////////
                            MOCK LP
//////////////////////////////////////////////////////////////*/

/**
 * @notice Simple ERC20 used to simulate the DAMES/ETH Uniswap V2 LP token.
 */
contract MockLP is ERC20 {
    constructor() ERC20("Mock DAMES ETH LP", "DAMES-ETH-LP") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/*//////////////////////////////////////////////////////////////
                    REENTRANCY ATTACKER
//////////////////////////////////////////////////////////////*/

contract ReentrantClaimer {
    DamesBounty public immutable bounty;
    MockLP public immutable lp;

    uint256 public received;
    bool public reenterSucceeded;

    constructor(DamesBounty _bounty, MockLP _lp) {
        bounty = _bounty;
        lp = _lp;
    }

    function stake(uint256 amount) external {
        lp.approve(address(bounty), amount);
        bounty.stake(amount);
    }

    function attackClaim() external {
        bounty.claim();
    }

    receive() external payable {
        received += msg.value;

        /*
         * Attempt to re-enter claim().
         *
         * The outer claim should still succeed, but this nested call
         * must fail because of ReentrancyGuard.
         */
        (bool success,) = address(bounty).call(abi.encodeWithSelector(DamesBounty.claim.selector));

        reenterSucceeded = success;
    }
}

/*//////////////////////////////////////////////////////////////
                          TEST SUITE
//////////////////////////////////////////////////////////////*/

contract DamesTest is Test {
    uint256 internal constant MAX_SUPPLY = 21_000_000 ether;

    /*
     * Test curve scale.
     *
     * Production value can be chosen later.
     */
    uint256 internal constant CURVE_SCALE = 100 ether;

    Dames internal dames;
    DamesBreeches internal breeches;
    DamesBounty internal bounty;
    MockLP internal lp;

    address internal owner;
    address internal alice;
    address internal bob;
    address internal attackerEOA;

    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        attackerEOA = makeAddr("attacker");

        /*//////////////////////////////////////////////////////////////
                              DEPLOY
        //////////////////////////////////////////////////////////////*/

        dames = new Dames(owner);

        breeches = new DamesBreeches(address(dames), CURVE_SCALE, owner);

        lp = new MockLP();

        bounty = new DamesBounty(address(lp), address(breeches), owner);

        /*//////////////////////////////////////////////////////////////
                          CONNECT CONTRACTS
        //////////////////////////////////////////////////////////////*/

        vm.prank(owner);
        breeches.setBountyOnce(address(bounty));

        bytes32 minterRole = dames.MINTER_ROLE();

        vm.prank(owner);
        dames.grantRole(minterRole, address(breeches));

        /*//////////////////////////////////////////////////////////////
                          FUND TEST ACCOUNTS
        //////////////////////////////////////////////////////////////*/

        vm.deal(alice, 100_000 ether);
        vm.deal(bob, 100_000 ether);
        vm.deal(attackerEOA, 100_000 ether);

        /*//////////////////////////////////////////////////////////////
                          MOCK LP BALANCES
        //////////////////////////////////////////////////////////////*/

        lp.mint(alice, 10_000 ether);
        lp.mint(bob, 10_000 ether);

        vm.prank(alice);
        lp.approve(address(bounty), type(uint256).max);

        vm.prank(bob);
        lp.approve(address(bounty), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                         TOKEN SECURITY
    //////////////////////////////////////////////////////////////*/

    function testOnlyBreechesCanMint() public {
        vm.startPrank(alice);

        vm.expectRevert();

        dames.mint(alice, 1 ether);

        vm.stopPrank();

        assertEq(dames.balanceOf(alice), 0);
    }

    function testBreechesHasMinterRole() public view {
        assertTrue(dames.hasRole(dames.MINTER_ROLE(), address(breeches)));
    }

    function testAdminCanBePermanentlyRenounced() public {
        bytes32 adminRole = dames.DEFAULT_ADMIN_ROLE();
        bytes32 minterRole = dames.MINTER_ROLE();

        vm.prank(owner);
        dames.renounceRole(adminRole, owner);

        assertFalse(dames.hasRole(adminRole, owner));

        vm.startPrank(owner);
        vm.expectRevert();
        dames.grantRole(minterRole, attackerEOA);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                         BOUNTY CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function testBountyCannotBeChanged() public {
        vm.startPrank(owner);

        vm.expectRevert(DamesBreeches.BountyAlreadySet.selector);

        breeches.setBountyOnce(address(bounty));

        vm.stopPrank();

        assertEq(breeches.bounty(), address(bounty));
    }

    /*//////////////////////////////////////////////////////////////
                          BASIC MINTING
    //////////////////////////////////////////////////////////////*/

    function testMintDamesWithEth() public {
        uint256 ethAmount = 1 ether;

        uint256 expected = breeches.quote(ethAmount);

        assertGt(expected, 0);

        vm.prank(alice);

        uint256 received = breeches.mint{value: ethAmount}(expected);

        assertEq(received, expected);

        assertEq(dames.balanceOf(alice), expected);

        assertEq(dames.totalSupply(), expected);

        assertEq(breeches.totalEthContributed(), ethAmount);
    }

    function testBreechesNeverKeepsEth() public {
        uint256 ethAmount = 3 ether;

        uint256 quote = breeches.quote(ethAmount);

        vm.prank(alice);

        breeches.mint{value: ethAmount}(quote);

        assertEq(address(breeches).balance, 0);

        assertEq(address(bounty).balance, ethAmount);
    }

    /*//////////////////////////////////////////////////////////////
                       CRITICAL REWARD FUNDING
    //////////////////////////////////////////////////////////////*/

    function testMintFundsBountyAtomically() public {
        uint256 ethAmount = 5 ether;

        uint256 quote = breeches.quote(ethAmount);

        vm.prank(alice);

        breeches.mint{value: ethAmount}(quote);

        assertEq(bounty.totalRewardsFunded(), ethAmount);

        assertEq(address(bounty).balance, ethAmount);

        assertEq(bounty.outstandingRewards(), ethAmount);
    }

    function testMultipleMintsCannotDoubleCountEth() public {
        uint256 firstAmount = 1 ether;
        uint256 secondAmount = 2 ether;

        uint256 quote1 = breeches.quote(firstAmount);

        vm.prank(alice);

        breeches.mint{value: firstAmount}(quote1);

        uint256 quote2 = breeches.quote(secondAmount);

        vm.prank(bob);

        breeches.mint{value: secondAmount}(quote2);

        assertEq(bounty.totalRewardsFunded(), 3 ether);

        assertEq(address(bounty).balance, 3 ether);

        assertEq(breeches.totalEthContributed(), 3 ether);
    }

    /**
     * This is the key regression test for the old style of reward exploit.
     *
     * Nobody except DamesBreeches can tell the Bounty that rewards exist.
     */
    function testAttackerCannotFakeRewardFunding() public {
        vm.startPrank(attackerEOA);

        vm.expectRevert(DamesBounty.NotDamesBreeches.selector);

        bounty.fundRewards{value: 10 ether}();

        vm.stopPrank();

        assertEq(bounty.totalRewardsFunded(), 0);

        assertEq(address(bounty).balance, 0);
    }

    function testCannotNotifyRewardsWithoutEth() public {
        vm.startPrank(attackerEOA);

        vm.expectRevert(DamesBounty.NotDamesBreeches.selector);

        bounty.fundRewards();

        vm.stopPrank();

        assertEq(bounty.totalRewardsFunded(), 0);
    }

    function testPlainEthTransferToBountyIsRejected() public {
        vm.prank(attackerEOA);

        (bool success,) = address(bounty).call{value: 1 ether}("");

        assertFalse(success);

        assertEq(address(bounty).balance, 0);

        assertEq(bounty.totalRewardsFunded(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                      ATOMIC FAILURE PROTECTION
    //////////////////////////////////////////////////////////////*/

    function testMintRevertsIfBountyCannotAcceptReward() public {
        vm.prank(owner);
        bounty.pause();

        uint256 quote = breeches.quote(1 ether);

        uint256 supplyBefore = dames.totalSupply();

        uint256 contributedBefore = breeches.totalEthContributed();

        vm.startPrank(alice);

        vm.expectRevert();

        breeches.mint{value: 1 ether}(quote);

        vm.stopPrank();

        /*
         * Entire transaction must roll back.
         */
        assertEq(dames.totalSupply(), supplyBefore);

        assertEq(breeches.totalEthContributed(), contributedBefore);

        assertEq(bounty.totalRewardsFunded(), 0);

        assertEq(address(bounty).balance, 0);

        assertEq(address(breeches).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                       SLIPPAGE PROTECTION
    //////////////////////////////////////////////////////////////*/

    function testMinDamesOutProtectsUser() public {
        uint256 quote = breeches.quote(1 ether);

        vm.startPrank(alice);

        vm.expectRevert(abi.encodeWithSelector(DamesBreeches.SlippageExceeded.selector, quote, quote + 1));

        breeches.mint{value: 1 ether}(quote + 1);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        ZERO STAKER LOGIC
    //////////////////////////////////////////////////////////////*/

    function testRewardsQueueWhenNobodyIsStaking() public {
        uint256 ethAmount = 7 ether;

        uint256 quote = breeches.quote(ethAmount);

        vm.prank(alice);

        breeches.mint{value: ethAmount}(quote);

        assertEq(bounty.totalStaked(), 0);

        assertEq(bounty.rewardRate(), 0);

        assertEq(bounty.queuedRewards(), ethAmount);

        assertEq(address(bounty).balance, ethAmount);
    }

    function testFirstStakeStartsQueuedRewardStream() public {
        uint256 ethAmount = 7 ether;

        uint256 quote = breeches.quote(ethAmount);

        vm.prank(alice);

        breeches.mint{value: ethAmount}(quote);

        assertEq(bounty.rewardRate(), 0);

        vm.prank(alice);

        bounty.stake(100 ether);

        assertEq(bounty.totalStaked(), 100 ether);

        assertGt(bounty.rewardRate(), 0);

        assertEq(bounty.periodFinish(), block.timestamp + 7 days);

        /*
         * Only integer division dust should remain queued.
         */
        assertLt(bounty.queuedRewards(), bounty.REWARD_DURATION());
    }

    /*//////////////////////////////////////////////////////////////
                         STAKING
    //////////////////////////////////////////////////////////////*/

    function testStakeLP() public {
        vm.prank(alice);

        bounty.stake(100 ether);

        assertEq(bounty.balanceOf(alice), 100 ether);

        assertEq(bounty.totalStaked(), 100 ether);

        assertEq(lp.balanceOf(address(bounty)), 100 ether);
    }

    function testWithdrawLP() public {
        vm.prank(alice);

        bounty.stake(100 ether);

        vm.prank(alice);

        bounty.withdraw(40 ether);

        assertEq(bounty.balanceOf(alice), 60 ether);

        assertEq(bounty.totalStaked(), 60 ether);

        assertEq(lp.balanceOf(address(bounty)), 60 ether);

        assertEq(lp.balanceOf(alice), 9_940 ether);
    }

    function testCannotWithdrawMoreThanStaked() public {
        vm.prank(alice);

        bounty.stake(100 ether);

        vm.startPrank(alice);

        vm.expectRevert(DamesBounty.InsufficientStake.selector);

        bounty.withdraw(101 ether);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        REWARD DISTRIBUTION
    //////////////////////////////////////////////////////////////*/

    function testSingleStakerEarnsEth() public {
        vm.prank(alice);

        bounty.stake(100 ether);

        uint256 quote = breeches.quote(7 ether);

        vm.prank(bob);

        breeches.mint{value: 7 ether}(quote);

        vm.warp(block.timestamp + 1 days);

        uint256 earned = bounty.earned(alice);

        /*
         * 7 ETH over 7 days = about 1 ETH after one day.
         */
        assertApproxEqAbs(earned, 1 ether, 1e12);
    }

    function testTwoEqualStakersSplitRewardsEqually() public {
        vm.prank(alice);
        bounty.stake(100 ether);

        vm.prank(bob);
        bounty.stake(100 ether);

        uint256 quote = breeches.quote(7 ether);

        vm.prank(alice);

        breeches.mint{value: 7 ether}(quote);

        vm.warp(block.timestamp + 7 days);

        uint256 aliceEarned = bounty.earned(alice);

        uint256 bobEarned = bounty.earned(bob);

        assertApproxEqAbs(aliceEarned, 3.5 ether, 1e12);

        assertApproxEqAbs(bobEarned, 3.5 ether, 1e12);

        assertApproxEqAbs(aliceEarned, bobEarned, 1);
    }

    function testClaimEthReward() public {
        vm.prank(alice);

        bounty.stake(100 ether);

        uint256 quote = breeches.quote(7 ether);

        vm.prank(bob);

        breeches.mint{value: 7 ether}(quote);

        vm.warp(block.timestamp + 1 days);

        uint256 balanceBefore = alice.balance;

        uint256 expectedReward = bounty.earned(alice);

        vm.prank(alice);

        uint256 claimed = bounty.claim();

        assertEq(claimed, expectedReward);

        assertEq(alice.balance, balanceBefore + claimed);

        assertEq(bounty.rewards(alice), 0);

        assertEq(bounty.totalRewardsClaimed(), claimed);
    }

    /*//////////////////////////////////////////////////////////////
                      LAST STAKER PROTECTION
    //////////////////////////////////////////////////////////////*/

    function testLastStakerLeavingFreezesRewards() public {
        vm.prank(alice);

        bounty.stake(100 ether);

        uint256 quote = breeches.quote(7 ether);

        vm.prank(bob);

        breeches.mint{value: 7 ether}(quote);

        vm.warp(block.timestamp + 1 days);

        uint256 earnedBefore = bounty.earned(alice);

        vm.prank(alice);

        bounty.withdraw(100 ether);

        assertEq(bounty.totalStaked(), 0);

        assertEq(bounty.rewardRate(), 0);

        assertGt(bounty.queuedRewards(), 0);

        uint256 earnedAfterWithdraw = bounty.earned(alice);

        assertApproxEqAbs(earnedAfterWithdraw, earnedBefore, 1);

        /*
         * Time passing with nobody staked must not consume rewards.
         */
        vm.warp(block.timestamp + 30 days);

        assertEq(bounty.earned(alice), earnedAfterWithdraw);
    }

    /*//////////////////////////////////////////////////////////////
                           PAUSING
    //////////////////////////////////////////////////////////////*/

    function testCannotStakeWhilePaused() public {
        vm.prank(owner);
        bounty.pause();

        vm.startPrank(alice);

        vm.expectRevert();

        bounty.stake(100 ether);

        vm.stopPrank();
    }

    function testWithdrawStillWorksWhilePaused() public {
        vm.prank(alice);
        bounty.stake(100 ether);

        vm.prank(owner);
        bounty.pause();

        vm.prank(alice);
        bounty.withdraw(100 ether);

        assertEq(bounty.balanceOf(alice), 0);

        assertEq(bounty.totalStaked(), 0);
    }

    function testClaimStillWorksWhilePaused() public {
        vm.prank(alice);
        bounty.stake(100 ether);

        uint256 quote = breeches.quote(7 ether);

        vm.prank(bob);

        breeches.mint{value: 7 ether}(quote);

        vm.warp(block.timestamp + 1 days);

        vm.prank(owner);
        bounty.pause();

        uint256 earnedBefore = bounty.earned(alice);

        assertGt(earnedBefore, 0);

        vm.prank(alice);

        uint256 claimed = bounty.claim();

        assertEq(claimed, earnedBefore);
    }

    /*//////////////////////////////////////////////////////////////
                       REENTRANCY PROTECTION
    //////////////////////////////////////////////////////////////*/

    function testClaimCannotBeReentered() public {
        ReentrantClaimer malicious = new ReentrantClaimer(bounty, lp);

        lp.mint(address(malicious), 100 ether);

        malicious.stake(100 ether);

        uint256 quote = breeches.quote(7 ether);

        vm.prank(alice);

        breeches.mint{value: 7 ether}(quote);

        vm.warp(block.timestamp + 1 days);

        uint256 expected = bounty.earned(address(malicious));

        assertGt(expected, 0);

        malicious.attackClaim();

        /*
         * Outer claim succeeds.
         */
        assertEq(malicious.received(), expected);

        /*
         * Nested claim must fail.
         */
        assertFalse(malicious.reenterSucceeded());

        /*
         * Reward cannot be claimed twice.
         */
        assertEq(bounty.earned(address(malicious)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            CURVE
    //////////////////////////////////////////////////////////////*/

    function testCurveStartsAtZero() public view {
        assertEq(breeches.totalMintableAt(0), 0);
    }

    function testCurveIncreasesWithEth() public view {
        uint256 atOne = breeches.totalMintableAt(1 ether);

        uint256 atTen = breeches.totalMintableAt(10 ether);

        uint256 atHundred = breeches.totalMintableAt(100 ether);

        assertGt(atOne, 0);

        assertGt(atTen, atOne);

        assertGt(atHundred, atTen);

        assertLe(atHundred, MAX_SUPPLY);
    }

    function testCurveAtOneScaleIsAbout63Percent() public view {
        uint256 supply = breeches.totalMintableAt(CURVE_SCALE);

        /*
         * 1 - e^-1 ≈ 63.21%
         */
        assertGt(supply, 13_000_000 ether);

        assertLt(supply, 13_500_000 ether);
    }

    function testCurveCanNeverExceedMaxSupply() public view {
        uint256 supply = breeches.totalMintableAt(CURVE_SCALE * 1_000);

        assertEq(supply, MAX_SUPPLY);
    }

    function testMaximumSupplyCannotBeExceeded() public {
        uint256 ethAmount = CURVE_SCALE * 42;

        vm.deal(alice, ethAmount + 1 ether);

        uint256 quote = breeches.quote(ethAmount);

        assertEq(quote, MAX_SUPPLY);

        vm.prank(alice);

        breeches.mint{value: ethAmount}(quote);

        assertEq(dames.totalSupply(), MAX_SUPPLY);

        vm.startPrank(alice);

        vm.expectRevert(DamesBreeches.MaxSupplyReached.selector);

        breeches.mint{value: 1 ether}(0);

        vm.stopPrank();

        assertEq(dames.totalSupply(), MAX_SUPPLY);
    }

    /*//////////////////////////////////////////////////////////////
                             FUZZING
    //////////////////////////////////////////////////////////////*/

    function testFuzzCurveNeverExceedsMaxSupply(uint256 ethAmount) public view {
        ethAmount = bound(ethAmount, 0, 1_000_000 ether);

        uint256 supply = breeches.totalMintableAt(ethAmount);

        assertLe(supply, MAX_SUPPLY);
    }

    function testFuzzCurveIsMonotonic(uint256 a, uint256 b) public view {
        a = bound(a, 0, 10_000 ether);

        b = bound(b, 0, 10_000 ether);

        if (a > b) {
            (a, b) = (b, a);
        }

        uint256 supplyA = breeches.totalMintableAt(a);

        uint256 supplyB = breeches.totalMintableAt(b);

        assertLe(supplyA, supplyB);
    }

    function testFuzzMintAccounting(uint256 ethAmount) public {
        ethAmount = bound(ethAmount, 1e12, 100 ether);

        vm.deal(alice, ethAmount);

        uint256 quote = breeches.quote(ethAmount);

        assertGt(quote, 0);

        vm.prank(alice);

        breeches.mint{value: ethAmount}(quote);

        assertEq(dames.totalSupply(), quote);

        assertEq(dames.balanceOf(alice), quote);

        assertEq(breeches.totalEthContributed(), ethAmount);

        assertEq(bounty.totalRewardsFunded(), ethAmount);

        assertEq(address(bounty).balance, ethAmount);

        assertEq(bounty.outstandingRewards(), ethAmount);

        assertEq(address(breeches).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                     CORE SOLVENCY INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function testRewardBalanceAlwaysBacksAccounting() public {
        vm.prank(alice);
        bounty.stake(100 ether);

        uint256 quote = breeches.quote(10 ether);

        vm.prank(bob);

        breeches.mint{value: 10 ether}(quote);

        vm.warp(block.timestamp + 3 days);

        vm.prank(alice);
        bounty.claim();

        /*
         * Every outstanding accounted reward must still have real ETH
         * physically sitting inside DamesBounty.
         */
        assertGe(address(bounty).balance, bounty.outstandingRewards());
    }

    function testBountyAlwaysHoldsAllStakedLP() public {
        vm.prank(alice);
        bounty.stake(321 ether);

        vm.prank(bob);
        bounty.stake(123 ether);

        assertEq(bounty.totalStaked(), 444 ether);

        assertGe(lp.balanceOf(address(bounty)), bounty.totalStaked());
    }
}
