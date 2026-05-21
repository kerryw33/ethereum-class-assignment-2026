// Kerry Lynn Whyte - ECO5037W Assignment 2 part 2
// 2026-05-21
// A smart contract which creates a Uniswap v4 liquidity pool using the protocol’s PoolManager
// price is discovered internally from pool state (reserves/liquidity curve) and it updates automatically as swaps and liquidity changes happen
// token holders trade against the pool's liquidity, not directly with other traders (as in an order book)


// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

/// @notice Manages a Uniswap v4 PNPT/FNBT liquidity pool:
///         creates the pool and mints concentrated liquidity positions.
contract RewardTokensManager is Ownable {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    //  Pool constants 
    uint24  public constant FEE_TIER     = 3000;      // 0.30 % swap fee
    int24   public constant TICK_SPACING = 60;        // standard spacing for 0.30 %
    address public constant HOOKS        = address(0); // no hooks

    // --- Economic target tick ---
    // 1 FNBT (eBucks, R0.10) = 10 PNPT (Smart Shopper, R0.01)
    // price = currency1 / currency0  =  1.0001^tick
    // tick  = floor(ln(price) / ln(1.0001)) 
    //
    // If PNPT < FNBT (address order): c0=PNPT, c1=FNBT
    //   price = 0.1  →  tick = floor(-23027.05) = -23028
    // If FNBT < PNPT:                 c0=FNBT, c1=PNPT
    //   price = 10   →  tick = floor( 23027.05) =  23027
    int24 private constant TARGET_TICK_PNPT_AS_C0 = -23028;
    int24 private constant TARGET_TICK_FNBT_AS_C0 =  23027;

    // Immutables - references to external contracts + token addresses (set at deployment - never change)
    IPoolManager     public immutable poolManager;
    IPositionManager public immutable positionManager;
    IERC20           public immutable pnpToken;
    IERC20           public immutable fnbToken;
    address          public immutable permit2;   // Permit2 used by PositionManager

    // Pool state  
    Currency public currency0; 
    Currency public currency1;
    PoolKey  public poolKey;

    /// @notice Tracks which poolIds this contract has initialised.
    mapping(bytes32 => bool) public createdPools;

    // --- Events ---
    event PoolCreated(
        bytes32 indexed poolId,
        address currency0,
        address currency1,
        uint24  fee,
        int24   tickSpacing,
        address hooks,
        uint160 sqrtPriceX96
    );

    event LiquidityMinted(
        bytes32 indexed poolId,
        uint256 positionId,
        address indexed owner,
        int24   tickLower,
        int24   tickUpper,
        uint128 liquidity
    );

    // Errors  
    error TickRangeDoesNotCoverAssignmentPrice();

    //  Constructor - initializes the contract with references to PoolManager, PositionManager, token addresses, and computes the pool key.
    constructor(
        address _poolManager,
        address _positionManager,
        address _pnpToken,
        address _fnbToken
    ) Ownable(msg.sender) {
        poolManager     = IPoolManager(_poolManager);
        positionManager = IPositionManager(_positionManager);
        pnpToken        = IERC20(_pnpToken);
        fnbToken        = IERC20(_fnbToken);

        // Retrieve Permit2 address from PositionManager 
        // PositionManager exposes permit2 as a public variable (getter) so call it
        (bool success, bytes memory data) = _positionManager.call(abi.encodeWithSignature("permit2()"));
        require(success, "permit2() call failed"); 
        permit2 = abi.decode(data, (address)); // decode the returned address from the call

        // Canonical ordering: lower address = currency0 (Uniswap convention)
        if (_pnpToken < _fnbToken) {
            currency0 = Currency.wrap(_pnpToken);
            currency1 = Currency.wrap(_fnbToken);
        } else {
            currency0 = Currency.wrap(_fnbToken);
            currency1 = Currency.wrap(_pnpToken);
        }
        
        // Uniswap v4 pool key for the PNPT/FNBT pair 
        poolKey = PoolKey({
            currency0:   currency0,
            currency1:   currency1,
            fee:         FEE_TIER,
            tickSpacing: TICK_SPACING,
            hooks:       IHooks(HOOKS)
        });
    }

    // --- View helper functions ---

    /// @notice Returns the assignment's implied target tick for the FNBT/PNPT pair.
    ///         Derived from 1 FNBT = 10 PNPT (price = c1/c0 = 1.0001^tick).
    /// @return target tick= -23028 when PNPT is currency0, target tick  = 23027 when FNBT is currency0.
    function getTargetTick() public view returns (int24) {
        if (Currency.unwrap(currency0) == address(pnpToken)) {
            return TARGET_TICK_PNPT_AS_C0; // c0=PNPT, c1=FNBT, price=0.1  (target tick=-23028)
        } else {
            return TARGET_TICK_FNBT_AS_C0; // c0=FNBT, c1=PNPT, price=10  (target tick=23027)
        }
    }

    /// @notice Returns the poolId for the PNPT/FNBT pool managed by this contract.
    /// @return The keccak256 pool identifier derived from the pool key.
    function getPoolId() public view returns (bytes32) {
        return PoolId.unwrap(poolKey.toId());
    }

    /// @notice Returns the canonical (sorted) token addresses used as pool currencies.
    /// @return currency0 address (lower address) and currency1 address (higher address).
    function getCanonicalCurrencies() external view returns (address, address) {
        return (Currency.unwrap(currency0), Currency.unwrap(currency1));
    }

    // --- Part 2: Pool creation ---

    /// @notice Initialises the PNPT/FNBT pool in PoolManager at the given starting price.
    /// @dev    Restricted to the owner (onlyOwner) so that only the deployer can set the
    ///         pool's starting sqrtPriceX96.
    /// @param sqrtPriceX96 Starting sqrt price (Q96 fixed-point) for the pool.
    /// @return poolId Keccak256 pool identifier derived from the pool key.
    function createPool(uint160 sqrtPriceX96) external onlyOwner returns (bytes32 poolId) {
        poolId = getPoolId();

        // Initialise the pool inside the singleton PoolManager .
        poolManager.initialize(poolKey, sqrtPriceX96);
        createdPools[poolId] = true; // mark this poolId as created

        // Emit an event with the pool details (tokens, fee tier, tick spacing, hooks address, and any PoolId) for off-chain indexing and verification - .
        emit PoolCreated(
            poolId, 
            Currency.unwrap(currency0),// address of currency0 token
            Currency.unwrap(currency1), // address of currency1 token
            FEE_TIER, // fee tier (3000 = 0.30%)
            TICK_SPACING, // tick spacing (60)
            HOOKS, // hooks address (0 so no hooks)
            sqrtPriceX96 
        );
    }

    // --- Part 3: Mint liquidity ---

    /// @notice Mints a concentrated liquidity position in the PNPT/FNBT pool.
    /// @param tickLower  Lower tick boundary (must be a multiple of TICK_SPACING).
    /// @param tickUpper  Upper tick boundary (must be a multiple of TICK_SPACING).
    /// @param amount0Desired Max amount of currency0 the caller is willing to deposit.
    /// @param amount1Desired Max amount of currency1 the caller is willing to deposit.
    /// @return positionId NFT token-id minted by PositionManager.
    /// @return poolId     The pool identifier for the position.
    function mintLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external returns (uint256 positionId, bytes32 poolId) {

        // Validate inputs and tick constraints.
        require(tickLower < tickUpper,                    "bad tick range"); // lower tick must be less than upper tick
        require(tickLower % TICK_SPACING == 0,            "tickLower not aligned"); // lower tick must be multiple of tick spacing
        require(tickUpper % TICK_SPACING == 0,            "tickUpper not aligned"); // upper tick must be multiple of tick spacing
        require(amount0Desired > 0 || amount1Desired > 0, "zero amounts"); // at least one of the desired amounts must be greater than zero
 
        // Ensure the chosen range covers the assignment's implied target tick - must be in range (lowerTick, upperTick).
        //    The range is valid when tickLower <= targetTick < tickUpper.
        int24 targetTick = getTargetTick();
        if (tickLower > targetTick || tickUpper <= targetTick) {
            revert TickRangeDoesNotCoverAssignmentPrice(); 
        }

        // Resolve and verify the liquidity pool.
        poolId = getPoolId(); // compute the poolId from the poolKey

        // Compute the liquidity amount from desired token amounts at the current price.
        //    sqrtPriceX96 comes from PoolManager's slot0 for this pool.
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolKey.toId()); // get current sqrt price from pool state
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);  // compute sqrt price at lower tick
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);  // compute sqrt price at upper tick

        // given current price and chosen tick range, how much liquidity do token amounts translate to
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, 
            sqrtPriceLowerX96, 
            sqrtPriceUpperX96, 
            amount0Desired,
            amount1Desired
        );

        // Pull desired token amounts from the caller into this contract.
        // The caller must have approved this contract on both tokens first.
        IERC20 token0 = IERC20(Currency.unwrap(currency0));
        IERC20 token1 = IERC20(Currency.unwrap(currency1));
        if (amount0Desired > 0) token0.transferFrom(msg.sender, address(this), amount0Desired);
        if (amount1Desired > 0) token1.transferFrom(msg.sender, address(this), amount1Desired);

        //  Approve Permit2 so PositionManager can pull tokens from this contract
        //  when it settles the pool deltas (PositionManager calls permit2.transferFrom).
        if (amount0Desired > 0) token0.approve(permit2, amount0Desired);
        if (amount1Desired > 0) token1.approve(permit2, amount1Desired);

        // Prepare PositionManager actions and execute modifyLiquidities.
        // Action bytes: MINT_POSITION followed by SETTLE_PAIR.
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), // action to mint a new liquidity position NFT
            uint8(Actions.SETTLE_PAIR)   // action to settle the pool deltas for the position's currency pair
            );

        bytes[] memory params = new bytes[](2); // array to hold the encoded parameters for each action
        // MINT_POSITION params: (PoolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData)
        params[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            uint256(liquidity), // how much liquidity to mint
            uint128(amount0Desired), //max currency0 to deposit
            uint128(amount1Desired), //max currency1 to deposit
            msg.sender,   // position NFT minted directly to the caller (who gets NFT)
            bytes("") // no hook data
        );
        // SETTLE_PAIR params: illustrate which two tokens (currency0, currency1) to settle payments for
        params[1] = abi.encode(currency0, currency1);

        // Execute the actions in a single transaction. PositionManager will pull the tokens, mint the position, and settle the pool deltas.
        positionManager.modifyLiquidities(
            abi.encode(actions, params), //bundle actions and parameters together
            block.timestamp + 60 // must execute in 60 seconds or fails
        );

        // Verify the mint succeeded - read-in the freshly assigned token-id.
        positionId = positionManager.nextTokenId() - 1;
        require(positionId > 0, "mint failed"); // position IDs start at 1, so if nextTokenId is 1 then no position was minted

        // Return any unspent token dust to the caller, then emit the assignment event.
        uint256 dust0 = token0.balanceOf(address(this));
        uint256 dust1 = token1.balanceOf(address(this));
        if (dust0 > 0) token0.transfer(msg.sender, dust0);
        if (dust1 > 0) token1.transfer(msg.sender, dust1);

        uint128 mintedLiquidity = positionManager.getPositionLiquidity(positionId); // actual liquidity minted for this position from PositionManager
        emit LiquidityMinted(poolId, positionId, msg.sender, tickLower, tickUpper, mintedLiquidity); // emit event with the position details for off-chain indexing and verification
    }
}
