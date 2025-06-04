// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import "./interfaces/ICLPool.sol";

import "./libraries/LowGasSafeMath.sol";
import "./libraries/SafeCast.sol";
import "./libraries/Tick.sol";
import "./libraries/TickBitmap.sol";
import "./libraries/Position.sol";
import "./libraries/Oracle.sol";

import "./libraries/FullMath.sol";
import "./libraries/FixedPoint128.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/TickMath.sol";
import "./libraries/LiquidityMath.sol";
import "./libraries/SqrtPriceMath.sol";
import "./libraries/SwapMath.sol";

import "./interfaces/ICLFactory.sol";
import "./interfaces/IERC20Minimal.sol";
import "./interfaces/callback/ICLMintCallback.sol";
import "./interfaces/callback/ICLSwapCallback.sol";
import "./interfaces/callback/ICLFlashCallback.sol";
import "contracts/libraries/VelodromeTimeLibrary.sol";

/// @title Concentrated Liquidity Pool
/// @notice A contract that allows for concentrated liquidity provision and swapping of two tokens.
/// It implements the ICLPool interface and utilizes several libraries for math and data structures.
contract CLPool is ICLPool {
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using Oracle for Oracle.Observation[65535];

    /// @inheritdoc ICLPoolConstants
    address public override factory;
    /// @inheritdoc ICLPoolConstants
    address public override token0;
    /// @inheritdoc ICLPoolConstants
    address public override token1;
    /// @inheritdoc ICLPoolConstants
    address public override gauge;
    /// @inheritdoc ICLPoolConstants
    address public override nft;

    /// @notice Stores the core state of the pool that is frequently accessed.
    struct Slot0 {
        /// @notice The current price of the pool as a sqrt(token1/token0) Q64.96 value.
        uint160 sqrtPriceX96;
        /// @notice The current tick.
        int24 tick;
        /// @notice The most-recently updated index of the observations array.
        uint16 observationIndex;
        /// @notice The current maximum number of observations that are being stored.
        uint16 observationCardinality;
        /// @notice The next maximum number of observations to store, triggered in observations.write.
        uint16 observationCardinalityNext;
        /// @notice Whether the pool is locked (reentrancy guard).
        bool unlocked;
    }

    /// @inheritdoc ICLPoolState
    Slot0 public override slot0;

    /// @inheritdoc ICLPoolState
    /// @notice The fee growth of token0 per unit of liquidity as a Q128.128 value.
    uint256 public override feeGrowthGlobal0X128;
    /// @inheritdoc ICLPoolState
    /// @notice The fee growth of token1 per unit of liquidity as a Q128.128 value.
    uint256 public override feeGrowthGlobal1X128;

    /// @inheritdoc ICLPoolState
    /// @notice The reward growth per unit of staked liquidity as a Q128.128 value.
    uint256 public override rewardGrowthGlobalX128;

    /// @notice Accumulated gauge fees in token0/token1 units.
    struct GaugeFees {
        uint128 token0;
        uint128 token1;
    }

    /// @inheritdoc ICLPoolState
    GaugeFees public override gaugeFees;

    /// @inheritdoc ICLPoolState
    /// @notice The rate at which rewards are distributed per second.
    uint256 public override rewardRate;
    /// @inheritdoc ICLPoolState
    /// @notice The total amount of rewards remaining to be distributed.
    uint256 public override rewardReserve;
    /// @inheritdoc ICLPoolState
    /// @notice The timestamp when the current reward period finishes.
    uint256 public override periodFinish;
    /// @inheritdoc ICLPoolState
    /// @notice Amount of rewards that were not distributed because there was no staked liquidity.
    uint256 public override rollover;

    /// @inheritdoc ICLPoolState
    /// @notice The total amount of staked liquidity in the pool.
    uint128 public override stakedLiquidity;
    /// @inheritdoc ICLPoolState
    /// @notice The timestamp of the last reward update.
    uint32 public override lastUpdated;
    /// @inheritdoc ICLPoolConstants
    /// @notice The spacing between usable ticks.
    int24 public override tickSpacing;

    /// @inheritdoc ICLPoolState
    /// @notice The current liquidity in the pool.
    uint128 public override liquidity;
    /// @inheritdoc ICLPoolConstants
    /// @notice The maximum amount of liquidity that can be added to a single tick.
    uint128 public override maxLiquidityPerTick;

    /// @inheritdoc ICLPoolState
    /// @notice Mapping from tick index to tick information.
    mapping(int24 => Tick.Info) public override ticks;
    /// @inheritdoc ICLPoolState
    /// @notice Mapping from word index to a bitmap of initialized ticks within that word.
    mapping(int16 => uint256) public override tickBitmap;
    /// @inheritdoc ICLPoolState
    /// @notice Mapping from position key to position information.
    mapping(bytes32 => Position.Info) public override positions;
    /// @inheritdoc ICLPoolState
    /// @notice Array of price observations for oracle functionality.
    Oracle.Observation[65535] public override observations;

    /// @dev Mutually exclusive reentrancy protection into the pool to/from a method. This method also prevents entrance
    /// to a function before the pool is initialized. The reentrancy guard is required throughout the contract because
    /// we use balance checks to determine the payment status of interactions such as mint, swap and flash.
    modifier lock() {
        require(slot0.unlocked, "CLPool: LOCKED"); // LOK
        slot0.unlocked = false;
        _;
        slot0.unlocked = true;
    }

    /// @dev Prevents calling a function from anyone except the gauge associated with this pool.
    modifier onlyGauge() {
        require(msg.sender == gauge, "CLPool: NOT_GAUGE");
        _;
    }

    /// @dev Prevents calling a function from anyone except the NFT manager.
    modifier onlyNftManager() {
        require(msg.sender == nft, "CLPool: NOT_NFT_MANAGER"); // NNFT
        _;
    }

    /// @inheritdoc ICLPoolActions
    /// @notice Initializes the pool with the given parameters.
    /// @dev Can only be called once by the factory.
    /// @param _factory The address of the CLFactory contract.
    /// @param _token0 The address of the first token.
    /// @param _token1 The address of the second token.
    /// @param _tickSpacing The spacing between usable ticks.
    /// @param _gauge The address of the gauge contract associated with this pool.
    /// @param _nft The address of the non-fungible position manager.
    /// @param _sqrtPriceX96 The initial square root price of the pool, encoded as Q64.96.
    function initialize(
        address _factory,
        address _token0,
        address _token1,
        int24 _tickSpacing,
        address _gauge,
        address _nft,
        uint160 _sqrtPriceX96
    ) external override {
        require(factory == address(0), "CLPool: ALREADY_INITIALIZED");
        require(_factory != address(0), "CLPool: ZERO_ADDRESS_FACTORY");
        factory = _factory;
        token0 = _token0;
        token1 = _token1;
        tickSpacing = _tickSpacing;
        gauge = _gauge;
        nft = _nft;

        maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(_tickSpacing);

        int24 tick = TickMath.getTickAtSqrtRatio(_sqrtPriceX96);

        // Initialize the oracle observations array.
        (uint16 cardinality, uint16 cardinalityNext) = observations.initialize(_blockTimestamp());

        slot0 = Slot0({
            sqrtPriceX96: _sqrtPriceX96,
            tick: tick,
            observationIndex: 0,
            observationCardinality: cardinality,
            observationCardinalityNext: cardinalityNext,
            unlocked: true // Pool is unlocked by default after initialization.
        });

        emit Initialize(_sqrtPriceX96, tick);
    }

    /// @inheritdoc ICLPoolReadOnly
    /// @notice Returns the current swap fee for the pool.
    /// @return The swap fee in hundredths of a bip (1e-6).
    function fee() public view override returns (uint24) {
        return ICLFactory(factory).getSwapFee(address(this));
    }

    /// @inheritdoc ICLPoolReadOnly
    /// @notice Returns the current unstaked fee for the pool.
    /// @return The unstaked fee in hundredths of a bip (1e-6).
    function unstakedFee() public view override returns (uint24) {
        return ICLFactory(factory).getUnstakedFee(address(this));
    }

    /// @dev Common checks for valid tick inputs.
    /// @param tickLower The lower tick.
    /// @param tickUpper The upper tick.
    function checkTicks(int24 tickLower, int24 tickUpper) private pure {
        require(tickLower < tickUpper, "CLPool: TICK_LOWER_GE_TICK_UPPER"); // TLU
        require(tickLower >= TickMath.MIN_TICK, "CLPool: TICK_LOWER_LESS_MIN_TICK"); // TLM
        require(tickUpper <= TickMath.MAX_TICK, "CLPool: TICK_UPPER_GREATER_MAX_TICK"); // TUM
    }

    /// @dev Returns the block timestamp truncated to 32 bits, i.e. mod 2**32. This method is overridden in tests.
    /// @return The block timestamp as a uint32.
    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp); // truncation is desired
    }

    /// @dev Get the pool's balance of token0.
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize check.
    /// @return The pool's balance of token0.
    function balance0() private view returns (uint256) {
        (bool success, bytes memory data) =
            token0.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        require(success && data.length >= 32, "CLPool: FAILED_BALANCE0_CALL");
        return abi.decode(data, (uint256));
    }

    /// @dev Get the pool's balance of token1.
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize check.
    /// @return The pool's balance of token1.
    function balance1() private view returns (uint256) {
        (bool success, bytes memory data) =
            token1.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        require(success && data.length >= 32, "CLPool: FAILED_BALANCE1_CALL");
        return abi.decode(data, (uint256));
    }

    /// @inheritdoc ICLPoolDerivedState
    /// @notice Returns tick cumulative, seconds per liquidity cumulative, and seconds ago for a given set of time points.
    /// @param secondsAgos An array of time points in seconds ago to observe.
    /// @return tickCumulatives An array of tick cumulative values.
    /// @return secondsPerLiquidityCumulativeX128s An array of seconds per liquidity cumulative values (Q128.128).
    function observe(uint32[] calldata secondsAgos)
        external
        view
        override
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        return observations.observe(
            _blockTimestamp(), secondsAgos, slot0.tick, slot0.observationIndex, liquidity, slot0.observationCardinality
        );
    }

    /// @inheritdoc ICLPoolActions
    /// @notice Increases the maximum number of observations stored in the oracle array.
    /// @param observationCardinalityNext The new target maximum number of observations.
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external override lock {
        uint16 observationCardinalityNextOld = slot0.observationCardinalityNext; // for the event
        uint16 observationCardinalityNextNew =
            observations.grow(observationCardinalityNextOld, observationCardinalityNext);
        slot0.observationCardinalityNext = observationCardinalityNextNew;
        if (observationCardinalityNextOld != observationCardinalityNextNew) {
            emit IncreaseObservationCardinalityNext(observationCardinalityNextOld, observationCardinalityNextNew);
        }
    }

    /// @notice Parameters for modifying a position.
    struct ModifyPositionParams {
        /// @notice The address that owns the position.
        address owner;
        /// @notice The lower tick of the position.
        int24 tickLower;
        /// @notice The upper tick of the position.
        int24 tickUpper;
        /// @notice The change in liquidity. Can be positive (mint) or negative (burn).
        int128 liquidityDelta;
    }

    /// @dev Effects changes to a position, including liquidity updates and fee calculations.
    /// @param params The parameters for modifying the position.
    /// @return position A storage pointer to the modified position.
    /// @return amount0 The amount of token0 to be transferred. Positive if owed to the pool, negative if owed to the user.
    /// @return amount1 The amount of token1 to be transferred. Positive if owed to the pool, negative if owed to the user.
    function _modifyPosition(ModifyPositionParams memory params)
        private
        returns (Position.Info storage position, int256 amount0, int256 amount1)
    {
        checkTicks(params.tickLower, params.tickUpper);

        Slot0 memory _slot0 = slot0; // SLOAD for gas optimization

        // Update the position's liquidity and fee growth trackers.
        position = _updatePosition(params.owner, params.tickLower, params.tickUpper, params.liquidityDelta, _slot0.tick);

        if (params.liquidityDelta != 0) {
            if (_slot0.tick < params.tickLower) {
                // Current tick is below the position's range.
                // Liquidity is out of range, so only token0 is required/provided.
                amount0 = SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            } else if (_slot0.tick < params.tickUpper) {
                // Current tick is within the position's range.
                // Liquidity is in range, so both token0 and token1 are required/provided.
                uint128 liquidityBefore = liquidity; // SLOAD for gas optimization

                // Write an oracle entry if liquidity changes.
                (slot0.observationIndex, slot0.observationCardinality) = observations.write(
                    _slot0.observationIndex,
                    _blockTimestamp(),
                    _slot0.tick,
                    liquidityBefore,
                    _slot0.observationCardinality,
                    _slot0.observationCardinalityNext
                );

                amount0 = SqrtPriceMath.getAmount0Delta(
                    _slot0.sqrtPriceX96, TickMath.getSqrtRatioAtTick(params.tickUpper), params.liquidityDelta
                );
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower), _slot0.sqrtPriceX96, params.liquidityDelta
                );

                liquidity = LiquidityMath.addDelta(liquidityBefore, params.liquidityDelta);
            } else {
                // Current tick is above the position's range.
                // Liquidity is out of range, so only token1 is required/provided.
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            }
        }
    }

    /// @dev Gets and updates a position with the given liquidity delta, and updates tick information.
    /// @param owner The owner of the position.
    /// @param tickLower The lower tick of the position.
    /// @param tickUpper The upper tick of the position.
    /// @param liquidityDelta The change in liquidity for the position.
    /// @param tick The current tick of the pool.
    /// @return position A storage pointer to the updated position.
    function _updatePosition(address owner, int24 tickLower, int24 tickUpper, int128 liquidityDelta, int24 tick)
        private
        returns (Position.Info storage position)
    {
        position = positions.get(owner, tickLower, tickUpper);

        uint256 _feeGrowthGlobal0X128 = feeGrowthGlobal0X128; // SLOAD for gas optimization
        uint256 _feeGrowthGlobal1X128 = feeGrowthGlobal1X128; // SLOAD for gas optimization

        // Update tick information if liquidity has changed.
        bool flippedLower = false;
        bool flippedUpper = false;
        if (liquidityDelta != 0) {
            uint32 time = _blockTimestamp();
            // Get the latest observation data for fee calculation.
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) = observations.observeSingle(
                time, 0, slot0.tick, slot0.observationIndex, liquidity, slot0.observationCardinality
            );

            // Update the lower tick.
            flippedLower = ticks.update(
                tickLower,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                false, // isUpper = false
                maxLiquidityPerTick
            );
            // Update the upper tick.
            flippedUpper = ticks.update(
                tickUpper,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                true, // isUpper = true
                maxLiquidityPerTick
            );

            // Flip the tick in the bitmap if its initialization state changed.
            if (flippedLower) {
                tickBitmap.flipTick(tickLower, tickSpacing);
            }
            if (flippedUpper) {
                tickBitmap.flipTick(tickUpper, tickSpacing);
            }
        }

        // Calculate the fee growth inside the position's range.
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            ticks.getFeeGrowthInside(tickLower, tickUpper, tick, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128);

        // Update the position's state.
        bool staked = owner == gauge;
        position.update(liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128, staked);

        // Clear tick data if it's no longer needed (liquidity became zero).
        if (liquidityDelta < 0) {
            if (flippedLower) {
                ticks.clear(tickLower);
            }
            if (flippedUpper) {
                ticks.clear(tickUpper);
            }
        }
    }

    /// @inheritdoc ICLPoolActions
    /// @notice Mints new liquidity for a position.
    /// @param recipient The address to receive the minted liquidity.
    /// @param tickLower The lower tick of the position.
    /// @param tickUpper The upper tick of the position.
    /// @param amount The amount of liquidity to mint.
    /// @param data Optional data to pass to the callback.
    /// @return amount0 The amount of token0 that was deposited.
    /// @return amount1 The amount of token1 that was deposited.
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external
        override
        lock
        returns (uint256 amount0, uint256 amount1)
    {
        require(amount > 0, "CLPool: MINT_AMOUNT_ZERO");
        // Modify the position to add the new liquidity.
        (, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: recipient,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(amount).toInt128()
            })
        );

        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        // Perform the token transfers via callback.
        uint256 balance0Before = 0;
        uint256 balance1Before = 0;
        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();
        ICLMintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);
        if (amount0 > 0) require(balance0Before.add(amount0) <= balance0(), "CLPool: MINT_FAILED_AMOUNT0"); // M0
        if (amount1 > 0) require(balance1Before.add(amount1) <= balance1(), "CLPool: MINT_FAILED_AMOUNT1"); // M1

        emit Mint(msg.sender, recipient, tickLower, tickUpper, amount, amount0, amount1);
    }

    /// @inheritdoc ICLPoolActions
    /// @notice Collects fees owed to a position.
    /// @param recipient The address to receive the collected fees.
    /// @param tickLower The lower tick of the position.
    /// @param tickUpper The upper tick of the position.
    /// @param amount0Requested The maximum amount of token0 to collect.
    /// @param amount1Requested The maximum amount of token1 to collect.
    /// @return amount0 The amount of token0 collected.
    /// @return amount1 The amount of token1 collected.
    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override lock returns (uint128 amount0, uint128 amount1) {
        (amount0, amount1) = _collect({
            recipient: recipient,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Requested: amount0Requested,
            amount1Requested: amount1Requested,
            owner: msg.sender // Caller is the owner of the position.
        });
    }

    /// @inheritdoc ICLPoolActions
    /// @notice Collects fees owed to a position, callable by the NFT manager.
    /// @param recipient The address to receive the collected fees.
    /// @param tickLower The lower tick of the position.
    /// @param tickUpper The upper tick of the position.
    /// @param amount0Requested The maximum amount of token0 to collect.
    /// @param amount1Requested The maximum amount of token1 to collect.
    /// @param owner The owner of the position.
    /// @return amount0 The amount of token0 collected.
    /// @return amount1 The amount of token1 collected.
    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested,
        address owner
    ) external override lock onlyNftManager returns (uint128 amount0, uint128 amount1) {
        (amount0, amount1) = _collect({
            recipient: recipient,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Requested: amount0Requested,
            amount1Requested: amount1Requested,
            owner: owner
        });
    }

    /// @dev Internal function to collect fees for a position.
    /// @param recipient The address to receive the collected fees.
    /// @param tickLower The lower tick of the position.
    /// @param tickUpper The upper tick of the position.
    /// @param amount0Requested The maximum amount of token0 to collect.
    /// @param amount1Requested The maximum amount of token1 to collect.
    /// @param owner The owner of the position.
    /// @return amount0 The amount of token0 collected.
    /// @return amount1 The amount of token1 collected.
    function _collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested,
        address owner
    ) private returns (uint128 amount0, uint128 amount1) {
        // No need to checkTicks here, as invalid positions will have zero tokensOwed.
        Position.Info storage position = positions.get(owner, tickLower, tickUpper);

        // Determine the actual amounts to collect, capped by tokens owed and requested amounts.
        amount0 = amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested;

        // Update the position's owed tokens and transfer the collected fees.
        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        emit Collect(owner, recipient, tickLower, tickUpper, amount0, amount1);
    }

    /// @inheritdoc ICLPoolActions
    /// @notice Burns liquidity from a position.
    /// @param tickLower The lower tick of the position.
    /// @param tickUpper The upper tick of the position.
    /// @param amount The amount of liquidity to burn.
    /// @return amount0 The amount of token0 received from burning liquidity.
    /// @return amount1 The amount of token1 received from burning liquidity.
    function burn(int24 tickLower, int24 tickUpper, uint128 amount)
        external
        override
        lock
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = _burn({tickLower: tickLower, tickUpper: tickUpper, amount: amount, owner: msg.sender});
    }

    /// @inheritdoc ICLPoolActions
    /// @notice Burns liquidity from a position, callable by the NFT manager.
    /// @param tickLower The lower tick of the position.
    /// @param tickUpper The upper tick of the position.
    /// @param amount The amount of liquidity to burn.
    /// @param owner The owner of the position.
    /// @return amount0 The amount of token0 received from burning liquidity.
    /// @return amount1 The amount of token1 received from burning liquidity.
    function burn(int24 tickLower, int24 tickUpper, uint128 amount, address owner)
        external
        override
        lock
        onlyNftManager
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = _burn({tickLower: tickLower, tickUpper: tickUpper, amount: amount, owner: owner});
    }

    /// @dev Internal function to burn liquidity from a position.
    /// @param tickLower The lower tick of the position.
    /// @param tickUpper The upper tick of the position.
    /// @param amount The amount of liquidity to burn.
    /// @param owner The owner of the position.
    /// @return amount0 The amount of token0 received from burning liquidity.
    /// @return amount1 The amount of token1 received from burning liquidity.
    function _burn(int24 tickLower, int24 tickUpper, uint128 amount, address owner)
        private
        returns (uint256 amount0, uint256 amount1)
    {
        // Modify the position to remove liquidity.
        (Position.Info storage position, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: owner,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(amount).toInt128() // Negative delta for burning
            })
        );

        // Amounts are negative from _modifyPosition for burns.
        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        // Add the withdrawn token amounts to the position's owed tokens.
        if (amount0 > 0 || amount1 > 0) {
            (position.tokensOwed0, position.tokensOwed1) =
                (position.tokensOwed0 + uint128(amount0), position.tokensOwed1 + uint128(amount1));
        }

        emit Burn(owner, tickLower, tickUpper, amount, amount0, amount1);
    }

    /// @inheritdoc ICLPoolActions
    /// @notice Stakes or unstakes liquidity for a position.
    /// @dev Can only be called by the gauge associated with this pool.
    /// @param stakedLiquidityDelta The change in staked liquidity. Positive for staking, negative for unstaking.
    /// @param tickLower The lower tick of the position.
    /// @param tickUpper The upper tick of the position.
    /// @param positionUpdate Whether to update the NFT and gauge positions.
    function stake(int128 stakedLiquidityDelta, int24 tickLower, int24 tickUpper, bool positionUpdate)
        external
        override
        lock
        onlyGauge
    {
        int24 tick = slot0.tick;
        // If the current tick is within the position's range, update rewards and staked liquidity.
        if (tick >= tickLower && tick < tickUpper) {
            _updateRewardsGrowthGlobal();
            stakedLiquidity = LiquidityMath.addDelta(stakedLiquidity, stakedLiquidityDelta);
        }

        // If required, update the NFT and gauge positions to reflect the staking change.
        if (positionUpdate) {
            Position.Info storage nftPosition = positions.get(nft, tickLower, tickUpper);
            Position.Info storage gaugePosition = positions.get(gauge, tickLower, tickUpper);

            // Calculate fee growth inside the position's range.
            (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
                ticks.getFeeGrowthInside(tickLower, tickUpper, tick, feeGrowthGlobal0X128, feeGrowthGlobal1X128);

            // Update the NFT position (unstaking) and gauge position (staking).
            nftPosition.update(-stakedLiquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128, false);
            gaugePosition.update(stakedLiquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128, true);
        }

        // Update tick locations where staked liquidity needs to be added or subtracted.
        // Only update ticks if they are initialized.
        if (ticks[tickLower].initialized) ticks.updateStake(tickLower, stakedLiquidityDelta, false);
        if (ticks[tickUpper].initialized) ticks.updateStake(tickUpper, stakedLiquidityDelta, true);
    }

    /// @notice Caches values that are computed and re-used across swap steps.
    struct SwapCache {
        /// @notice Liquidity at the beginning of the swap.
        uint128 liquidityStart;
        /// @notice Staked liquidity at the beginning of the swap.
        uint128 stakedLiquidityStart;
        /// @notice The timestamp of the current block.
        uint32 blockTimestamp;
        /// @notice The current value of the tick accumulator, computed only if an initialized tick is crossed.
        int56 tickCumulative;
        /// @notice The current value of seconds per liquidity accumulator, computed only if an initialized tick is crossed.
        uint160 secondsPerLiquidityCumulativeX128;
        /// @notice Whether the tickCumulative and secondsPerLiquidityCumulativeX128 have been computed and cached.
        bool computedLatestObservation;
    }

    /// @notice The top-level state of a swap, results of which are recorded in storage at the end.
    struct SwapState {
        /// @notice The amount remaining to be swapped in/out of the input/output asset.
        int256 amountSpecifiedRemaining;
        /// @notice The amount already swapped out/in of the output/input asset.
        int256 amountCalculated;
        /// @notice Current sqrt(price) as a Q64.96 value.
        uint160 sqrtPriceX96;
        /// @notice The tick associated with the current price.
        int24 tick;
        /// @notice The fee associated with the pool.
        uint24 fee;
        /// @notice Whether fees have been updated in the current swap.
        bool hasUpdatedFees;
        /// @notice The global fee growth of the input token as a Q128.128 value.
        uint256 feeGrowthGlobalX128;
        /// @notice Amount of input token paid as gauge fee.
        uint128 gaugeFee;
        /// @notice The current liquidity in range.
        uint128 liquidity;
        /// @notice The current staked liquidity in range.
        uint128 stakedLiquidity;
    }

    /// @notice Intermediate computations for a single swap step.
    struct StepComputations {
        /// @notice The price at the beginning of the step as a Q64.96 value.
        uint160 sqrtPriceStartX96;
        /// @notice The next tick to swap to from the current tick in the swap direction.
        int24 tickNext;
        /// @notice Whether tickNext is initialized or not.
        bool initialized;
        /// @notice sqrt(price) for the next tick (1/0) as a Q64.96 value.
        uint160 sqrtPriceNextX96;
        /// @notice How much is being swapped in in this step.
        uint256 amountIn;
        /// @notice How much is being swapped out in this step.
        uint256 amountOut;
        /// @notice How much fee is being paid in this step.
        uint256 feeAmount;
    }

    /// @inheritdoc ICLPoolActions
    /// @notice Swaps tokens in the pool.
    /// @param recipient The address to receive the output tokens.
    /// @param zeroForOne True if swapping token0 for token1, false otherwise.
    /// @param amountSpecified The amount of tokens to swap. Positive for exact input, negative for exact output.
    /// @param sqrtPriceLimitX96 The price limit for the swap, as a Q64.96 value.
    /// @param data Optional data to pass to the callback.
    /// @return amount0 The net amount of token0 swapped. Negative if output, positive if input.
    /// @return amount1 The net amount of token1 swapped. Negative if output, positive if input.
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external override returns (int256 amount0, int256 amount1) {
        require(amountSpecified != 0, "CLPool: AMOUNT_SPECIFIED_ZERO"); // AS

        Slot0 memory slot0Start = slot0;

        require(slot0Start.unlocked, "CLPool: LOCKED"); // LOK
        // Ensure the price limit is valid and has not been reached.
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 > slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO,
            "CLPool: SQRT_PRICE_LIMIT_INVALID" // SPL
        );

        slot0.unlocked = false; // Lock the pool for the duration of the swap.

        // Initialize the swap cache with current pool state.
        SwapCache memory cache = SwapCache({
            liquidityStart: liquidity,
            stakedLiquidityStart: stakedLiquidity,
            blockTimestamp: _blockTimestamp(),
            secondsPerLiquidityCumulativeX128: 0,
            tickCumulative: 0,
            computedLatestObservation: false
        });

        bool exactInput = amountSpecified > 0; // True if swapping for an exact input amount.

        // Initialize the swap state.
        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0Start.sqrtPriceX96,
            tick: slot0Start.tick,
            fee: fee(),
            hasUpdatedFees: false,
            feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128,
            gaugeFee: 0,
            liquidity: cache.liquidityStart,
            stakedLiquidity: cache.stakedLiquidityStart
        });

        // Continue swapping in steps as long as the specified amount hasn't been fully swapped and the price limit hasn't been reached.
        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            StepComputations memory step; // Stores computations for the current swap step.

            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            // Get the next initialized tick in the direction of the swap.
            (step.tickNext, step.initialized) =
                tickBitmap.nextInitializedTickWithinOneWord(state.tick, tickSpacing, zeroForOne);

            // Ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds.
            // Cap tickNext to MIN_TICK or MAX_TICK if it exceeds them.
            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // Get the price for the next tick.
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            // Compute the amounts to swap to reach the target tick, price limit, or exhaust the input/output amount.
            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                // Determine the target price for this step: either the next tick's price or the overall price limit.
                (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96)
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                state.fee
            );

            // Update remaining and calculated amounts based on whether it's an exact input or exact output swap.
            if (exactInput) {
                state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256();
                state.amountCalculated = state.amountCalculated.sub(step.amountOut.toInt256());
            } else {
                state.amountSpecifiedRemaining += step.amountOut.toInt256();
                state.amountCalculated = state.amountCalculated.add((step.amountIn + step.feeAmount).toInt256());
            }

            // Update global fee tracker and gauge fee if there's liquidity in the current range.
            if (state.liquidity > 0) {
                (uint256 _feeGrowthGlobalX128, uint256 _stakedFeeAmount) =
                    calculateFees(step.feeAmount, state.liquidity, state.stakedLiquidity);

                state.feeGrowthGlobalX128 += _feeGrowthGlobalX128;
                state.gaugeFee += uint128(_stakedFeeAmount);
            }

            // If the swap reached the next price (tick), perform tick transition logic.
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // If the tick is initialized, process the tick crossing.
                if (step.initialized) {
                    // Compute and cache latest observation data if not already done.
                    // This is done only once when the first initialized tick is crossed.
                    if (!cache.computedLatestObservation) {
                        (cache.tickCumulative, cache.secondsPerLiquidityCumulativeX128) = observations.observeSingle(
                            cache.blockTimestamp,
                            0, // Observe at the current time
                            slot0Start.tick,
                            slot0Start.observationIndex,
                            cache.liquidityStart,
                            slot0Start.observationCardinality
                        );
                        cache.computedLatestObservation = true;
                    }
                    // Update rewards growth global if fees haven't been updated yet in this swap.
                    if (!state.hasUpdatedFees) {
                        _updateRewardsGrowthGlobal();
                        state.hasUpdatedFees = true;
                    }
                    // Cross the tick and get the net liquidity changes.
                    Tick.LiquidityNets memory nets = ticks.cross(
                        step.tickNext,
                        (zeroForOne ? state.feeGrowthGlobalX128 : feeGrowthGlobal0X128), // Fee growth of token0
                        (zeroForOne ? feeGrowthGlobal1X128 : state.feeGrowthGlobalX128), // Fee growth of token1
                        cache.secondsPerLiquidityCumulativeX128,
                        cache.tickCumulative,
                        cache.blockTimestamp,
                        rewardGrowthGlobalX128
                    );
                    // Adjust liquidity net signs if swapping leftward (zeroForOne).
                    // Safe because liquidityNet & stakedLiquidityNet cannot be type(int128).min.
                    if (zeroForOne) {
                        nets.liquidityNet = -nets.liquidityNet;
                        nets.stakedLiquidityNet = -nets.stakedLiquidityNet;
                    }

                    // Update overall pool liquidity and staked liquidity.
                    state.liquidity = LiquidityMath.addDelta(state.liquidity, nets.liquidityNet);
                    state.stakedLiquidity = LiquidityMath.addDelta(state.stakedLiquidity, nets.stakedLiquidityNet);
                }

                // Update the current tick based on the direction of the swap.
                state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // If the price changed but didn't reach the next tick, recompute the current tick.
                // This happens if the swap exhausts the amount specified or hits the price limit mid-step.
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        // Update tick and write an oracle entry if the tick changed during the swap.
        if (state.tick != slot0Start.tick) {
            (uint16 observationIndex, uint16 observationCardinality) = observations.write(
                slot0Start.observationIndex,
                cache.blockTimestamp,
                slot0Start.tick, // Previous tick
                cache.liquidityStart, // Liquidity before swap
                slot0Start.observationCardinality,
                slot0Start.observationCardinalityNext
            );
            // Update slot0 with the new state.
            (slot0.sqrtPriceX96, slot0.tick, slot0.observationIndex, slot0.observationCardinality) =
                (state.sqrtPriceX96, state.tick, observationIndex, observationCardinality);
        } else {
            // Otherwise, just update the price in slot0.
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }

        // Update overall pool liquidity and staked liquidity if they changed.
        if (cache.liquidityStart != state.liquidity) liquidity = state.liquidity;
        if (cache.stakedLiquidityStart != state.stakedLiquidity) stakedLiquidity = state.stakedLiquidity;

        // Update global fee growth and gauge fees.
        // Overflow is acceptable here as the protocol expects withdrawal before max type(uint128) fees are hit.
        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
            if (state.gaugeFee > 0) gaugeFees.token0 += state.gaugeFee;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
            if (state.gaugeFee > 0) gaugeFees.token1 += state.gaugeFee;
        }

        // Calculate the final amounts swapped.
        (amount0, amount1) = zeroForOne == exactInput
            ? (amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated) // Exact input case
            : (state.amountCalculated, amountSpecified - state.amountSpecifiedRemaining); // Exact output case

        // Perform token transfers and invoke the callback.
        if (zeroForOne) { // Swapping token0 for token1
            if (amount1 < 0) TransferHelper.safeTransfer(token1, recipient, uint256(-amount1)); // Send output token1

            uint256 balance0Before = balance0();
            ICLSwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data); // Callback for input token0
            require(balance0Before.add(uint256(amount0)) <= balance0(), "CLPool: INSUFFICIENT_INPUT_AMOUNT0"); // IIA
        } else { // Swapping token1 for token0
            if (amount0 < 0) TransferHelper.safeTransfer(token0, recipient, uint256(-amount0)); // Send output token0

            uint256 balance1Before = balance1();
            ICLSwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data); // Callback for input token1
            require(balance1Before.add(uint256(amount1)) <= balance1(), "CLPool: INSUFFICIENT_INPUT_AMOUNT1"); // IIA
        }

        emit Swap(msg.sender, recipient, amount0, amount1, state.sqrtPriceX96, state.liquidity, state.tick);
        slot0.unlocked = true; // Unlock the pool.
    }

    /// @inheritdoc ICLPoolActions
    /// @notice Performs a flash loan.
    /// @param recipient The address to receive the loaned tokens and execute logic.
    /// @param amount0 The amount of token0 to loan.
    /// @param amount1 The amount of token1 to loan.
    /// @param data Optional data to pass to the callback.
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external override lock {
        uint128 _liquidity = liquidity;
        require(_liquidity > 0, "CLPool: ZERO_LIQUIDITY"); // L

        // Calculate flash loan fees.
        uint256 fee0 = FullMath.mulDivRoundingUp(amount0, fee(), 1e6);
        uint256 fee1 = FullMath.mulDivRoundingUp(amount1, fee(), 1e6);
        uint256 balance0Before = balance0();
        uint256 balance1Before = balance1();

        // Transfer loaned amounts to the recipient.
        if (amount0 > 0) TransferHelper.safeTransfer(token0, recipient, amount0);
        if (amount1 > 0) TransferHelper.safeTransfer(token1, recipient, amount1);

        // Invoke the flash callback on the recipient.
        ICLFlashCallback(msg.sender).uniswapV3FlashCallback(fee0, fee1, data);

        // Check if the pool received the loaned amounts back plus fees.
        uint256 balance0After = balance0();
        uint256 balance1After = balance1();

        require(balance0Before.add(fee0) <= balance0After, "CLPool: FLASH_FAILED_AMOUNT0"); // F0
        require(balance1Before.add(fee1) <= balance1After, "CLPool: FLASH_FAILED_AMOUNT1"); // F1

        // Calculate amounts paid back to the pool (excluding fees already accounted for).
        // Subtraction is safe because balanceAfter is guaranteed to be >= balanceBefore + fee.
        uint256 paid0 = balance0After - balance0Before;
        uint256 paid1 = balance1After - balance1Before;

        // Update fee growth and gauge fees if any amount was paid for token0.
        if (paid0 > 0) {
            (uint256 _feeGrowthGlobalX128, uint256 _stakedFeeAmount) = calculateFees(paid0, _liquidity, stakedLiquidity);

            if (_feeGrowthGlobalX128 > 0) feeGrowthGlobal0X128 += _feeGrowthGlobalX128;
            if (uint128(_stakedFeeAmount) > 0) gaugeFees.token0 += uint128(_stakedFeeAmount);
        }
        // Update fee growth and gauge fees if any amount was paid for token1.
        if (paid1 > 0) {
            (uint256 _feeGrowthGlobalX128, uint256 _stakedFeeAmount) = calculateFees(paid1, _liquidity, stakedLiquidity);

            if (_feeGrowthGlobalX128 > 0) feeGrowthGlobal1X128 += _feeGrowthGlobalX128;
            if (uint128(_stakedFeeAmount) > 0) gaugeFees.token1 += uint128(_stakedFeeAmount);
        }
        emit Flash(msg.sender, recipient, amount0, amount1, paid0, paid1);
    }

    /// @inheritdoc ICLPoolState
    /// @notice Calculates the reward growth inside a given tick range.
    /// @param tickLower The lower tick of the range.
    /// @param tickUpper The upper tick of the range.
    /// @param _rewardGrowthGlobalX128 The global reward growth per unit of staked liquidity (Q128.128).
    /// If zero, uses the current pool's rewardGrowthGlobalX128.
    /// @return rewardGrowthInside The reward growth inside the tick range per unit of staked liquidity (Q128.128).
    function getRewardGrowthInside(int24 tickLower, int24 tickUpper, uint256 _rewardGrowthGlobalX128)
        external
        view
        override
        returns (uint256 rewardGrowthInside)
    {
        checkTicks(tickLower, tickUpper);
        // Use the pool's current global reward growth if not provided.
        if (_rewardGrowthGlobalX128 == 0) _rewardGrowthGlobalX128 = rewardGrowthGlobalX128;

        return ticks.getRewardGrowthInside(tickLower, tickUpper, slot0.tick, _rewardGrowthGlobalX128);
    }

    /// @inheritdoc ICLPoolActions
    /// @notice Updates the global reward growth.
    /// @dev Can only be called by the gauge associated with this pool.
    function updateRewardsGrowthGlobal() external override lock onlyGauge {
        _updateRewardsGrowthGlobal();
    }

    /// @dev Internal function to update the global reward growth.
    /// It calculates the rewards accrued since the last update and distributes them.
    /// - `timeDelta != 0` handles the case when the function is called multiple times in the same block.
    /// - `stakedLiquidity > 0` handles cases such as:
    ///   - Depositing staked liquidity when there is no liquidity staked yet.
    ///   - Notifying rewards when there is no liquidity staked.
    function _updateRewardsGrowthGlobal() internal {
        uint32 timestamp = _blockTimestamp();
        uint256 _lastUpdated = lastUpdated;
        uint256 timeDelta = timestamp - _lastUpdated; // Skip if this is a second call in the same block.

        if (timeDelta != 0) {
            if (rewardReserve > 0) {
                uint256 reward = rewardRate * timeDelta; // Calculate rewards for the elapsed time.
                if (reward > rewardReserve) reward = rewardReserve; // Cap reward by the remaining reserve.
                rewardReserve -= reward; // Decrease the reward reserve.

                if (stakedLiquidity > 0) {
                    // Distribute rewards to staked liquidity.
                    rewardGrowthGlobalX128 += FullMath.mulDiv(reward, FixedPoint128.Q128, stakedLiquidity);
                } else {
                    // If no staked liquidity, add rewards to rollover to be distributed later.
                    rollover += reward;
                }
            }
            lastUpdated = timestamp; // Update the last updated timestamp.
        }
    }

    /// @inheritdoc ICLPoolActions
    /// @notice Synchronizes reward parameters with the gauge.
    /// @dev Can only be called by the gauge associated with this pool.
    /// @param _rewardRate The new reward rate.
    /// @param _rewardReserve The new reward reserve.
    /// @param _periodFinish The new period finish timestamp.
    function syncReward(uint256 _rewardRate, uint256 _rewardReserve, uint256 _periodFinish)
        external
        override
        lock
        onlyGauge
    {
        rewardRate = _rewardRate;
        rewardReserve = _rewardReserve;
        periodFinish = _periodFinish;
        delete rollover; // Clear any previously rolled-over rewards.
    }

    /// @notice Calculates the fees owed to staked liquidity and the fee levied on unstaked liquidity.
    /// @param feeAmount Total fees collected in a swap step or flash loan.
    /// @param _liquidity Current liquidity in the active tick range.
    /// @param _stakedLiquidity Current staked liquidity in the active tick range.
    /// @return unstakedFeeAmount Fee amount for unstaked LPs after accounting for staked liquidity contribution and unstaked fee.
    /// @return stakedFeeAmount Fee amount for staked LPs, consisting of their proportional share and the unstaked fee.
    function splitFees(uint256 feeAmount, uint128 _liquidity, uint128 _stakedLiquidity)
        internal
        view
        returns (uint256 unstakedFeeAmount, uint256 stakedFeeAmount)
    {
        // Calculate the portion of fees attributable to staked liquidity based on its proportion of total liquidity.
        stakedFeeAmount = FullMath.mulDivRoundingUp(feeAmount, _stakedLiquidity, _liquidity);
        // The remaining fees are initially attributed to unstaked liquidity.
        // Then, apply the unstaked fee mechanism to this remainder.
        (unstakedFeeAmount, stakedFeeAmount) = applyUnstakedFees(feeAmount - stakedFeeAmount, stakedFeeAmount);
    }

    /// @notice Applies the unstaked fee to the portion of fees attributed to unstaked liquidity.
    /// A part of the unstaked liquidity's fees is redirected to staked liquidity.
    /// @param _unstakedFeeAmount Fee amount initially attributed to unstaked LPs (net of staked liquidity's direct share).
    /// @param _stakedFeeAmount Fee amount initially attributed to staked LPs (their direct proportional share).
    /// @return unstakedFeeAmount Final fee amount for unstaked LPs after the unstaked fee is applied.
    /// @return stakedFeeAmount Final fee amount for staked LPs, including their share of the unstaked fee.
    function applyUnstakedFees(uint256 _unstakedFeeAmount, uint256 _stakedFeeAmount)
        internal
        view
        returns (uint256 unstakedFeeAmount, uint256 stakedFeeAmount)
    {
        // Calculate the portion of unstaked fees that goes to staked liquidity.
        uint256 _stakedPortionFromUnstaked = FullMath.mulDivRoundingUp(_unstakedFeeAmount, unstakedFee(), 1_000_000);
        // Unstaked LPs receive the remainder.
        unstakedFeeAmount = _unstakedFeeAmount - _stakedPortionFromUnstaked;
        // Staked LPs receive their initial share plus the portion from unstaked fees.
        stakedFeeAmount = _stakedFeeAmount + _stakedPortionFromUnstaked;
    }

    /// @notice Calculates the fee growth for unstaked liquidity and the total amount of fees for staked liquidity.
    /// This function determines how swap fees or flash loan fees are distributed between
    /// unstaked liquidity providers (via feeGrowthGlobal) and staked liquidity providers (accumulated in gaugeFees).
    /// @param feeAmount The total amount of fees collected.
    /// @param _liquidity The current total liquidity in the relevant range.
    /// @param _stakedLiquidity The current staked liquidity in the relevant range.
    /// @return feeGrowthGlobalX128 The fee growth per unit of unstaked liquidity (Q128.128). This will be zero if all liquidity is staked.
    /// @return stakedFeeAmount The total amount of fees allocated to staked liquidity providers.
    function calculateFees(uint256 feeAmount, uint128 _liquidity, uint128 _stakedLiquidity)
        internal
        view
        returns (uint256 feeGrowthGlobalX128, uint256 stakedFeeAmount)
    {
        // Case 1: All liquidity is staked. All fees go to staked liquidity.
        if (_liquidity == _stakedLiquidity) {
            stakedFeeAmount = feeAmount;
            // feeGrowthGlobalX128 remains 0 as there's no unstaked liquidity.
        }
        // Case 2: No liquidity is staked. Fees are subject to the unstaked fee mechanism,
        // and the portion not taken by the unstaked fee contributes to feeGrowthGlobalX128 for unstaked LPs.
        else if (_stakedLiquidity == 0) {
            (uint256 unstakedPortion, uint256 stakedPortionFromUnstaked) = applyUnstakedFees(feeAmount, 0);
            feeGrowthGlobalX128 = FullMath.mulDiv(unstakedPortion, FixedPoint128.Q128, _liquidity);
            stakedFeeAmount = stakedPortionFromUnstaked; // This portion goes to the gauge (staked LPs)
        }
        // Case 3: Mixed staked and unstaked liquidity.
        // Fees are first split proportionally. Then, the unstaked portion is subject to the unstaked fee mechanism.
        else {
            (uint256 unstakedPortion, uint256 _stakedPortion) = splitFees(feeAmount, _liquidity, _stakedLiquidity);
            // Unstaked portion contributes to feeGrowthGlobalX128 for the unstaked part of the liquidity.
            feeGrowthGlobalX128 = FullMath.mulDiv(unstakedPortion, FixedPoint128.Q128, _liquidity - _stakedLiquidity);
            stakedFeeAmount = _stakedPortion; // This combined amount goes to the gauge (staked LPs)
        }
    }

    /// @inheritdoc ICLPoolOwnerActions
    /// @notice Collects accumulated fees for the gauge.
    /// @dev Can only be called by the gauge associated with this pool.
    /// @return amount0 The amount of token0 collected.
    /// @return amount1 The amount of token1 collected.
    function collectFees() external override lock onlyGauge returns (uint128 amount0, uint128 amount1) {
        amount0 = gaugeFees.token0;
        amount1 = gaugeFees.token1;

        // Transfer collected fees, leaving 1 unit if amount > 1 to save gas on subsequent collections (avoid clearing slot).
        if (amount0 > 1) {
            gaugeFees.token0 = 1; // Leave 1 unit to keep the storage slot warm.
            TransferHelper.safeTransfer(token0, msg.sender, --amount0); // Transfer amount0 - 1
        } else if (amount0 == 1) {
            // If exactly 1, transfer it and clear the slot (though this path is less common due to the ">1" optimization)
            delete gaugeFees.token0;
             TransferHelper.safeTransfer(token0, msg.sender, amount0);
        }


        if (amount1 > 1) {
            gaugeFees.token1 = 1; // Leave 1 unit.
            TransferHelper.safeTransfer(token1, msg.sender, --amount1); // Transfer amount1 - 1
        } else if (amount1 == 1) {
            delete gaugeFees.token1;
            TransferHelper.safeTransfer(token1, msg.sender, amount1);
        }


        emit CollectFees(msg.sender, amount0, amount1);
    }
}
