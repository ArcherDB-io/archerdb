// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.security.SecureRandom;
import java.util.Objects;

/**
 * Immutable 128-bit unsigned integer for entity IDs, correlation IDs, etc.
 *
 * <p>
 * Stores values as two 64-bit longs (low and high parts) in little-endian format, matching the wire
 * protocol.
 *
 * <p>
 * Example:
 *
 * <pre>
 * {
 *     &#64;code
 *     UInt128 entityId = UInt128.random();
 *     UInt128 groupId = UInt128.of(1234L);
 *     UInt128 zero = UInt128.ZERO;
 * }
 * </pre>
 */
public final class UInt128 {

    /** The zero value (all bits zero). */
    public static final UInt128 ZERO = new UInt128(0L, 0L);

    private static final SecureRandom SECURE_RANDOM = new SecureRandom();

    private final long lo;
    private final long hi;

    private UInt128(long lo, long hi) {
        this.lo = lo;
        this.hi = hi;
    }

    /**
     * Creates a UInt128 from low and high parts.
     *
     * @param lo least significant 64 bits
     * @param hi most significant 64 bits
     * @return the UInt128 value
     */
    public static UInt128 of(long lo, long hi) {
        if (lo == 0 && hi == 0) {
            return ZERO;
        }
        return new UInt128(lo, hi);
    }

    /**
     * Creates a UInt128 from a single long value (high bits = 0).
     *
     * @param value the 64-bit value to use as the low part
     * @return the UInt128 value
     */
    public static UInt128 of(long value) {
        return of(value, 0L);
    }

    /**
     * Creates a UInt128 from a single long value (alias for of(long)).
     *
     * @param value the 64-bit value
     * @return the UInt128 value
     */
    public static UInt128 fromLong(long value) {
        return of(value, 0L);
    }

    /**
     * Creates a UInt128 from a 16-byte array (little-endian).
     *
     * @param bytes 16-byte array
     * @return the UInt128 value
     * @throws IllegalArgumentException if bytes is not 16 bytes
     */
    public static UInt128 fromBytes(byte[] bytes) {
        Objects.requireNonNull(bytes, "bytes cannot be null");
        if (bytes.length != 16) {
            throw new IllegalArgumentException("UInt128 requires exactly 16 bytes");
        }
        ByteBuffer buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
        return of(buf.getLong(), buf.getLong());
    }

    /**
     * Generates a random UInt128 using SecureRandom.
     *
     * @return a random UInt128
     */
    public static UInt128 random() {
        byte[] bytes = new byte[16];
        SECURE_RANDOM.nextBytes(bytes);
        return fromBytes(bytes);
    }

    /**
     * Returns the least significant 64 bits.
     */
    public long getLo() {
        return lo;
    }

    /**
     * Returns the most significant 64 bits.
     */
    public long getHi() {
        return hi;
    }

    /**
     * Returns the value as a 16-byte array (little-endian).
     */
    public byte[] toBytes() {
        byte[] bytes = new byte[16];
        ByteBuffer buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
        buf.putLong(lo);
        buf.putLong(hi);
        return bytes;
    }

    /**
     * Returns true if this value is zero.
     */
    public boolean isZero() {
        return lo == 0 && hi == 0;
    }

    @Override
    public boolean equals(Object obj) {
        if (this == obj)
            return true;
        if (!(obj instanceof UInt128))
            return false;
        UInt128 other = (UInt128) obj;
        return lo == other.lo && hi == other.hi;
    }

    @Override
    public int hashCode() {
        return Long.hashCode(lo) * 31 + Long.hashCode(hi);
    }

    @Override
    public String toString() {
        if (isZero()) {
            return "0";
        }
        // Format as hex for readability
        return String.format("%016x%016x", hi, lo);
    }
}
