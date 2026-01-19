// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

/////////////////////////////////////////////////////////////
// Conflict Resolution Types (v2.2)                        //
// Active-Active Replication Support                       //
/////////////////////////////////////////////////////////////

using System;
using System.Collections.Generic;

namespace ArcherDB;

/// <summary>
/// Policy for resolving write conflicts in active-active replication.
/// https://docs.archerdb.io/reference/active-active#resolution-policy
/// </summary>
public enum ConflictResolutionPolicy : byte
{
    /// <summary>
    /// Highest timestamp wins (default).
    /// </summary>
    LastWriterWins = 0,

    /// <summary>
    /// Primary region write takes precedence.
    /// </summary>
    PrimaryWins = 1,

    /// <summary>
    /// Application-provided resolution function.
    /// </summary>
    CustomHook = 2,
}

/// <summary>
/// A single entry in a vector clock.
/// https://docs.archerdb.io/reference/active-active#vector-clock
/// </summary>
public class VectorClockEntry
{
    /// <summary>
    /// Region identifier.
    /// </summary>
    public string RegionId { get; set; } = "";

    /// <summary>
    /// Logical timestamp for this region.
    /// </summary>
    public ulong Timestamp { get; set; }
}

/// <summary>
/// Vector clock for tracking causality in distributed systems.
/// https://docs.archerdb.io/reference/active-active#vector-clock
/// </summary>
public class VectorClock
{
    /// <summary>
    /// Clock entries keyed by region ID.
    /// </summary>
    public Dictionary<string, ulong> Entries { get; set; } = new();

    /// <summary>
    /// Creates an empty vector clock.
    /// </summary>
    public VectorClock() { }

    /// <summary>
    /// Creates a vector clock with initial entries.
    /// </summary>
    public VectorClock(Dictionary<string, ulong> entries)
    {
        Entries = new Dictionary<string, ulong>(entries);
    }

    /// <summary>
    /// Increments the timestamp for a region.
    /// </summary>
    public void Increment(string regionId)
    {
        if (Entries.TryGetValue(regionId, out var current))
            Entries[regionId] = current + 1;
        else
            Entries[regionId] = 1;
    }

    /// <summary>
    /// Merges another vector clock into this one (takes max of each entry).
    /// </summary>
    public void Merge(VectorClock other)
    {
        foreach (var kvp in other.Entries)
        {
            if (Entries.TryGetValue(kvp.Key, out var current))
                Entries[kvp.Key] = Math.Max(current, kvp.Value);
            else
                Entries[kvp.Key] = kvp.Value;
        }
    }

    /// <summary>
    /// Compares two vector clocks.
    /// Returns: -1 if this &lt; other, 0 if concurrent, 1 if this &gt; other
    /// </summary>
    public int Compare(VectorClock other)
    {
        bool thisGreater = false;
        bool otherGreater = false;

        // Check all entries in this clock
        foreach (var kvp in Entries)
        {
            other.Entries.TryGetValue(kvp.Key, out var otherValue);
            if (kvp.Value > otherValue) thisGreater = true;
            if (kvp.Value < otherValue) otherGreater = true;
        }

        // Check entries only in other clock
        foreach (var kvp in other.Entries)
        {
            if (!Entries.ContainsKey(kvp.Key) && kvp.Value > 0)
                otherGreater = true;
        }

        if (thisGreater && !otherGreater) return 1;
        if (otherGreater && !thisGreater) return -1;
        return 0; // Concurrent
    }

    /// <summary>
    /// Returns true if this clock happened before or is concurrent with other.
    /// </summary>
    public bool HappenedBefore(VectorClock other) => Compare(other) <= 0;

    /// <summary>
    /// Returns true if the clocks are concurrent (neither happened before the other).
    /// </summary>
    public bool IsConcurrent(VectorClock other) => Compare(other) == 0;
}

/// <summary>
/// Information about a detected conflict.
/// https://docs.archerdb.io/reference/active-active#conflict
/// </summary>
public class ConflictInfo
{
    /// <summary>
    /// The entity ID with the conflict.
    /// </summary>
    public UInt128 EntityId { get; set; }

    /// <summary>
    /// Vector clock of the local write.
    /// </summary>
    public VectorClock LocalClock { get; set; } = new();

    /// <summary>
    /// Vector clock of the remote write.
    /// </summary>
    public VectorClock RemoteClock { get; set; } = new();

    /// <summary>
    /// Region ID where local write originated.
    /// </summary>
    public string LocalRegion { get; set; } = "";

    /// <summary>
    /// Region ID where remote write originated.
    /// </summary>
    public string RemoteRegion { get; set; } = "";

    /// <summary>
    /// Timestamp of the local write (nanoseconds).
    /// </summary>
    public ulong LocalTimestamp { get; set; }

    /// <summary>
    /// Timestamp of the remote write (nanoseconds).
    /// </summary>
    public ulong RemoteTimestamp { get; set; }
}

/// <summary>
/// Result of conflict resolution.
/// https://docs.archerdb.io/reference/active-active#resolution
/// </summary>
public class ConflictResolution
{
    /// <summary>
    /// The winning region ID.
    /// </summary>
    public string WinningRegion { get; set; } = "";

    /// <summary>
    /// The policy used for resolution.
    /// </summary>
    public ConflictResolutionPolicy Policy { get; set; }

    /// <summary>
    /// The merged vector clock after resolution.
    /// </summary>
    public VectorClock MergedClock { get; set; } = new();

    /// <summary>
    /// Whether the local write won.
    /// </summary>
    public bool LocalWins { get; set; }
}

/// <summary>
/// Statistics about conflict resolution.
/// https://docs.archerdb.io/reference/active-active#stats
/// </summary>
public class ConflictStats
{
    /// <summary>
    /// Total conflicts detected.
    /// </summary>
    public ulong TotalConflicts { get; set; }

    /// <summary>
    /// Conflicts resolved by last-writer-wins.
    /// </summary>
    public ulong LastWriterWinsCount { get; set; }

    /// <summary>
    /// Conflicts resolved by primary-wins.
    /// </summary>
    public ulong PrimaryWinsCount { get; set; }

    /// <summary>
    /// Conflicts resolved by custom hook.
    /// </summary>
    public ulong CustomHookCount { get; set; }

    /// <summary>
    /// Timestamp of last conflict (nanoseconds).
    /// </summary>
    public ulong LastConflictTimestamp { get; set; }
}

/// <summary>
/// Entry in the conflict audit log.
/// https://docs.archerdb.io/reference/active-active#audit
/// </summary>
public class ConflictAuditEntry
{
    /// <summary>
    /// Unique ID for this audit entry.
    /// </summary>
    public ulong AuditId { get; set; }

    /// <summary>
    /// The entity ID with the conflict.
    /// </summary>
    public UInt128 EntityId { get; set; }

    /// <summary>
    /// Timestamp when conflict was detected (nanoseconds).
    /// </summary>
    public ulong DetectedTimestamp { get; set; }

    /// <summary>
    /// The winning region ID.
    /// </summary>
    public string WinningRegion { get; set; } = "";

    /// <summary>
    /// The losing region ID.
    /// </summary>
    public string LosingRegion { get; set; } = "";

    /// <summary>
    /// The resolution policy used.
    /// </summary>
    public ConflictResolutionPolicy Policy { get; set; }

    /// <summary>
    /// Serialized winning write data (for auditing).
    /// </summary>
    public byte[]? WinningData { get; set; }

    /// <summary>
    /// Serialized losing write data (for auditing).
    /// </summary>
    public byte[]? LosingData { get; set; }
}
