package com.archerdb.geo;

import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.Test;

import java.util.HashSet;
import java.util.Set;

/**
 * Unit tests for UInt128.
 */
class UInt128Test {

    @Test
    void testZero() {
        UInt128 zero = UInt128.ZERO;
        assertEquals(0L, zero.getLo());
        assertEquals(0L, zero.getHi());
    }

    @Test
    void testRandom() {
        UInt128 random = UInt128.random();

        // Random should be non-zero (extremely high probability)
        assertNotEquals(UInt128.ZERO, random);
    }

    @Test
    void testRandomUniqueness() {
        Set<UInt128> ids = new HashSet<>();
        int count = 1000;

        for (int i = 0; i < count; i++) {
            UInt128 id = UInt128.random();
            assertTrue(ids.add(id), "Generated duplicate ID");
        }

        assertEquals(count, ids.size());
    }

    @Test
    void testFromLong() {
        UInt128 id = UInt128.fromLong(12345678L);

        assertEquals(12345678L, id.getLo());
        assertEquals(0L, id.getHi());
    }

    @Test
    void testFromParts() {
        UInt128 id = new UInt128(0x123456789ABCDEF0L, 0xFEDCBA9876543210L);

        assertEquals(0x123456789ABCDEF0L, id.getLo());
        assertEquals(0xFEDCBA9876543210L, id.getHi());
    }

    @Test
    void testEquals() {
        UInt128 a = new UInt128(100L, 200L);
        UInt128 b = new UInt128(100L, 200L);
        UInt128 c = new UInt128(100L, 201L);
        UInt128 d = new UInt128(101L, 200L);

        assertEquals(a, b);
        assertNotEquals(a, c);
        assertNotEquals(a, d);
    }

    @Test
    void testHashCode() {
        UInt128 a = new UInt128(100L, 200L);
        UInt128 b = new UInt128(100L, 200L);

        assertEquals(a.hashCode(), b.hashCode());
    }

    @Test
    void testToString() {
        UInt128 id = UInt128.fromLong(12345678L);
        String str = id.toString();

        assertNotNull(str);
        assertFalse(str.isEmpty());
    }

    @Test
    void testToHexString() {
        UInt128 id = new UInt128(0x123456789ABCDEF0L, 0xFEDCBA9876543210L);
        String hex = id.toHexString();

        assertNotNull(hex);
        // Should be 32 hex chars (128 bits / 4 bits per char)
        assertEquals(32, hex.length());
    }
}
