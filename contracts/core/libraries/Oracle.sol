// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0 <0.8.0;

/// @title Oracle Library
/// @notice Provides functions for managing and accessing historical price and liquidity data (observations).
/// @dev Observations are stored in a fixed-size array that acts as a circular buffer.
/// Each pool initializes with a small oracle array, which can be expanded by anyone willing to pay for the storage.
/// When the array is full, older observations are overwritten.
/// The most recent observation can always be accessed, regardless of array length.
library Oracle {
    /// @notice Represents a single observation of price and liquidity data at a specific time.
    struct Observation {
        /// @notice The block timestamp of when the observation was recorded.
        uint32 blockTimestamp;
        /// @notice The cumulative tick value, scaled by the time elapsed since the pool's initialization.
        /// (i.e., sum of (tick * time_elapsed_in_tick) for all ticks since initialization).
        int56 tickCumulative;
        /// @notice The cumulative seconds per liquidity, scaled by 2^128.
        /// (i.e., sum of (seconds_elapsed_in_liquidity_range / liquidity_in_range) for all liquidity ranges since initialization).
        /// Liquidity is floored at 1 to prevent division by zero.
        uint160 secondsPerLiquidityCumulativeX128;
        /// @notice Whether the observation has been initialized with actual data.
        bool initialized;
    }

    /// @notice Transforms a previous observation into a new one based on elapsed time, current tick, and liquidity.
    /// @dev This function calculates the new cumulative values.
    /// `blockTimestamp` must be chronologically equal to or later than `last.blockTimestamp`. Handles overflow of timestamps (0 or 1 time).
    /// @param last The most recent observation to transform.
    /// @param blockTimestamp The timestamp for the new observation (current block timestamp).
    /// @param tick The current active tick of the pool.
    /// @param liquidity The current in-range liquidity of the pool.
    /// @return A new Observation struct populated with updated cumulative values.
    function transform(Observation memory last, uint32 blockTimestamp, int24 tick, uint128 liquidity)
        private
        pure
        returns (Observation memory)
    {
        uint32 delta = blockTimestamp - last.blockTimestamp; // Time elapsed since the last observation.
        return Observation({
            blockTimestamp: blockTimestamp,
            tickCumulative: last.tickCumulative + int56(tick) * delta, // Update tick cumulative.
            secondsPerLiquidityCumulativeX128: last.secondsPerLiquidityCumulativeX128
                + ((uint160(delta) << 128) / (liquidity > 0 ? liquidity : 1)), // Update seconds per liquidity cumulative.
            initialized: true
        });
    }

    /// @notice Initializes the oracle array by writing the first observation.
    /// @dev This is called once when the pool is created.
    /// @param self The storage pointer to the observations array.
    /// @param time The timestamp of initialization (typically `block.timestamp`).
    /// @return cardinality The initial number of populated elements (1).
    /// @return cardinalityNext The initial capacity of the oracle array (1).
    function initialize(Observation[65535] storage self, uint32 time)
        internal
        returns (uint16 cardinality, uint16 cardinalityNext)
    {
        self[0] = Observation({
            blockTimestamp: time,
            tickCumulative: 0, // Initial cumulative tick is 0.
            secondsPerLiquidityCumulativeX128: 0, // Initial seconds per liquidity is 0.
            initialized: true
        });
        return (1, 1); // Both cardinality and next cardinality start at 1.
    }

    /// @notice Writes a new observation to the oracle array.
    /// @dev This can be called at most once per block (actually, per 15 seconds due to the check).
    /// The `index` points to the most recently written element. `cardinality` and `index` are managed externally (by the pool).
    /// If `index` is at the end of the current `cardinality` and `cardinalityNext` is larger, `cardinality` can be increased.
    /// This maintains the order of observations.
    /// @param self The storage pointer to the observations array.
    /// @param index The index of the most recently written observation.
    /// @param blockTimestamp The timestamp for the new observation.
    /// @param tick The current active tick.
    /// @param liquidity The current in-range liquidity.
    /// @param cardinality The current number of initialized observations in the array.
    /// @param cardinalityNext The target capacity of the array (can be larger than `cardinality`).
    /// @return indexUpdated The new index of the most recently written observation.
    /// @return cardinalityUpdated The new cardinality (may be increased if conditions are met).
    function write(
        Observation[65535] storage self,
        uint16 index,
        uint32 blockTimestamp,
        int24 tick,
        uint128 liquidity,
        uint16 cardinality,
        uint16 cardinalityNext
    ) internal returns (uint16 indexUpdated, uint16 cardinalityUpdated) {
        Observation memory last = self[index]; // Get the last written observation.

        // Optimization: Do not write a new observation if the last one was less than 15 seconds ago.
        // This reduces storage writes and gas costs for frequent small swaps.
        if (last.blockTimestamp + 14 >= blockTimestamp) return (index, cardinality);

        // If the array is full (index is at the last slot of current cardinality)
        // and a larger capacity (cardinalityNext) is set, increase the current cardinality.
        if (cardinalityNext > cardinality && index == (cardinality - 1)) {
            cardinalityUpdated = cardinalityNext;
        } else {
            cardinalityUpdated = cardinality;
        }

        // Calculate the next index in the circular buffer.
        indexUpdated = (index + 1) % cardinalityUpdated;
        // Store the new observation, transformed from the last one.
        self[indexUpdated] = transform(last, blockTimestamp, tick, liquidity);
    }

    /// @notice Expands the capacity of the oracle array to store up to `next` observations.
    /// @dev This is called by the pool when `increaseObservationCardinalityNext` is invoked.
    /// Pre-populates new slots with a minimal value to "warm" them, potentially reducing gas costs for later SSTOREs during swaps,
    /// though the `initialized` flag remains false for these new slots until they are properly written.
    /// @param self The storage pointer to the observations array.
    /// @param current The current target capacity (`cardinalityNext` from the pool's perspective).
    /// @param next The proposed new target capacity.
    /// @return The updated target capacity. Returns `current` if `next` is not greater.
    function grow(Observation[65535] storage self, uint16 current, uint16 next) internal returns (uint16) {
        require(current > 0, "Oracle: INVALID_CURRENT_CARDINALITY"); // "I"
        // No-op if the new capacity is not greater than the current one.
        if (next <= current) return current;
        // "Warm" the new storage slots by writing a dummy value.
        // These slots are not considered initialized yet.
        for (uint16 i = current; i < next; i++) {
            self[i].blockTimestamp = 1; // Dummy value, `initialized` is still false.
        }
        return next; // Return the new target capacity.
    }

    /// @notice Compares two 32-bit timestamps, accounting for potential overflows.
    /// @dev Assumes `a` and `b` are chronologically before or at `time`.
    /// Useful for comparing timestamps in a circular buffer where time wraps around.
    /// @param time The reference timestamp (current block timestamp).
    /// @param a The first timestamp to compare.
    /// @param b The second timestamp to compare.
    /// @return True if `a` is chronologically less than or equal to `b`, false otherwise.
    function lte(uint32 time, uint32 a, uint32 b) private pure returns (bool) {
        // If neither 'a' nor 'b' has overflowed relative to 'time', a direct comparison is fine.
        if (a <= time && b <= time) return a <= b;

        // Adjust timestamps that have wrapped around by adding 2^32.
        // If 'a' or 'b' is greater than 'time', it implies it's an older timestamp that has wrapped.
        uint256 aAdjusted = a > time ? a : a + 2 ** 32;
        uint256 bAdjusted = b > time ? b : b + 2 ** 32;

        return aAdjusted <= bAdjusted;
    }

    /// @notice Performs a binary search to find observations bracketing a target timestamp.
    /// @dev Finds `beforeOrAt` and `atOrAfter` such that `beforeOrAt.blockTimestamp <= target <= atOrAfter.blockTimestamp`.
    /// The result can be the same observation if `target` matches an existing observation's timestamp.
    /// Assumes the target timestamp is within the bounds of the oldest and newest initialized observations in the array.
    /// @param self The storage pointer to the observations array.
    /// @param time The current block timestamp (for `lte` comparisons).
    /// @param target The target timestamp to search for.
    /// @param index The index of the most recently written observation.
    /// @param cardinality The number of initialized observations in the array.
    /// @return beforeOrAt The observation recorded at or before the `target` timestamp.
    /// @return atOrAfter The observation recorded at or after the `target` timestamp.
    function binarySearch(Observation[65535] storage self, uint32 time, uint32 target, uint16 index, uint16 cardinality)
        private
        view
        returns (Observation memory beforeOrAt, Observation memory atOrAfter)
    {
        uint256 l = (index + 1) % cardinality; // Index of the oldest observation.
        uint256 r = l + cardinality - 1;    // Effective index of the newest observation in a linear view.
        uint256 i; // Current midpoint index in the search.

        while (true) {
            i = (l + r) / 2;
            beforeOrAt = self[i % cardinality]; // Get observation at the midpoint.

            // If the observation at 'i' is uninitialized, it means we are too far in the "past"
            // (or in an uninitialized part of a newly grown array). Search in the more recent half.
            if (!beforeOrAt.initialized) {
                l = i + 1;
                continue;
            }

            // Get the observation immediately following 'beforeOrAt' in the circular buffer.
            atOrAfter = self[(i + 1) % cardinality];

            // Check if 'target' is between 'beforeOrAt' and 'atOrAfter'.
            bool targetLtOrEqBefore = lte(time, beforeOrAt.blockTimestamp, target);

            if (targetLtOrEqBefore && lte(time, target, atOrAfter.blockTimestamp)) {
                // Found the bracketing observations.
                break;
            }

            // Adjust search range based on comparison.
            if (!targetLtOrEqBefore) { // target is before beforeOrAt.blockTimestamp
                r = i - 1;
            } else { // target is after atOrAfter.blockTimestamp (or atOrAfter is uninitialized and target is after beforeOrAt)
                l = i + 1;
            }
        }
    }

    /// @notice Retrieves observations that surround a given target timestamp.
    /// @dev Assumes at least one observation is initialized.
    /// This is a helper for `observeSingle` to find the data points for interpolation or direct return.
    /// @param self The storage pointer to the observations array.
    /// @param time The current block timestamp.
    /// @param target The target timestamp for which to find surrounding observations.
    /// @param tick The current active tick (used if transformation is needed).
    /// @param index The index of the most recently written observation.
    /// @param liquidity The current in-range liquidity (used if transformation is needed).
    /// @param cardinality The number of initialized observations in the array.
    /// @return beforeOrAt The observation at or before the `target` timestamp.
    /// @return atOrAfter The observation at or after the `target` timestamp.
    function getSurroundingObservations(
        Observation[65535] storage self,
        uint32 time,
        uint32 target,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    ) private view returns (Observation memory beforeOrAt, Observation memory atOrAfter) {
        // Optimistically start with the newest observation.
        beforeOrAt = self[index];

        // Case 1: Target is at or after the newest observation.
        if (lte(time, beforeOrAt.blockTimestamp, target)) {
            if (beforeOrAt.blockTimestamp == target) {
                // Target matches the newest observation exactly. `atOrAfter` is not strictly needed but returned as empty.
                return (beforeOrAt, atOrAfter);
            } else {
                // Target is after the newest observation. Transform the newest to the target time.
                // `atOrAfter` will be this transformed observation.
                return (beforeOrAt, transform(beforeOrAt, target, tick, liquidity));
            }
        }

        // Case 2: Target is before the newest observation.
        // Start with the oldest observation.
        uint16 oldestIndex = (index + 1) % cardinality;
        beforeOrAt = self[oldestIndex];
        // If the oldest known observation (by index) isn't initialized, it implies cardinality might be 1,
        // and self[0] (which is self[index] if index=0, cardinality=1) is the only one.
        // However, the `lte` check below should handle this. If `beforeOrAt` (oldest) is not initialized,
        // it means the array is essentially empty or corrupted past the newest observation,
        // which shouldn't happen if `cardinality > 0`.
        // A robust way if oldest is uninitialized could be to use self[0] if it's initialized,
        // but current logic proceeds, relying on binarySearch to skip uninitialized.
        // This line seems to handle a specific edge case of a freshly initialized array or small cardinality.
        if (!beforeOrAt.initialized) beforeOrAt = self[0]; // Fallback to self[0] if oldest by index is uninitialized.

        // Ensure the target is not older than the oldest observation.
        require(lte(time, beforeOrAt.blockTimestamp, target), "Oracle: TARGET_TOO_OLD"); // "OLD"

        // Case 3: Target is between the oldest and newest observations.
        // Perform a binary search to find the bracketing observations.
        return binarySearch(self, time, target, index, cardinality);
    }

    /// @notice Retrieves cumulative values for a single point in time, `secondsAgo` from `time`.
    /// @dev Returns (0,0) if `cardinality` is 0.
    /// Reverts if `secondsAgo` requests data older than the oldest available observation.
    /// If `secondsAgo` is 0, returns the current cumulative values (possibly transformed to `time`).
    /// If `target` (time - secondsAgo) falls between two observations, interpolates the cumulative values.
    /// @param self The storage pointer to the observations array.
    /// @param time The current block timestamp.
    /// @param secondsAgo The duration in the past to observe (e.g., 0 for current, 60 for 1 minute ago).
    /// @param tick The current active tick of the pool.
    /// @param index The index of the most recently written observation.
    /// @param liquidity The current in-range liquidity of the pool.
    /// @param cardinality The number of initialized observations in the array.
    /// @return tickCumulative The tick cumulative value at the target time.
    /// @return secondsPerLiquidityCumulativeX128 The seconds per liquidity cumulative value (Q128.128) at the target time.
    function observeSingle(
        Observation[65535] storage self,
        uint32 time,
        uint32 secondsAgo,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    ) internal view returns (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) {
        // If no observations, return zero. This check was missing but is implied by `cardinality > 0` in `observe`.
        // Adding it here for explicitness in `observeSingle` if called directly, though `observe` has the `require`.
        if (cardinality == 0) return (0,0);


        if (secondsAgo == 0) {
            // For "current" observation, use the latest written one.
            // If it's not from the current block, transform it to the current block's timestamp.
            Observation memory last = self[index];
            if (last.blockTimestamp != time) {
                 // Ensure last.blockTimestamp is not in the future, can happen in test environments or due to clock skew.
                require(last.blockTimestamp <= time, "Oracle: LAST_OBSERVATION_IN_FUTURE");
                last = transform(last, time, tick, liquidity);
            }
            return (last.tickCumulative, last.secondsPerLiquidityCumulativeX128);
        }

        uint32 target = time - secondsAgo; // Calculate the target timestamp.

        // Get observations surrounding the target timestamp.
        (Observation memory beforeOrAt, Observation memory atOrAfter) =
            getSurroundingObservations(self, time, target, tick, index, liquidity, cardinality);

        // Determine if interpolation is needed.
        if (target == beforeOrAt.blockTimestamp) {
            // Target matches the 'beforeOrAt' observation exactly.
            return (beforeOrAt.tickCumulative, beforeOrAt.secondsPerLiquidityCumulativeX128);
        } else if (target == atOrAfter.blockTimestamp) {
            // Target matches the 'atOrAfter' observation exactly.
            // This case implies atOrAfter was initialized (e.g. from transform() if target was after newest, or found by binarySearch).
            return (atOrAfter.tickCumulative, atOrAfter.secondsPerLiquidityCumulativeX128);
        } else {
            // Target is between 'beforeOrAt' and 'atOrAfter'. Interpolate.
            uint32 observationTimeDelta = atOrAfter.blockTimestamp - beforeOrAt.blockTimestamp;
            uint32 targetDelta = target - beforeOrAt.blockTimestamp;

            // Interpolate tickCumulative.
            int56 tickCumulativeInterpolated = beforeOrAt.tickCumulative +
                ((atOrAfter.tickCumulative - beforeOrAt.tickCumulative) / int56(observationTimeDelta)) * int56(targetDelta);

            // Interpolate secondsPerLiquidityCumulativeX128.
            uint160 secondsPerLiquidityCumulativeX128Interpolated = beforeOrAt.secondsPerLiquidityCumulativeX128 +
                uint160(
                    (uint256(atOrAfter.secondsPerLiquidityCumulativeX128 - beforeOrAt.secondsPerLiquidityCumulativeX128) *
                        targetDelta) /
                        observationTimeDelta
                );
            return (tickCumulativeInterpolated, secondsPerLiquidityCumulativeX128Interpolated);
        }
    }

    /// @notice Retrieves cumulative values for multiple points in time, specified by `secondsAgos`.
    /// @dev Reverts if any `secondsAgo` value requests data older than the oldest available observation
    /// or if `cardinality` is 0.
    /// @param self The storage pointer to the observations array.
    /// @param time The current block timestamp.
    /// @param secondsAgos An array of durations in the past to observe.
    /// @param tick The current active tick of the pool.
    /// @param index The index of the most recently written observation.
    /// @param liquidity The current in-range liquidity of the pool.
    /// @param cardinality The number of initialized observations in the array.
    /// @return tickCumulatives An array of tick cumulative values corresponding to each `secondsAgo`.
    /// @return secondsPerLiquidityCumulativeX128s An array of seconds per liquidity cumulative values (Q128.128) for each `secondsAgo`.
    function observe(
        Observation[65535] storage self,
        uint32 time,
        uint32[] memory secondsAgos,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    ) internal view returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) {
        require(cardinality > 0, "Oracle: NO_OBSERVATIONS_AVAILABLE"); // "I"

        uint256 len = secondsAgos.length;
        tickCumulatives = new int56[](len);
        secondsPerLiquidityCumulativeX128s = new uint160[](len);

        for (uint256 i = 0; i < len; i++) {
            (tickCumulatives[i], secondsPerLiquidityCumulativeX128s[i]) =
                observeSingle(self, time, secondsAgos[i], tick, index, liquidity, cardinality);
        }
    }
}
