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

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Capped} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract Dames is ERC20, ERC20Capped, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    uint256 public constant MAX_SUPPLY = 21_000_000 ether;

    constructor(address admin) ERC20("Dames", "DAMES") ERC20Capped(MAX_SUPPLY) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Capped) {
        super._update(from, to, value);
    }
}
