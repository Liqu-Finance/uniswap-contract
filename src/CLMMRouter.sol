// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC721} from "forge-std/interfaces/IERC721.sol";

/// @title CLMMRouter - Concentrated Liquidity Market Maker Helper
/// @notice Simplifies CLMM position management on Uniswap V4 for frontends and agents
/// @dev All functions are stateless helpers — no funds are held by this contract
contract CLMMRouter {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    IPermit2 public immutable permit2;

    constructor(IPoolManager _poolManager, IPositionManager _positionManager, IPermit2 _permit2) {
        poolManager = _poolManager;
        positionManager = _positionManager;
        permit2 = _permit2;
    }

    // ══════════════════════════════════════════════════════
    //  STRUCTS
    // ══════════════════════════════════════════════════════

    struct PoolParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct PositionInfo {
        uint256 tokenId;
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        uint160 sqrtPriceX96;
        int24 currentTick;
        uint256 feeGrowthGlobal0;
        uint256 feeGrowthGlobal1;
    }

    struct PoolState {
        PoolId poolId;
        uint160 sqrtPriceX96;
        int24 tick;
        uint24 protocolFee;
        uint24 lpFee;
        uint128 liquidity;
        uint256 feeGrowthGlobal0;
        uint256 feeGrowthGlobal1;
    }

    // ══════════════════════════════════════════════════════
    //  PURE HELPERS — tick/price conversion (for frontend)
    // ══════════════════════════════════════════════════════

    /// @notice Get the tick from a sqrtPriceX96 value, rounded to tickSpacing
    /// @param sqrtPriceX96 The sqrt price in Q96 format
    /// @param tickSpacing The tick spacing to round to
    /// @return tick The rounded tick
    function sqrtPriceToTick(uint160 sqrtPriceX96, int24 tickSpacing) external pure returns (int24 tick) {
        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        // Round down to nearest tickSpacing
        tick = (tick / tickSpacing) * tickSpacing;
    }

    /// @notice Get the sqrtPriceX96 from a tick
    /// @param tick The tick value
    /// @return sqrtPriceX96 The sqrt price in Q96 format
    function tickToSqrtPrice(int24 tick) external pure returns (uint160 sqrtPriceX96) {
        return TickMath.getSqrtPriceAtTick(tick);
    }

    /// @notice Get valid tick bounds for a tick spacing
    /// @param tickSpacing The tick spacing
    /// @return minTick The minimum usable tick
    /// @return maxTick The maximum usable tick
    function getTickBounds(int24 tickSpacing) external pure returns (int24 minTick, int24 maxTick) {
        minTick = TickMath.minUsableTick(tickSpacing);
        maxTick = TickMath.maxUsableTick(tickSpacing);
    }

    // ══════════════════════════════════════════════════════
    //  READ FUNCTIONS — pool & position state
    // ══════════════════════════════════════════════════════

    /// @notice Get full pool state
    /// @param params Pool parameters
    /// @return state The pool state
    function getPoolState(PoolParams calldata params) external view returns (PoolState memory state) {
        PoolKey memory poolKey = _toPoolKey(params);
        state.poolId = poolKey.toId();

        (state.sqrtPriceX96, state.tick, state.protocolFee, state.lpFee) =
            poolManager.getSlot0(state.poolId);

        state.liquidity = poolManager.getLiquidity(state.poolId);

        (state.feeGrowthGlobal0, state.feeGrowthGlobal1) =
            poolManager.getFeeGrowthGlobals(state.poolId);
    }

    /// @notice Get position info by token ID
    /// @param tokenId The NFT token ID
    /// @return info Position details
    function getPosition(uint256 tokenId) external view returns (PositionInfo memory info) {
        info.tokenId = tokenId;
        info.liquidity = positionManager.getPositionLiquidity(tokenId);

        (PoolKey memory poolKey, ) = positionManager.getPoolAndPositionInfo(tokenId);
        PoolId poolId = poolKey.toId();

        (info.sqrtPriceX96, info.currentTick, , ) = poolManager.getSlot0(poolId);
        (info.feeGrowthGlobal0, info.feeGrowthGlobal1) = poolManager.getFeeGrowthGlobals(poolId);
    }

    /// @notice Get all positions for a user (scans token IDs)
    /// @param user The user address
    /// @param startTokenId Start scanning from this token ID
    /// @param maxScan Maximum number of IDs to scan
    /// @return tokenIds Array of token IDs owned by user
    /// @return count Number of positions found
    function getUserPositions(
        address user,
        uint256 startTokenId,
        uint256 maxScan
    ) external view returns (uint256[] memory tokenIds, uint256 count) {
        uint256 nextId = positionManager.nextTokenId();
        uint256 endId = startTokenId + maxScan;
        if (endId > nextId) endId = nextId;

        // First pass: count
        tokenIds = new uint256[](maxScan);
        for (uint256 id = startTokenId; id < endId; id++) {
            try IERC721(address(positionManager)).ownerOf(id) returns (address owner) {
                if (owner == user) {
                    tokenIds[count] = id;
                    count++;
                }
            } catch {
                continue;
            }
        }

        // Trim array
        assembly {
            mstore(tokenIds, count)
        }
    }

    // ══════════════════════════════════════════════════════
    //  WRITE FUNCTIONS — position management
    // ══════════════════════════════════════════════════════

    /// @notice Approve tokens for the Uniswap V4 flow: ERC20 -> Permit2 -> PositionManager
    /// @dev User must call this before minting/increasing. Only needs to be done once per token.
    /// @param token The ERC20 token to approve
    function approveToken(address token) external {
        IERC20(token).approve(address(permit2), type(uint256).max);
        permit2.approve(token, address(positionManager), type(uint160).max, type(uint48).max);
    }

    /// @notice Create a new pool with initial price
    /// @param params Pool parameters
    /// @param sqrtPriceX96 Initial sqrt price
    /// @return tick The initial tick
    function createPool(PoolParams calldata params, uint160 sqrtPriceX96) external returns (int24 tick) {
        PoolKey memory poolKey = _toPoolKey(params);
        tick = positionManager.initializePool(poolKey, sqrtPriceX96);
    }

    /// @notice Mint a new CLMM position
    /// @dev Caller must have approved tokens via approveToken() first.
    ///      Tokens are pulled from msg.sender via Permit2.
    /// @param params Pool parameters
    /// @param tickLower Lower tick of the position (must be multiple of tickSpacing)
    /// @param tickUpper Upper tick of the position (must be multiple of tickSpacing)
    /// @param liquidity Amount of liquidity to mint
    /// @param amount0Max Maximum token0 to spend (slippage protection)
    /// @param amount1Max Maximum token1 to spend (slippage protection)
    /// @param recipient Address to receive the position NFT
    /// @param deadline Transaction deadline
    function mintPosition(
        PoolParams calldata params,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        address recipient,
        uint256 deadline
    ) external payable {
        PoolKey memory poolKey = _toPoolKey(params);

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR),
            uint8(Actions.SWEEP),
            uint8(Actions.SWEEP)
        );

        bytes[] memory mintParams = new bytes[](4);
        mintParams[0] = abi.encode(
            poolKey, tickLower, tickUpper, liquidity,
            amount0Max, amount1Max, recipient, bytes("")
        );
        mintParams[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        mintParams[2] = abi.encode(poolKey.currency0, recipient);
        mintParams[3] = abi.encode(poolKey.currency1, recipient);

        uint256 valueToPass = poolKey.currency0.isAddressZero() ? amount0Max : 0;
        positionManager.modifyLiquidities{value: valueToPass}(
            abi.encode(actions, mintParams),
            deadline
        );
    }

    /// @notice Increase liquidity on an existing position
    /// @param tokenId The NFT token ID
    /// @param liquidity Amount of liquidity to add
    /// @param amount0Max Maximum token0 to spend
    /// @param amount1Max Maximum token1 to spend
    /// @param deadline Transaction deadline
    function increaseLiquidity(
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        uint256 deadline
    ) external payable {
        (PoolKey memory poolKey, ) = positionManager.getPoolAndPositionInfo(tokenId);

        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY),
            uint8(Actions.CLOSE_CURRENCY),
            uint8(Actions.CLOSE_CURRENCY)
        );

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(tokenId, liquidity, amount0Max, amount1Max, bytes(""));
        params[1] = abi.encode(poolKey.currency0);
        params[2] = abi.encode(poolKey.currency1);

        uint256 valueToPass = poolKey.currency0.isAddressZero() ? amount0Max : 0;
        positionManager.modifyLiquidities{value: valueToPass}(
            abi.encode(actions, params),
            deadline
        );
    }

    /// @notice Decrease liquidity from an existing position (partial withdraw)
    /// @param tokenId The NFT token ID
    /// @param liquidity Amount of liquidity to remove
    /// @param amount0Min Minimum token0 to receive (slippage protection)
    /// @param amount1Min Minimum token1 to receive (slippage protection)
    /// @param recipient Address to receive the tokens
    /// @param deadline Transaction deadline
    function decreaseLiquidity(
        uint256 tokenId,
        uint128 liquidity,
        uint128 amount0Min,
        uint128 amount1Min,
        address recipient,
        uint256 deadline
    ) external {
        (PoolKey memory poolKey, ) = positionManager.getPoolAndPositionInfo(tokenId);

        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.TAKE_PAIR)
        );

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidity, amount0Min, amount1Min, bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, recipient);

        positionManager.modifyLiquidities(abi.encode(actions, params), deadline);
    }

    /// @notice Close a position entirely: remove all liquidity + burn NFT
    /// @param tokenId The NFT token ID
    /// @param amount0Min Minimum token0 to receive
    /// @param amount1Min Minimum token1 to receive
    /// @param recipient Address to receive the tokens
    /// @param deadline Transaction deadline
    function closePosition(
        uint256 tokenId,
        uint128 amount0Min,
        uint128 amount1Min,
        address recipient,
        uint256 deadline
    ) external {
        (PoolKey memory poolKey, ) = positionManager.getPoolAndPositionInfo(tokenId);

        bytes memory actions = abi.encodePacked(
            uint8(Actions.BURN_POSITION),
            uint8(Actions.TAKE_PAIR)
        );

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, amount0Min, amount1Min, bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, recipient);

        positionManager.modifyLiquidities(abi.encode(actions, params), deadline);
    }

    // ══════════════════════════════════════════════════════
    //  INTERNAL
    // ══════════════════════════════════════════════════════

    function _toPoolKey(PoolParams memory params) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(params.token0),
            currency1: Currency.wrap(params.token1),
            fee: params.fee,
            tickSpacing: params.tickSpacing,
            hooks: IHooks(params.hooks)
        });
    }
}
