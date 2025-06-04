// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import "contracts/core/libraries/SafeCast.sol";
import "contracts/core/libraries/TickMath.sol";
import "contracts/core/interfaces/ICLPool.sol";

import "./interfaces/ISwapRouter.sol";
import "./base/PeripheryImmutableState.sol";
import "./base/PeripheryValidation.sol";
import "./base/PeripheryPaymentsWithFee.sol";
import "./base/Multicall.sol";
import "./base/SelfPermit.sol";
import "./libraries/Path.sol";
import "./libraries/PoolAddress.sol";
import "./libraries/CallbackValidation.sol";
import "./interfaces/external/IWETH9.sol";

/// @title Concentrated Liquidity Swap Router
/// @notice Provides a router for performing token swaps against Concentrated Liquidity (CL) pools.
/// This contract enables single-hop and multi-hop swaps with exact input or exact output amounts.
/// It interacts with CL pool contracts and handles payments, including ETH wrapping/unwrapping.
contract SwapRouter is
    ISwapRouter,
    PeripheryImmutableState,
    PeripheryValidation,
    PeripheryPaymentsWithFee,
    Multicall,
    SelfPermit
{
    using Path for bytes;
    using SafeCast for uint256;

    /// @dev Placeholder value for `amountInCached` to indicate it's not set.
    /// This value is chosen because the computed `amountIn` for an exact output swap can never be `type(uint256).max`.
    uint256 private constant DEFAULT_AMOUNT_IN_CACHED = type(uint256).max;

    /// @dev Transient storage variable to store the computed `amountIn` for an exact output multi-hop swap.
    /// It's set in the callback from the last pool and read in the `exactOutput` function.
    uint256 private amountInCached = DEFAULT_AMOUNT_IN_CACHED;

    /// @notice Constructor that initializes the immutable factory and WETH9 addresses.
    /// @param _factory The address of the CL factory contract.
    /// @param _WETH9 The address of the WETH9 contract.
    constructor(address _factory, address _WETH9) PeripheryImmutableState(_factory, _WETH9) {}

    /// @dev Returns the ICLPool instance for a given token pair and tick spacing.
    /// @notice The pool contract address is computed deterministically and may or may not exist yet.
    /// @param tokenA Address of the first token.
    /// @param tokenB Address of the second token.
    /// @param tickSpacing The tick spacing of the pool.
    /// @return pool The ICLPool interface for the specified pool.
    function getPool(address tokenA, address tokenB, int24 tickSpacing) private view returns (ICLPool) {
        return ICLPool(PoolAddress.computeAddress(factory, PoolAddress.getPoolKey(tokenA, tokenB, tickSpacing)));
    }

    /// @notice Data struct passed to the pool's swap callback.
    struct SwapCallbackData {
        bytes path; // The encoded path of the swap.
        address payer; // The address that should pay for the swap input.
    }

    /// @inheritdoc ICLSwapCallback
    /// @notice Callback function called by a CL pool during a swap.
    /// @dev This function is responsible for processing payments for the swap.
    /// For exact input swaps, it pays the required input tokens to the pool.
    /// For exact output swaps, it handles the received input tokens:
    ///   - If it's a multi-hop swap, it initiates the next swap in the path.
    ///   - If it's the last hop, it caches the input amount and pays the tokens to the pool.
    /// @param amount0Delta The change in the pool's token0 balance.
    /// @param amount1Delta The change in the pool's token1 balance.
    /// @param _data The abi-encoded SwapCallbackData.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata _data) external override {
        // Swaps entirely within 0-liquidity regions are not supported as they don't result in token transfers.
        require(amount0Delta > 0 || amount1Delta > 0, "SwapRouter: NO_TOKENS_SWAPPED");
        SwapCallbackData memory data = abi.decode(_data, (SwapCallbackData));
        (address tokenIn, address tokenOut, int24 tickSpacing) = data.path.decodeFirstPool();

        // Ensure the callback is from a legitimate pool created by the factory.
        CallbackValidation.verifyCallback(factory, tokenIn, tokenOut, tickSpacing);

        // Determine if it's an exact input swap and the amount to pay.
        // amount0Delta > 0 means token0 is the input if zeroForOne (tokenIn < tokenOut) is true.
        // amount1Delta > 0 means token1 is the input if zeroForOne (tokenIn < tokenOut) is false.
        (bool isExactInput, uint256 amountToPay) =
            amount0Delta > 0
                ? (tokenIn < tokenOut, uint256(amount0Delta)) // token0 is input
                : (tokenOut < tokenIn, uint256(amount1Delta)); // token1 is input

        if (isExactInput) {
            // For exact input, pay the pool the specified input amount.
            pay(tokenIn, data.payer, msg.sender, amountToPay);
        } else {
            // For exact output:
            if (data.path.hasMultiplePools()) {
                // If there are more pools in the path, skip the current token (which is now input for next hop)
                // and initiate the next exact output swap. The recipient for this intermediate swap is this router.
                data.path = data.path.skipToken();
                exactOutputInternal(amountToPay, msg.sender, 0, data); // amountToPay is the output for the *next* hop
            } else {
                // This is the first hop of an exact output swap (or the only hop).
                // Cache the amount of tokenIn required for this hop.
                amountInCached = amountToPay;
                // The tokenIn for payment is the tokenOut of the current path segment because exact output swaps are processed in reverse.
                // The actual payment happens here.
                pay(tokenOut, data.payer, msg.sender, amountToPay); // tokenOut here is the actual input token for this pool hop
            }
        }
    }

    /// @dev Internal function to perform a single-hop exact input swap.
    /// @param amountIn The amount of input tokens.
    /// @param recipient The address to receive the output tokens.
    /// @param sqrtPriceLimitX96 The price limit for the swap.
    /// @param data The SwapCallbackData containing the path and payer.
    /// @return amountOut The amount of output tokens received.
    function exactInputInternal(
        uint256 amountIn,
        address recipient,
        uint160 sqrtPriceLimitX96,
        SwapCallbackData memory data
    ) private returns (uint256 amountOut) {
        // Allow swapping to address(0) to mean swapping to this router contract.
        if (recipient == address(0)) recipient = address(this);

        (address tokenIn, address tokenOut, int24 tickSpacing) = data.path.decodeFirstPool();
        bool zeroForOne = tokenIn < tokenOut; // Determine swap direction.

        // Call swap on the CL pool.
        (int256 amount0Delta, int256 amount1Delta) = getPool(tokenIn, tokenOut, tickSpacing).swap(
            recipient, // The recipient of the output tokens.
            zeroForOne, // The direction of the swap.
            amountIn.toInt256(), // The exact amount of tokens to input.
            sqrtPriceLimitX96 == 0 // If no price limit is set, use the default min/max.
                ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                : sqrtPriceLimitX96,
            abi.encode(data) // Pass callback data.
        );
        // Output amount is the negative of the delta of the output token.
        return uint256(-(zeroForOne ? amount1Delta : amount0Delta));
    }

    /// @inheritdoc ISwapRouter
    /// @notice Swaps an exact amount of input tokens for as many output tokens as possible in a single pool.
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline) // Ensures the transaction is executed before the deadline.
        returns (uint256 amountOut)
    {
        // Perform the single-hop exact input swap.
        amountOut = exactInputInternal(
            params.amountIn,
            params.recipient,
            params.sqrtPriceLimitX96,
            SwapCallbackData({
                // Encode the path for a single hop.
                path: abi.encodePacked(params.tokenIn, params.tickSpacing, params.tokenOut),
                payer: msg.sender // The caller pays for the input tokens.
            })
        );
        // Ensure the amount of output tokens received is not less than the minimum specified.
        require(amountOut >= params.amountOutMinimum, "SwapRouter: TOO_LITTLE_RECEIVED");
        refundETH(); // Refund any unused ETH sent with the transaction.
    }

    /// @inheritdoc ISwapRouter
    /// @notice Swaps an exact amount of input tokens for as many output tokens as possible through a series of pools.
    function exactInput(ExactInputParams memory params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 amountOut)
    {
        address payer = msg.sender; // The caller pays for the first hop.
        address recipient = params.recipient;

        // Iterate through the swap path.
        while (true) {
            bool hasMultiplePools = params.path.hasMultiplePools();

            // The output of the previous swap becomes the input for the current swap.
            params.amountIn = exactInputInternal(
                params.amountIn,
                // For intermediate hops, this router contract custodies the tokens.
                // For the last hop, tokens are sent to the final recipient.
                hasMultiplePools ? address(this) : recipient,
                0, // No sqrtPriceLimitX96 for intermediate hops of a multi-hop exact input swap.
                SwapCallbackData({
                    path: params.path.getFirstPool(), // Process only the first pool in the remaining path.
                    payer: payer
                })
            );

            // If there are more pools, continue to the next hop.
            if (hasMultiplePools) {
                payer = address(this); // For subsequent hops, this router contract is the payer.
                params.path = params.path.skipToken(); // Advance the path.
            } else {
                // This was the last hop.
                amountOut = params.amountIn;
                break;
            }
        }
        // Ensure the final amount of output tokens received is not less than the minimum specified.
        require(amountOut >= params.amountOutMinimum, "SwapRouter: TOO_LITTLE_RECEIVED");
        refundETH(); // Refund any unused ETH.
    }

    /// @dev Internal function to perform a single-hop exact output swap.
    /// @param amountOut The amount of output tokens desired.
    /// @param recipient The address to receive the output tokens.
    /// @param sqrtPriceLimitX96 The price limit for the swap.
    /// @param data The SwapCallbackData containing the path and payer.
    /// @return amountIn The amount of input tokens required.
    function exactOutputInternal(
        uint256 amountOut,
        address recipient,
        uint160 sqrtPriceLimitX96,
        SwapCallbackData memory data
    ) private returns (uint256 amountIn) {
        // Allow swapping to address(0) to mean swapping to this router contract.
        if (recipient == address(0)) recipient = address(this);

        // For exact output, the path is decoded in reverse (tokenOut is the first token in path).
        (address tokenOut, address tokenIn, int24 tickSpacing) = data.path.decodeFirstPool();
        bool zeroForOne = tokenIn < tokenOut; // Determine swap direction based on actual token order.

        // Call swap on the CL pool with a negative amount for exact output.
        (int256 amount0Delta, int256 amount1Delta) = getPool(tokenIn, tokenOut, tickSpacing).swap(
            recipient, // The recipient of the output tokens.
            zeroForOne, // The direction of the swap.
            -amountOut.toInt256(), // Negative amount to specify exact output.
            sqrtPriceLimitX96 == 0 // If no price limit is set, use the default min/max.
                ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                : sqrtPriceLimitX96,
            abi.encode(data) // Pass callback data.
        );

        uint256 amountOutReceived;
        // Determine input and output amounts based on deltas and swap direction.
        (amountIn, amountOutReceived) = zeroForOne
            ? (uint256(amount0Delta), uint256(-amount1Delta)) // amount0 is input, amount1 is output
            : (uint256(amount1Delta), uint256(-amount0Delta)); // amount1 is input, amount0 is output

        // It's technically possible to not receive the full output amount if the price limit is hit.
        // If no price limit was specified, require that the full output amount was received.
        if (sqrtPriceLimitX96 == 0) require(amountOutReceived == amountOut, "SwapRouter: INSUFFICIENT_OUTPUT_RECEIVED");
        return amountIn;
    }

    /// @inheritdoc ISwapRouter
    /// @notice Swaps as little input tokens as possible for an exact amount of output tokens in a single pool.
    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 amountIn)
    {
        // Perform the single-hop exact output swap.
        // The path is encoded with tokenOut first, then tickSpacing, then tokenIn.
        amountIn = exactOutputInternal(
            params.amountOut,
            params.recipient,
            params.sqrtPriceLimitX96,
            SwapCallbackData({
                path: abi.encodePacked(params.tokenOut, params.tickSpacing, params.tokenIn),
                payer: msg.sender // The caller pays for the input tokens.
            })
        );

        // Ensure the amount of input tokens required is not more than the maximum specified.
        require(amountIn <= params.amountInMaximum, "SwapRouter: TOO_MUCH_REQUESTED");
        // Reset amountInCached as it's not used for single hops directly but good practice.
        amountInCached = DEFAULT_AMOUNT_IN_CACHED;
        refundETH(); // Refund any unused ETH.
    }

    /// @inheritdoc ISwapRouter
    /// @notice Swaps as little input tokens as possible for an exact amount of output tokens through a series of pools.
    /// @dev For multi-hop exact output, swaps are processed in reverse order of the path.
    /// The callback from the *first actual pool swapped against* (last in path) will set `amountInCached`.
    function exactOutput(ExactOutputParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 amountIn)
    {
        // The payer is msg.sender for the first call to exactOutputInternal.
        // This first call corresponds to the *last* swap in the path (e.g., USDC -> WETH for a DAI -> WETH swap).
        // The `amountOut` of this call is `params.amountOut` (the final desired output).
        // The `recipient` is `params.recipient` (the final recipient).
        // The `path` for this call is the full path. exactOutputInternal will decode the first segment (tokenOut, tokenIn for that hop).
        exactOutputInternal(
            params.amountOut,
            params.recipient,
            0, // No sqrtPriceLimitX96 for intermediate hops of a multi-hop exact output swap (handled in callback logic).
            SwapCallbackData({path: params.path, payer: msg.sender})
        );

        // `amountInCached` is populated by the callback from the *first pool in the path* (last pool executed in the chain of callbacks).
        amountIn = amountInCached;
        // Ensure the total input amount required is not more than the maximum specified.
        require(amountIn <= params.amountInMaximum, "SwapRouter: TOO_MUCH_REQUESTED");
        // Reset amountInCached for the next transaction.
        amountInCached = DEFAULT_AMOUNT_IN_CACHED;
        refundETH(); // Refund any unused ETH.
    }
}
