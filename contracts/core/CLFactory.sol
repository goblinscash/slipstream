// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import "./interfaces/ICLFactory.sol";
import "./interfaces/fees/IFeeModule.sol";
import "./interfaces/IVoter.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@nomad-xyz/src/ExcessivelySafeCall.sol";
import "./CLPool.sol";

/// @title Canonical CL factory
/// @notice Deploys CL pools and manages ownership and control over pool protocol fees.
/// This contract is responsible for creating new CL (Concentrated Liquidity) pools,
/// managing the fees associated with these pools, and handling ownership and administrative functions.
contract CLFactory is ICLFactory {
    using ExcessivelySafeCall for address;

    /// @inheritdoc ICLFactory
    IVoter public immutable override voter;
    /// @inheritdoc ICLFactory
    address public immutable override poolImplementation;
    /// @inheritdoc ICLFactory
    address public override owner;
    /// @inheritdoc ICLFactory
    address public override swapFeeManager;
    /// @inheritdoc ICLFactory
    address public override swapFeeModule;
    /// @inheritdoc ICLFactory
    address public override unstakedFeeManager;
    /// @inheritdoc ICLFactory
    address public override unstakedFeeModule;
    /// @inheritdoc ICLFactory
    address public override nft;
    /// @inheritdoc ICLFactory
    address public override gaugeFactory;
    /// @inheritdoc ICLFactory
    address public override gaugeImplementation;
    /// @inheritdoc ICLFactory
    mapping(int24 => uint24) public override tickSpacingToFee;
    /// @inheritdoc ICLFactory
    mapping(address => mapping(address => mapping(int24 => address))) public override getPool;
    /// @dev Used in VotingEscrow to determine if a contract is a valid pool.
    mapping(address => bool) private _isPool;

    /// @dev Array of enabled tick spacings.
    int24[] private _tickSpacings;

    /// @notice Constructor to initialize the CLFactory.
    /// @param _voter The address of the Voter contract.
    /// @param _poolImplementation The address of the CLPool implementation contract.
    constructor(address _voter, address _poolImplementation) {
        owner = msg.sender;
        swapFeeManager = msg.sender;
        unstakedFeeManager = msg.sender;
        voter = IVoter(_voter);
        poolImplementation = _poolImplementation;
        emit OwnerChanged(address(0), msg.sender);
        emit SwapFeeManagerChanged(address(0), msg.sender);
        emit UnstakedFeeManagerChanged(address(0), msg.sender);

        // Enable default tick spacings with their corresponding fees
        enableTickSpacing(1, 100); // 0.01% fee
        enableTickSpacing(50, 500); // 0.05% fee
        enableTickSpacing(100, 500); // 0.05% fee
        enableTickSpacing(200, 3_000); // 0.3% fee
        enableTickSpacing(2_000, 10_000); // 1% fee
    }

    /// @inheritdoc ICLFactory
    /// @notice Creates a new CL pool for the given token pair and tick spacing.
    /// @param tokenA The address of the first token.
    /// @param tokenB The address of the second token.
    /// @param tickSpacing The tick spacing for the pool.
    /// @param sqrtPriceX96 The initial square root price of the pool, encoded as Q64.96.
    /// @return pool The address of the newly created pool.
    function createPool(address tokenA, address tokenB, int24 tickSpacing, uint160 sqrtPriceX96)
        external
        override
        returns (address pool)
    {
        require(tokenA != tokenB, "CLFactory: IDENTICAL_ADDRESSES");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "CLFactory: ZERO_ADDRESS");
        require(tickSpacingToFee[tickSpacing] != 0, "CLFactory: TICK_SPACING_NOT_ENABLED");
        require(getPool[token0][token1][tickSpacing] == address(0), "CLFactory: POOL_EXISTS");

        // Create a deterministic address for the pool using Clones.
        bytes32 _salt = keccak256(abi.encode(token0, token1, tickSpacing));
        pool = Clones.cloneDeterministic({master: poolImplementation, salt: _salt});

        // Predict the deterministic address for the gauge.
        address gauge =
            Clones.predictDeterministicAddress({master: gaugeImplementation, salt: _salt, deployer: gaugeFactory});

        // Initialize the newly created pool.
        CLPool(pool).initialize({
            _factory: address(this),
            _token0: token0,
            _token1: token1,
            _tickSpacing: tickSpacing,
            _gauge: gauge,
            _nft: nft,
            _sqrtPriceX96: sqrtPriceX96
        });

        // Mark the pool as a valid pool.
        _isPool[pool] = true;
        // Store the pool address in the mapping.
        getPool[token0][token1][tickSpacing] = pool;
        // Populate mapping in the reverse direction, deliberate choice to avoid the cost of comparing addresses.
        getPool[token1][token0][tickSpacing] = pool;

        // Create a gauge for the pool through the Voter contract.
        voter.createGauge(address(this), pool);
        emit PoolCreated(token0, token1, tickSpacing, pool);
    }

    /// @inheritdoc ICLFactory
    /// @notice Sets the owner of the factory.
    /// @dev Only the current owner can call this function.
    /// @param _owner The address of the new owner.
    function setOwner(address _owner) external override {
        address cachedOwner = owner;
        require(msg.sender == cachedOwner, "CLFactory: NOT_OWNER");
        require(_owner != address(0), "CLFactory: ZERO_ADDRESS");
        emit OwnerChanged(cachedOwner, _owner);
        owner = _owner;
    }

    /// @inheritdoc ICLFactory
    /// @notice Sets the swap fee manager for the factory.
    /// @dev Only the current swap fee manager can call this function.
    /// @param _swapFeeManager The address of the new swap fee manager.
    function setSwapFeeManager(address _swapFeeManager) external override {
        address cachedSwapFeeManager = swapFeeManager;
        require(msg.sender == cachedSwapFeeManager, "CLFactory: NOT_SWAP_FEE_MANAGER");
        require(_swapFeeManager != address(0), "CLFactory: ZERO_ADDRESS");
        swapFeeManager = _swapFeeManager;
        emit SwapFeeManagerChanged(cachedSwapFeeManager, _swapFeeManager);
    }

    /// @inheritdoc ICLFactory
    /// @notice Sets the unstaked fee manager for the factory.
    /// @dev Only the current unstaked fee manager can call this function.
    /// @param _unstakedFeeManager The address of the new unstaked fee manager.
    function setUnstakedFeeManager(address _unstakedFeeManager) external override {
        address cachedUnstakedFeeManager = unstakedFeeManager;
        require(msg.sender == cachedUnstakedFeeManager, "CLFactory: NOT_UNSTAKED_FEE_MANAGER");
        require(_unstakedFeeManager != address(0), "CLFactory: ZERO_ADDRESS");
        unstakedFeeManager = _unstakedFeeManager;
        emit UnstakedFeeManagerChanged(cachedUnstakedFeeManager, _unstakedFeeManager);
    }

    /// @inheritdoc ICLFactory
    /// @notice Sets the swap fee module for the factory.
    /// @dev Only the swap fee manager can call this function.
    /// @param _swapFeeModule The address of the new swap fee module.
    function setSwapFeeModule(address _swapFeeModule) external override {
        require(msg.sender == swapFeeManager, "CLFactory: NOT_SWAP_FEE_MANAGER");
        require(_swapFeeModule != address(0), "CLFactory: ZERO_ADDRESS");
        address oldFeeModule = swapFeeModule;
        swapFeeModule = _swapFeeModule;
        emit SwapFeeModuleChanged(oldFeeModule, _swapFeeModule);
    }

    /// @inheritdoc ICLFactory
    /// @notice Sets the unstaked fee module for the factory.
    /// @dev Only the unstaked fee manager can call this function.
    /// @param _unstakedFeeModule The address of the new unstaked fee module.
    function setUnstakedFeeModule(address _unstakedFeeModule) external override {
        require(msg.sender == unstakedFeeManager, "CLFactory: NOT_UNSTAKED_FEE_MANAGER");
        require(_unstakedFeeModule != address(0), "CLFactory: ZERO_ADDRESS");
        address oldFeeModule = unstakedFeeModule;
        unstakedFeeModule = _unstakedFeeModule;
        emit UnstakedFeeModuleChanged(oldFeeModule, _unstakedFeeModule);
    }

    /// @inheritdoc ICLFactory
    /// @notice Gets the swap fee for a given pool.
    /// @dev If a swap fee module is set, it tries to fetch the fee from the module.
    /// Otherwise, it returns the default fee based on the pool's tick spacing.
    /// @param pool The address of the pool.
    /// @return The swap fee for the pool.
    function getSwapFee(address pool) external view override returns (uint24) {
        if (swapFeeModule != address(0)) {
            (bool success, bytes memory data) = swapFeeModule.excessivelySafeStaticCall(
                200_000, 32, abi.encodeWithSelector(IFeeModule.getFee.selector, pool)
            );
            if (success) {
                uint24 fee = abi.decode(data, (uint24));
                // Ensure the fee from the module is within a valid range.
                if (fee <= 100_000) { // Max fee 10%
                    return fee;
                }
            }
        }
        // Return the default fee based on tick spacing if the module call fails or returns an invalid fee.
        return tickSpacingToFee[CLPool(pool).tickSpacing()];
    }

    /// @inheritdoc ICLFactory
    /// @notice Gets the unstaked fee for a given pool.
    /// @dev If the pool's gauge is not alive or an unstaked fee module is set,
    /// it tries to fetch the fee from the module. Otherwise, it returns a default fee.
    /// @param pool The address of the pool.
    /// @return The unstaked fee for the pool.
    function getUnstakedFee(address pool) external view override returns (uint24) {
        // If the gauge associated with the pool is not alive, no unstaked fee is charged.
        if (!IVoter(voter).isAlive(ICLPool(pool).gauge())) {
            return 0;
        }
        if (unstakedFeeModule != address(0)) {
            (bool success, bytes memory data) = unstakedFeeModule.excessivelySafeStaticCall(
                200_000, 32, abi.encodeWithSelector(IFeeModule.getFee.selector, pool)
            );
            if (success) {
                uint24 fee = abi.decode(data, (uint24));
                // Ensure the fee from the module is within a valid range.
                if (fee <= 1_000_000) { // Max fee 100%
                    return fee;
                }
            }
        }
        // Default unstaked fee is 10% if the module call fails or returns an invalid fee.
        return 100_000;
    }

    /// @inheritdoc ICLFactory
    /// @notice Enables a new tick spacing with an associated fee.
    /// @dev Only the owner can call this function.
    /// The fee must be between 0% and 10%.
    /// The tick spacing must be positive and less than 16384.
    /// @param tickSpacing The tick spacing to enable.
    /// @param fee The fee associated with the tick spacing (e.g., 100 for 0.01%).
    function enableTickSpacing(int24 tickSpacing, uint24 fee) public override {
        require(msg.sender == owner, "CLFactory: NOT_OWNER");
        require(fee > 0 && fee <= 100_000, "CLFactory: INVALID_FEE"); // Fee cannot be 0 and must be <= 10%
        // tick spacing is capped at 16384 to prevent the situation where tickSpacing is so large that
        // TickBitmap#nextInitializedTickWithinOneWord overflows int24 container from a valid tick
        // 16384 ticks represents a >5x price change with ticks of 1 bips
        require(tickSpacing > 0 && tickSpacing < 16384, "CLFactory: INVALID_TICK_SPACING");
        require(tickSpacingToFee[tickSpacing] == 0, "CLFactory: TICK_SPACING_ALREADY_ENABLED");

        tickSpacingToFee[tickSpacing] = fee;
        _tickSpacings.push(tickSpacing);
        emit TickSpacingEnabled(tickSpacing, fee);
    }

    /// @inheritdoc ICLFactory
    /// @notice Returns an array of all enabled tick spacings.
    /// @return An array of int24 representing the enabled tick spacings.
    function tickSpacings() external view override returns (int24[] memory) {
        return _tickSpacings;
    }

    /// @inheritdoc ICLFactory
    /// @notice Checks if a given address is a valid CL pool created by this factory.
    /// @param pool The address to check.
    /// @return True if the address is a valid pool, false otherwise.
    function isPair(address pool) external view override returns (bool) {
        return _isPool[pool];
    }

    /// @inheritdoc ICLFactory
    /// @notice Sets the gauge factory and gauge implementation addresses.
    /// @dev Can only be called once by the owner.
    /// @param _gaugeFactory The address of the gauge factory.
    /// @param _gaugeImplementation The address of the gauge implementation.
    function setGaugeFactory(address _gaugeFactory, address _gaugeImplementation) external override {
        require(gaugeFactory == address(0), "CLFactory: ALREADY_INITIALIZED"); // "AI"
        require(owner == msg.sender, "CLFactory: NOT_OWNER"); // "NA"
        require(_gaugeFactory != address(0) && _gaugeImplementation != address(0), "CLFactory: ZERO_ADDRESS");
        gaugeFactory = _gaugeFactory;
        gaugeImplementation = _gaugeImplementation;
    }

    /// @inheritdoc ICLFactory
    /// @notice Sets the non-fungible position manager address.
    /// @dev Can only be called once by the owner.
    /// @param _nft The address of the non-fungible position manager.
    function setNonfungiblePositionManager(address _nft) external override {
        require(nft == address(0), "CLFactory: ALREADY_INITIALIZED"); // "AI"
        require(owner == msg.sender, "CLFactory: NOT_OWNER"); // "NA"
        require(_nft != address(0), "CLFactory: ZERO_ADDRESS");
        nft = _nft;
    }
}
