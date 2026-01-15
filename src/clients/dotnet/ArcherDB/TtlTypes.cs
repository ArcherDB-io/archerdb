// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//
// TTL operation types for ArcherDB .NET SDK.
// These types match the wire format defined in src/ttl.zig.

using System;
using System.Runtime.InteropServices;

namespace ArcherDB;

/// <summary>
/// Result codes for TTL operations.
/// </summary>
public enum TtlOperationResult : byte
{
    /// <summary>Operation succeeded.</summary>
    Success = 0,

    /// <summary>Entity not found.</summary>
    EntityNotFound = 1,

    /// <summary>Invalid TTL value.</summary>
    InvalidTtl = 2,

    /// <summary>Operation not permitted.</summary>
    NotPermitted = 3,

    /// <summary>Entity is immutable (system entity).</summary>
    EntityImmutable = 4,
}

/// <summary>
/// Request to set an absolute TTL for an entity.
/// Wire format: 64 bytes.
/// </summary>
[StructLayout(LayoutKind.Sequential, Size = SIZE)]
public struct TtlSetRequest
{
    public const int SIZE = 64;

    /// <summary>Entity ID to modify.</summary>
    public UInt128 EntityId;

    /// <summary>New TTL value in seconds (0 = never expires).</summary>
    public uint TtlSeconds;

    /// <summary>Reserved for future flags.</summary>
    public uint Flags;

    // Reserved padding (40 bytes)
    private unsafe fixed byte reserved[40];
}

/// <summary>
/// Response from a TTL set operation.
/// Wire format: 64 bytes.
/// </summary>
[StructLayout(LayoutKind.Sequential, Size = SIZE)]
public struct TtlSetResponse
{
    public const int SIZE = 64;

    /// <summary>Entity ID that was modified.</summary>
    public UInt128 EntityId;

    /// <summary>Previous TTL value in seconds.</summary>
    public uint PreviousTtlSeconds;

    /// <summary>New TTL value in seconds.</summary>
    public uint NewTtlSeconds;

    /// <summary>Operation result.</summary>
    public TtlOperationResult Result;

    // Padding for alignment (3 bytes)
    private unsafe fixed byte _padding[3];

    // Reserved (32 bytes)
    private unsafe fixed byte reserved[32];
}

/// <summary>
/// Request to extend an entity's TTL by a relative amount.
/// Wire format: 64 bytes.
/// </summary>
[StructLayout(LayoutKind.Sequential, Size = SIZE)]
public struct TtlExtendRequest
{
    public const int SIZE = 64;

    /// <summary>Entity ID to modify.</summary>
    public UInt128 EntityId;

    /// <summary>Amount to extend TTL by (seconds).</summary>
    public uint ExtendBySeconds;

    /// <summary>Reserved for future flags.</summary>
    public uint Flags;

    // Reserved padding (40 bytes)
    private unsafe fixed byte reserved[40];
}

/// <summary>
/// Response from a TTL extend operation.
/// Wire format: 64 bytes.
/// </summary>
[StructLayout(LayoutKind.Sequential, Size = SIZE)]
public struct TtlExtendResponse
{
    public const int SIZE = 64;

    /// <summary>Entity ID that was modified.</summary>
    public UInt128 EntityId;

    /// <summary>Previous TTL value in seconds.</summary>
    public uint PreviousTtlSeconds;

    /// <summary>New TTL value in seconds.</summary>
    public uint NewTtlSeconds;

    /// <summary>Operation result.</summary>
    public TtlOperationResult Result;

    // Padding for alignment (3 bytes)
    private unsafe fixed byte _padding[3];

    // Reserved (32 bytes)
    private unsafe fixed byte reserved[32];
}

/// <summary>
/// Request to clear an entity's TTL (make it never expire).
/// Wire format: 64 bytes.
/// </summary>
[StructLayout(LayoutKind.Sequential, Size = SIZE)]
public struct TtlClearRequest
{
    public const int SIZE = 64;

    /// <summary>Entity ID to modify.</summary>
    public UInt128 EntityId;

    /// <summary>Reserved for future flags.</summary>
    public uint Flags;

    // Reserved padding (44 bytes)
    private unsafe fixed byte reserved[44];
}

/// <summary>
/// Response from a TTL clear operation.
/// Wire format: 64 bytes.
/// </summary>
[StructLayout(LayoutKind.Sequential, Size = SIZE)]
public struct TtlClearResponse
{
    public const int SIZE = 64;

    /// <summary>Entity ID that was modified.</summary>
    public UInt128 EntityId;

    /// <summary>Previous TTL value in seconds.</summary>
    public uint PreviousTtlSeconds;

    /// <summary>Operation result.</summary>
    public TtlOperationResult Result;

    // Padding for alignment (3 bytes)
    private unsafe fixed byte _padding[3];

    // Reserved (36 bytes)
    private unsafe fixed byte reserved[36];
}
