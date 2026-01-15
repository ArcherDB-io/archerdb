// ArcherDB Java Client - Native TTL Set Batch
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2025 ArcherDB Developers

package com.archerdb.geo;

import com.archerdb.core.Batch;

/**
 * Native batch class for TTL set requests.
 *
 * <p>
 * Wire format (64 bytes per request):
 * <ul>
 * <li>offset 0: entity_id (u128, 16 bytes)</li>
 * <li>offset 16: ttl_seconds (u32, 4 bytes)</li>
 * <li>offset 20: flags (u32, 4 bytes)</li>
 * <li>offset 24: reserved (40 bytes)</li>
 * </ul>
 */
public final class NativeTtlSetBatch extends Batch {

    interface Struct {
        int SIZE = 64;
        int EntityIdLo = 0;
        int EntityIdHi = 8;
        int TtlSeconds = 16;
        int Flags = 20;
    }

    public NativeTtlSetBatch(final int capacity) {
        super(capacity, Struct.SIZE);
    }

    public void setEntityId(final long lo, final long hi) {
        putUInt64(at(Struct.EntityIdLo), lo);
        putUInt64(at(Struct.EntityIdHi), hi);
    }

    public void setTtlSeconds(final int ttlSeconds) {
        putUInt32(at(Struct.TtlSeconds), ttlSeconds);
    }

    public void setFlags(final int flags) {
        putUInt32(at(Struct.Flags), flags);
    }
}
