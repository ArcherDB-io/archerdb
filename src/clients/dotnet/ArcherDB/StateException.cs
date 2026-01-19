// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors

using System;

namespace ArcherDB;

/// <summary>
/// State error codes returned by state-machine operations.
/// </summary>
public enum StateError : byte
{
    /// <summary>
    /// Entity UUID not found.
    /// </summary>
    EntityNotFound = 200,

    /// <summary>
    /// Entity expired due to TTL.
    /// </summary>
    EntityExpired = 210,
}

/// <summary>
/// Exception thrown when the state machine returns an explicit error code.
/// </summary>
public sealed class StateException : Exception
{
    /// <summary>
    /// State error code.
    /// </summary>
    public StateError Error { get; }

    public StateException(StateError error)
        : base($"State error: {error} ({(byte)error}).")
    {
        Error = error;
    }
}
