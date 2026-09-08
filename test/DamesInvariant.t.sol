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
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Dames} from "../src/Dames.sol";
import {DamesBreeches} from "../src/DamesBreeches.sol";
import {DamesBounty} from "../src/DamesBounty.sol";

contract InvariantMockLP is ERC20 {
    constructor() ERC20("DAMES ETH LP", "DAMES-ETH-LP") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DamesHandler {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    Dames internal immutable dames;
    DamesBreeches internal immutable breeches;
    DamesBounty internal immutable bounty;
    InvariantMockLP internal immutable lp;

    constructor(Dames _dames, DamesBreeches _breeches, DamesBounty _bounty, InvariantMockLP _lp) {
        dames = _dames;
        breeches = _breeches;
        bounty = _bounty;
        lp = _lp;

        lp.approve(address(bounty), type(uint256).max);
    }

    receive() external payable {}

    function mint(uint96 rawAmount) external {
        if (dames.totalSupply() >= 21_000_000 ether) {
            return;
        }

        uint256 amount = (uint256(rawAmount) % 50 ether) + 1;

        if (amount > address(this).balance) {
            amount = address(this).balance;
        }

        if (amount == 0) {
            return;
        }

        uint256 quote = breeches.quote(amount);

        if (quote == 0) {
            return;
        }

        breeches.mint{value: amount}(0);
    }

    function stake(uint96 rawAmount) external {
        uint256 available = lp.balanceOf(address(this));

        if (available == 0) {
            return;
        }

        uint256 amount = (uint256(rawAmount) % 1_000 ether) + 1;

        if (amount > available) {
            amount = available;
        }

        bounty.stake(amount);
    }

    function withdraw(uint96 rawAmount) external {
        uint256 staked = bounty.balanceOf(address(this));

        if (staked == 0) {
            return;
        }

        uint256 amount = (uint256(rawAmount) % staked) + 1;

        bounty.withdraw(amount);
    }

    function claim() external {
        bounty.claim();
    }

    function warp(uint32 rawSeconds) external {
        uint256 jump = (uint256(rawSeconds) % 14 days) + 1;

        vm.warp(block.timestamp + jump);
    }
}

contract DamesInvariantTest is StdInvariant, Test {
    uint256 internal constant MAX_SUPPLY = 21_000_000 ether;

    uint256 internal constant CURVE_SCALE = 100 ether;

    Dames internal dames;
    DamesBreeches internal breeches;
    DamesBounty internal bounty;
    InvariantMockLP internal lp;
    DamesHandler internal handler;

    function setUp() public {
        dames = new Dames(address(this));

        breeches = new DamesBreeches(address(dames), CURVE_SCALE, address(this));

        lp = new InvariantMockLP();

        bounty = new DamesBounty(address(lp), address(breeches), address(this));

        breeches.setBountyOnce(address(bounty));

        bytes32 minterRole = dames.MINTER_ROLE();

        dames.grantRole(minterRole, address(breeches));

        handler = new DamesHandler(dames, breeches, bounty, lp);

        vm.deal(address(handler), 100_000 ether);

        lp.mint(address(handler), 1_000_000 ether);

        bytes4[] memory selectors = new bytes4[](5);

        selectors[0] = DamesHandler.mint.selector;

        selectors[1] = DamesHandler.stake.selector;

        selectors[2] = DamesHandler.withdraw.selector;

        selectors[3] = DamesHandler.claim.selector;

        selectors[4] = DamesHandler.warp.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        targetContract(address(handler));
    }

    function invariantSupplyNeverExceeds21Million() public view {
        assertLe(dames.totalSupply(), MAX_SUPPLY);
    }

    function invariantBountyAlwaysHasEnoughEth() public view {
        assertGe(address(bounty).balance, bounty.outstandingRewards());
    }

    function invariantClaimsNeverExceedFunding() public view {
        assertLe(bounty.totalRewardsClaimed(), bounty.totalRewardsFunded());
    }

    function invariantBountyAlwaysHoldsStakedLP() public view {
        assertGe(lp.balanceOf(address(bounty)), bounty.totalStaked());
    }

    function invariantBreechesNeverHoldsEth() public view {
        assertEq(address(breeches).balance, 0);
    }

    function invariantEveryContributedEthIsFunded() public view {
        assertEq(breeches.totalEthContributed(), bounty.totalRewardsFunded());
    }

    function invariantBountyEthMatchesAccounting() public view {
        assertEq(address(bounty).balance, bounty.totalRewardsFunded() - bounty.totalRewardsClaimed());
    }

    function invariantSupplyMatchesCurve() public view {
        assertEq(dames.totalSupply(), breeches.totalMintableAt(breeches.totalEthContributed()));
    }

    function invariantLPAccountingMatchesBalance() public view {
        assertEq(lp.balanceOf(address(bounty)), bounty.totalStaked());
    }
}
