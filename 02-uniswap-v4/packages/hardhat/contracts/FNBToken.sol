// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title FNBToken
 * @notice ERC20 token representing eBucks (FNB reward points) on-chain.
 *         Used as one of the two assets in the PNPT/FNBT Uniswap v4 liquidity pool.
 * @dev Fixed supply: all tokens are minted to the deployer at construction and
 *      no further minting is possible. Inherits the full OpenZeppelin ERC20
 *      implementation, which provides transfer, approve, and transferFrom.
 */
contract FNBToken is ERC20 {
    /// @notice Deploys the token and mints the entire supply to the deployer.
    /// @param initialSupply Total token supply in base units (18 decimals).
    ///        For example, passing 1000000 * 10**18 mints 1,000,000 FNBT.
    constructor(uint256 initialSupply) ERC20("FNB Token", "FNBT") {
        // Mint the full fixed supply to the deployer so they can seed
        // liquidity or distribute tokens to other accounts.
        _mint(msg.sender, initialSupply);
    }
}
