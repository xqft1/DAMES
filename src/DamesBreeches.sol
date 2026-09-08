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

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

interface IDames {
    function mint(address to, uint256 amount) external;
    function totalSupply() external view returns (uint256);
}

interface IDamesBounty {
    function fundRewards() external payable;
    function damesBreeches() external view returns (address);
}

/**
 * @title DamesBreeches
 * @notice Bonding-curve mint contract for DAMES.
 *
 * Users send ETH and receive DAMES according to an exponential bonding curve.
 * 100% of ETH received is atomically forwarded to DamesBounty for
 * DAMES/ETH LP stakers.
 *
 * Security:
 * - No ETH treasury.
 * - No developer fee.
 * - No ETH withdrawal function.
 * - Bounty address can only be configured once.
 * - The Bounty must prove it was deployed specifically for this Breeches.
 * - Minting uses a user supplied minimum output for slippage protection.
 * - Reentrancy protected.
 * - Minting can be paused without changing the Bounty.
 */
contract DamesBreeches is Ownable2Step, Pausable, ReentrancyGuard {
    uint256 public constant WAD = 1e18;
    uint256 public constant MAX_SUPPLY = 21_000_000 ether;

    /*
     * Solady expWad returns zero at approximately -41.4465e18.
     * At that point the curve has effectively reached MAX_SUPPLY.
     */
    uint256 private constant EXP_ZERO_THRESHOLD = 41_446_531_673_892_822_313;

    IDames public immutable dames;

    /**
     * @notice Controls the steepness of the curve.
     *
     * Larger value = slower issuance.
     *
     * At totalEthContributed == curveScale,
     * approximately 63.2% of the total supply is mintable.
     */
    uint256 public immutable curveScale;

    /**
     * @notice DamesBounty contract.
     *
     * Starts unset because DamesBounty itself requires the Breeches address
     * during deployment. It can be set exactly once.
     */
    address public bounty;

    /// @notice Total ETH successfully contributed through minting.
    uint256 public totalEthContributed;

    event BountySet(address indexed bounty);

    event DamesMinted(
        address indexed minter,
        uint256 ethAmount,
        uint256 damesAmount,
        uint256 totalEthContributed,
        uint256 totalDamesSupply
    );

    error ZeroAddress();
    error ZeroAmount();
    error BadCurveScale();
    error BountyAlreadySet();
    error InvalidBounty();
    error BountyNotConfigured();
    error MaxSupplyReached();
    error TooLittleEth();
    error SlippageExceeded(uint256 damesOut, uint256 minDamesOut);

    constructor(address _dames, uint256 _curveScale, address _owner) Ownable(_owner) {
        if (_dames == address(0) || _owner == address(0)) {
            revert ZeroAddress();
        }

        if (_curveScale == 0) {
            revert BadCurveScale();
        }

        dames = IDames(_dames);
        curveScale = _curveScale;
    }

    /**
     * @notice Configure DamesBounty exactly once.
     *
     * The supplied contract must report this Breeches contract as its
     * immutable damesBreeches address. This prevents accidentally connecting
     * to the wrong reward contract.
     */
    function setBountyOnce(address _bounty) external onlyOwner {
        if (bounty != address(0)) {
            revert BountyAlreadySet();
        }

        if (_bounty == address(0) || _bounty.code.length == 0) {
            revert InvalidBounty();
        }

        /*
         * DamesBounty has:
         *
         * address public immutable damesBreeches;
         *
         * so Solidity automatically exposes this getter.
         */
        try IDamesBounty(_bounty).damesBreeches() returns (address configuredBreeches) {
            if (configuredBreeches != address(this)) {
                revert InvalidBounty();
            }
        } catch {
            revert InvalidBounty();
        }

        bounty = _bounty;

        emit BountySet(_bounty);
    }

    /**
     * @notice Mint DAMES using native ETH.
     *
     * @param minDamesOut Minimum acceptable DAMES output.
     *
     * 100% of msg.value is sent atomically to DamesBounty.
     * If Bounty funding fails, the entire mint transaction reverts.
     */
    function mint(uint256 minDamesOut) external payable whenNotPaused nonReentrant returns (uint256 damesOut) {
        if (msg.value == 0) {
            revert ZeroAmount();
        }

        address bountyAddress = bounty;

        if (bountyAddress == address(0)) {
            revert BountyNotConfigured();
        }

        uint256 supply = dames.totalSupply();

        if (supply >= MAX_SUPPLY) {
            revert MaxSupplyReached();
        }

        uint256 newTotalEth = totalEthContributed + msg.value;

        uint256 targetSupply = totalMintableAt(newTotalEth);

        /*
         * Anchor issuance against actual DAMES supply rather than blindly
         * trusting historical curve accounting.
         *
         * This provides additional protection if token supply and curve state
         * could ever become inconsistent during deployment/setup.
         */
        if (targetSupply <= supply) {
            revert TooLittleEth();
        }

        damesOut = targetSupply - supply;

        if (damesOut < minDamesOut) {
            revert SlippageExceeded(damesOut, minDamesOut);
        }

        /*
         * Effects first.
         *
         * If either external call below fails, Solidity reverts this update
         * along with the entire transaction.
         */
        totalEthContributed = newTotalEth;

        /*
         * Atomically fund rewards.
         *
         * There is no separate rewardAmount parameter.
         * The Bounty records msg.value itself.
         *
         * Therefore the amount reported as a reward cannot differ from the
         * amount of ETH actually delivered.
         */
        IDamesBounty(bountyAddress).fundRewards{value: msg.value}();

        /*
         * Mint only after successful reward funding.
         *
         * If mint() fails, the earlier Bounty call also reverts because the
         * entire transaction is atomic.
         */
        dames.mint(msg.sender, damesOut);

        emit DamesMinted(msg.sender, msg.value, damesOut, newTotalEth, supply + damesOut);
    }

    /**
     * @notice Preview DAMES received for a given ETH contribution.
     */
    function quote(uint256 ethAmount) external view returns (uint256 damesOut) {
        if (ethAmount == 0) {
            return 0;
        }

        uint256 supply = dames.totalSupply();

        if (supply >= MAX_SUPPLY) {
            return 0;
        }

        uint256 targetSupply = totalMintableAt(totalEthContributed + ethAmount);

        if (targetSupply <= supply) {
            return 0;
        }

        damesOut = targetSupply - supply;
    }

    /**
     * @notice Total DAMES that should be mintable after a given cumulative
     *         amount of ETH has been contributed.
     *
     * Curve:
     *
     * MAX_SUPPLY * (1 - e^(-totalETH / curveScale))
     */
    function totalMintableAt(uint256 totalEthAmount) public view returns (uint256) {
        if (totalEthAmount == 0) {
            return 0;
        }

        /*
         * Full precision multiplication avoids:
         *
         * totalEthAmount * 1e18
         *
         * overflowing before division.
         */
        uint256 exponentWad = Math.mulDiv(totalEthAmount, WAD, curveScale);

        /*
         * expWad is effectively zero beyond this point, therefore the curve
         * has reached the maximum representable supply.
         *
         * Checking here also guarantees the uint256 -> int256 cast below is
         * safely bounded.
         */
        if (exponentWad >= EXP_ZERO_THRESHOLD) {
            return MAX_SUPPLY;
        }

        int256 negativeExponent = -int256(exponentWad);

        int256 decaySigned = FixedPointMathLib.expWad(negativeExponent);

        uint256 decay = uint256(decaySigned);

        uint256 mintedRatio = WAD - decay;

        return Math.mulDiv(MAX_SUPPLY, mintedRatio, WAD);
    }

    /**
     * @notice Emergency stop for new DAMES minting.
     *
     * No ETH is held in Breeches, and the owner cannot redirect the Bounty
     * once it has been configured.
     */
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
