// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title PNPToken
 * @notice ERC20 token representing Pick n Pay Smart Shopper points on-chain.
 * @dev Fixed supply: all tokens are minted to the deployer at construction and
 *      no further minting is possible. Inherits the full OpenZeppelin ERC20
 *      implementation, which provides transfer, approve, and transferFrom.
 */

 // ERC20 token representing Pick n Pay Smart Shopper points on-chain.
// The token has a fixed supply, which is created when the contract is deployed.
contract PNPToken is ERC20 {
    /**
     * @notice Deploys the token and mints the entire supply to the deployer.
     * @param initialSupply Total token supply in base units (18 decimals).
     *        For example, passing 1000000 * 10**18 mints 1,000,000 PNPT.
     */
     // Constructor runs once when the contract is deployed.
    // It creates the full initial supply and gives it to the deployer.
    constructor(uint256 initialSupply) ERC20("PNP Token", "PNPT") {
        // Mint the full fixed supply to the deployer so they can seed
        // liquidity or distribute tokens to other accounts.
        _mint(msg.sender, initialSupply);
    }
}
