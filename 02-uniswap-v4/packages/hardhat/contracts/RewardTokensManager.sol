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

/// @dev Minimal interface to retrieve the Permit2 address stored on PositionManager.
interface IPermit2Provider {
    function permit2() external view returns (address);
}

/// @notice Manages a Uniswap v4 PNPT/FNBT liquidity pool:
///         creates the pool and mints concentrated liquidity positions.
contract RewardTokensManager is Ownable {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ─── Pool constants ────────────────────────────────────────────────────────
    uint24  public constant FEE_TIER     = 3000;      // 0.30 % swap fee
    int24   public constant TICK_SPACING = 60;        // standard spacing for 0.30 %
    address public constant HOOKS        = address(0); // no hooks

    // ─── Economic target tick ──────────────────────────────────────────────────
    // 1 FNBT (eBucks, R0.10) = 10 PNPT (Smart Shopper, R0.01)
    // price = currency1 / currency0  =  1.0001^tick
    // tick  = floor( ln(price) / ln(1.0001) )
    //
    // If PNPT < FNBT (address order): c0=PNPT, c1=FNBT
    //   price = 0.1  →  tick = floor(-23027.05) = -23028
    // If FNBT < PNPT:                 c0=FNBT, c1=PNPT
    //   price = 10   →  tick = floor( 23027.05) =  23027
    int24 private constant TARGET_TICK_PNPT_AS_C0 = -23028;
    int24 private constant TARGET_TICK_FNBT_AS_C0 =  23027;

    // ─── Immutables ────────────────────────────────────────────────────────────
    IPoolManager     public immutable poolManager;
    IPositionManager public immutable positionManager;
    IERC20           public immutable pnpToken;
    IERC20           public immutable fnbToken;
    address          public immutable permit2;   // Permit2 used by PositionManager

    // ─── Pool state ────────────────────────────────────────────────────────────
    Currency public currency0;
    Currency public currency1;
    PoolKey  public poolKey;

    /// @notice Tracks which poolIds this contract has initialised.
    mapping(bytes32 => bool) public createdPools;

    // ─── Events ────────────────────────────────────────────────────────────────
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

    // ─── Errors ────────────────────────────────────────────────────────────────
    error TickRangeDoesNotCoverAssignmentPrice();

    // ─── Constructor ───────────────────────────────────────────────────────────
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

        // Retrieve Permit2 address from PositionManager so we can approve it later.
        permit2 = IPermit2Provider(_positionManager).permit2();

        // Canonical ordering: lower address = currency0 (Uniswap convention).
        if (_pnpToken < _fnbToken) {
            currency0 = Currency.wrap(_pnpToken);
            currency1 = Currency.wrap(_fnbToken);
        } else {
            currency0 = Currency.wrap(_fnbToken);
            currency1 = Currency.wrap(_pnpToken);
        }
        
        poolKey = PoolKey({
            currency0:   currency0,
            currency1:   currency1,
            fee:         FEE_TIER,
            tickSpacing: TICK_SPACING,
            hooks:       IHooks(HOOKS)
        });
    }

    // ─── View helpers ──────────────────────────────────────────────────────────

    /// @notice Returns the assignment's implied target tick for the FNBT/PNPT pair.
    ///         Derived from 1 FNBT = 10 PNPT (price = c1/c0 = 1.0001^tick).
    function getTargetTick() public view returns (int24) {
        if (Currency.unwrap(currency0) == address(pnpToken)) {
            return TARGET_TICK_PNPT_AS_C0; // c0=PNPT, c1=FNBT → price=0.1 → -23028
        } else {
            return TARGET_TICK_FNBT_AS_C0; // c0=FNBT, c1=PNPT → price=10  →  23027
        }
    }

    /// @notice Returns the poolId for the PNPT/FNBT pool managed by this contract.
    function getPoolId() public view returns (bytes32) {
        return PoolId.unwrap(poolKey.toId());
    }

    /// @notice Returns the canonical (sorted) token addresses used as pool currencies.
    function getCanonicalCurrencies() external view returns (address, address) {
        return (Currency.unwrap(currency0), Currency.unwrap(currency1));
    }

    // ─── Part 2: Pool creation ─────────────────────────────────────────────────

    /// @notice Initialises the PNPT/FNBT pool in PoolManager at the given starting price.
    /// @dev    Restricted to the owner (onlyOwner) so that only the deployer can set the
    ///         pool's starting sqrtPriceX96. Without this guard any caller could initialise
    ///         the pool at an arbitrary or manipulated price before the owner does.
    /// @param sqrtPriceX96 Starting sqrt price (Q96 fixed-point) for the pool.
    /// @return poolId The keccak256 pool identifier derived from the pool key.
    function createPool(uint160 sqrtPriceX96) external onlyOwner returns (bytes32 poolId) {
        poolId = getPoolId();

        // Initialise the pool inside the singleton PoolManager.
        poolManager.initialize(poolKey, sqrtPriceX96);

        createdPools[poolId] = true;

        emit PoolCreated(
            poolId,
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            FEE_TIER,
            TICK_SPACING,
            HOOKS,
            sqrtPriceX96
        );
    }

    // ─── Part 3: Mint liquidity ────────────────────────────────────────────────

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

        // 1) Validate inputs and tick constraints.
        require(tickLower < tickUpper,                    "bad tick range");
        require(tickLower % TICK_SPACING == 0,            "tickLower not aligned");
        require(tickUpper % TICK_SPACING == 0,            "tickUpper not aligned");
        require(amount0Desired > 0 || amount1Desired > 0, "zero amounts");

        // 2) Ensure the chosen range covers the assignment's implied target tick.
        //    The range is valid when tickLower <= targetTick < tickUpper.
        int24 targetTick = getTargetTick();
        if (tickLower > targetTick || tickUpper <= targetTick) {
            revert TickRangeDoesNotCoverAssignmentPrice();
        }

        // 3) Resolve and verify the liquidity pool.
        poolId = getPoolId();

        // 4) Compute the liquidity amount from desired token deposits at the current price.
        //    sqrtPriceX96 comes from PoolManager's slot0 for this pool.
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolKey.toId());
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceLowerX96,
            sqrtPriceUpperX96,
            amount0Desired,
            amount1Desired
        );

        // 5) Pull desired token amounts from the caller into this contract.
        //    The caller must have approved this contract on both tokens first.
        IERC20 token0 = IERC20(Currency.unwrap(currency0));
        IERC20 token1 = IERC20(Currency.unwrap(currency1));
        if (amount0Desired > 0) token0.transferFrom(msg.sender, address(this), amount0Desired);
        if (amount1Desired > 0) token1.transferFrom(msg.sender, address(this), amount1Desired);

        // 6) Approve Permit2 so PositionManager can pull tokens from this contract
        //    when it settles the pool deltas (PositionManager calls permit2.transferFrom).
        if (amount0Desired > 0) token0.approve(permit2, amount0Desired);
        if (amount1Desired > 0) token1.approve(permit2, amount1Desired);

        // 7) Prepare PositionManager actions and execute modifyLiquidities.
        //    Action bytes: MINT_POSITION followed by SETTLE_PAIR.
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );

        bytes[] memory params = new bytes[](2);
        // MINT_POSITION params: (PoolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData)
        params[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            uint256(liquidity),
            uint128(amount0Desired),
            uint128(amount1Desired),
            msg.sender,   // position NFT minted directly to the caller
            bytes("")
        );
        // SETTLE_PAIR params: (currency0, currency1)
        params[1] = abi.encode(currency0, currency1);

        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 60
        );

        // 8) Verify the mint succeeded by reading the freshly assigned token-id.
        positionId = positionManager.nextTokenId() - 1;
        require(positionId > 0, "mint failed");

        // 9) Return any unspent token dust to the caller, then emit the assignment event.
        uint256 dust0 = token0.balanceOf(address(this));
        uint256 dust1 = token1.balanceOf(address(this));
        if (dust0 > 0) token0.transfer(msg.sender, dust0);
        if (dust1 > 0) token1.transfer(msg.sender, dust1);

        uint128 mintedLiquidity = positionManager.getPositionLiquidity(positionId);
        emit LiquidityMinted(poolId, positionId, msg.sender, tickLower, tickUpper, mintedLiquidity);
    }
}
