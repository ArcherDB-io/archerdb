// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//
// GeoClient provides high-level geospatial operations for ArcherDB.

using System;
using System.Threading.Tasks;

namespace ArcherDB;

/// <summary>
/// Client for ArcherDB geospatial operations.
/// Provides methods for inserting, querying, and managing geo events.
/// </summary>
public sealed class GeoClient : IDisposable
{
    private readonly UInt128 clusterID;
    private readonly NativeClient nativeClient;

    /// <summary>
    /// Creates a new GeoClient connected to the specified ArcherDB cluster.
    /// </summary>
    /// <param name="clusterID">The cluster ID to connect to.</param>
    /// <param name="addresses">Array of server addresses (e.g., "127.0.0.1:3000").</param>
    public GeoClient(UInt128 clusterID, string[] addresses)
    {
        this.nativeClient = NativeClient.Init(clusterID, addresses);
        this.clusterID = clusterID;
    }

    ~GeoClient()
    {
        if (nativeClient != null)
        {
            Dispose(disposing: false);
        }
    }

    /// <summary>
    /// The cluster ID this client is connected to.
    /// </summary>
    public UInt128 ClusterID => clusterID;

    // ========================================================================
    // Insert Operations
    // ========================================================================

    /// <summary>
    /// Inserts a single geo event into the database.
    /// </summary>
    /// <param name="geoEvent">The geo event to insert.</param>
    /// <returns>The result of the insert operation.</returns>
    public InsertGeoEventResult InsertEvent(GeoEvent geoEvent)
    {
        var ret = nativeClient.CallRequest<InsertGeoEventsResult, GeoEvent>(TBOperation.InsertEvents, new[] { geoEvent });
        return ret.Length == 0 ? InsertGeoEventResult.Ok : ret[0].Result;
    }

    /// <summary>
    /// Inserts a batch of geo events into the database.
    /// </summary>
    /// <param name="batch">The geo events to insert.</param>
    /// <returns>Array of results for events that had errors (empty if all succeeded).</returns>
    public InsertGeoEventsResult[] InsertEvents(ReadOnlySpan<GeoEvent> batch)
    {
        return nativeClient.CallRequest<InsertGeoEventsResult, GeoEvent>(TBOperation.InsertEvents, batch);
    }

    /// <summary>
    /// Inserts a single geo event into the database asynchronously.
    /// </summary>
    /// <param name="geoEvent">The geo event to insert.</param>
    /// <returns>The result of the insert operation.</returns>
    public Task<InsertGeoEventResult> InsertEventAsync(GeoEvent geoEvent)
    {
        return nativeClient.CallRequestAsync<InsertGeoEventsResult, GeoEvent>(TBOperation.InsertEvents, new[] { geoEvent })
            .ContinueWith(x => x.Result.Length == 0 ? InsertGeoEventResult.Ok : x.Result[0].Result);
    }

    /// <summary>
    /// Inserts a batch of geo events into the database asynchronously.
    /// </summary>
    /// <param name="batch">The geo events to insert.</param>
    /// <returns>Array of results for events that had errors (empty if all succeeded).</returns>
    public Task<InsertGeoEventsResult[]> InsertEventsAsync(ReadOnlyMemory<GeoEvent> batch)
    {
        return nativeClient.CallRequestAsync<InsertGeoEventsResult, GeoEvent>(TBOperation.InsertEvents, batch);
    }

    // ========================================================================
    // Delete Operations
    // ========================================================================

    /// <summary>
    /// Deletes a single entity from the database.
    /// </summary>
    /// <param name="entityId">The entity ID to delete.</param>
    /// <returns>The result of the delete operation.</returns>
    public DeleteEntityResult DeleteEntity(UInt128 entityId)
    {
        var ret = nativeClient.CallRequest<DeleteEntitiesResult, UInt128>(TBOperation.DeleteEntities, new[] { entityId });
        return ret.Length == 0 ? DeleteEntityResult.Ok : ret[0].Result;
    }

    /// <summary>
    /// Deletes multiple entities from the database.
    /// </summary>
    /// <param name="batch">The entity IDs to delete.</param>
    /// <returns>Array of results for entities that had errors (empty if all succeeded).</returns>
    public DeleteEntitiesResult[] DeleteEntities(ReadOnlySpan<UInt128> batch)
    {
        return nativeClient.CallRequest<DeleteEntitiesResult, UInt128>(TBOperation.DeleteEntities, batch);
    }

    /// <summary>
    /// Deletes a single entity from the database asynchronously.
    /// </summary>
    /// <param name="entityId">The entity ID to delete.</param>
    /// <returns>The result of the delete operation.</returns>
    public Task<DeleteEntityResult> DeleteEntityAsync(UInt128 entityId)
    {
        return nativeClient.CallRequestAsync<DeleteEntitiesResult, UInt128>(TBOperation.DeleteEntities, new[] { entityId })
            .ContinueWith(x => x.Result.Length == 0 ? DeleteEntityResult.Ok : x.Result[0].Result);
    }

    /// <summary>
    /// Deletes multiple entities from the database asynchronously.
    /// </summary>
    /// <param name="batch">The entity IDs to delete.</param>
    /// <returns>Array of results for entities that had errors (empty if all succeeded).</returns>
    public Task<DeleteEntitiesResult[]> DeleteEntitiesAsync(ReadOnlyMemory<UInt128> batch)
    {
        return nativeClient.CallRequestAsync<DeleteEntitiesResult, UInt128>(TBOperation.DeleteEntities, batch);
    }

    // ========================================================================
    // Query Operations
    // ========================================================================

    /// <summary>
    /// Queries geo events by entity UUID.
    /// </summary>
    /// <param name="filter">The UUID query filter.</param>
    /// <returns>Array of matching geo events.</returns>
    public GeoEvent[] QueryByUuid(QueryUuidFilter filter)
    {
        return nativeClient.CallRequest<GeoEvent, QueryUuidFilter>(TBOperation.QueryUuid, new[] { filter });
    }

    /// <summary>
    /// Queries geo events by entity UUID asynchronously.
    /// </summary>
    /// <param name="filter">The UUID query filter.</param>
    /// <returns>Array of matching geo events.</returns>
    public Task<GeoEvent[]> QueryByUuidAsync(QueryUuidFilter filter)
    {
        return nativeClient.CallRequestAsync<GeoEvent, QueryUuidFilter>(TBOperation.QueryUuid, new[] { filter });
    }

    /// <summary>
    /// Queries geo events within a radius.
    /// </summary>
    /// <param name="filter">The radius query filter.</param>
    /// <returns>Array of matching geo events.</returns>
    public GeoEvent[] QueryByRadius(QueryRadiusFilter filter)
    {
        return nativeClient.CallRequest<GeoEvent, QueryRadiusFilter>(TBOperation.QueryRadius, new[] { filter });
    }

    /// <summary>
    /// Queries geo events within a radius asynchronously.
    /// </summary>
    /// <param name="filter">The radius query filter.</param>
    /// <returns>Array of matching geo events.</returns>
    public Task<GeoEvent[]> QueryByRadiusAsync(QueryRadiusFilter filter)
    {
        return nativeClient.CallRequestAsync<GeoEvent, QueryRadiusFilter>(TBOperation.QueryRadius, new[] { filter });
    }

    /// <summary>
    /// Queries geo events within a polygon.
    /// </summary>
    /// <param name="filter">The polygon query filter.</param>
    /// <returns>Array of matching geo events.</returns>
    public GeoEvent[] QueryByPolygon(QueryPolygonFilter filter)
    {
        return nativeClient.CallRequest<GeoEvent, QueryPolygonFilter>(TBOperation.QueryPolygon, new[] { filter });
    }

    /// <summary>
    /// Queries geo events within a polygon asynchronously.
    /// </summary>
    /// <param name="filter">The polygon query filter.</param>
    /// <returns>Array of matching geo events.</returns>
    public Task<GeoEvent[]> QueryByPolygonAsync(QueryPolygonFilter filter)
    {
        return nativeClient.CallRequestAsync<GeoEvent, QueryPolygonFilter>(TBOperation.QueryPolygon, new[] { filter });
    }

    /// <summary>
    /// Queries the latest geo events.
    /// </summary>
    /// <param name="filter">The latest query filter.</param>
    /// <returns>Array of matching geo events.</returns>
    public GeoEvent[] QueryLatest(QueryLatestFilter filter)
    {
        return nativeClient.CallRequest<GeoEvent, QueryLatestFilter>(TBOperation.QueryLatest, new[] { filter });
    }

    /// <summary>
    /// Queries the latest geo events asynchronously.
    /// </summary>
    /// <param name="filter">The latest query filter.</param>
    /// <returns>Array of matching geo events.</returns>
    public Task<GeoEvent[]> QueryLatestAsync(QueryLatestFilter filter)
    {
        return nativeClient.CallRequestAsync<GeoEvent, QueryLatestFilter>(TBOperation.QueryLatest, new[] { filter });
    }

    // ========================================================================
    // TTL Operations
    // ========================================================================

    /// <summary>
    /// Sets an absolute TTL for an entity.
    /// </summary>
    /// <param name="entityId">Entity UUID to set TTL for.</param>
    /// <param name="ttlSeconds">Absolute TTL in seconds (0 = never expires).</param>
    /// <returns>TTL set response with previous and new TTL values.</returns>
    /// <exception cref="ArgumentException">If entityId is zero.</exception>
    /// <example>
    /// <code>
    /// // Set entity to expire in 1 hour
    /// var response = client.SetTtl(entityId, 3600);
    /// Console.WriteLine($"Previous TTL: {response.PreviousTtlSeconds}s");
    /// Console.WriteLine($"New TTL: {response.NewTtlSeconds}s");
    /// </code>
    /// </example>
    public TtlSetResponse SetTtl(UInt128 entityId, uint ttlSeconds)
    {
        if (entityId == UInt128.Zero)
        {
            throw new ArgumentException("entityId must not be zero", nameof(entityId));
        }

        var request = new TtlSetRequest
        {
            EntityId = entityId,
            TtlSeconds = ttlSeconds,
            Flags = 0,
        };

        var results = nativeClient.CallRequest<TtlSetResponse, TtlSetRequest>(TBOperation.TtlSet, new[] { request });

        if (results.Length == 0)
        {
            throw new InvalidOperationException("No response from TTL set operation");
        }

        return results[0];
    }

    /// <summary>
    /// Sets an absolute TTL for an entity asynchronously.
    /// </summary>
    /// <param name="entityId">Entity UUID to set TTL for.</param>
    /// <param name="ttlSeconds">Absolute TTL in seconds (0 = never expires).</param>
    /// <returns>TTL set response with previous and new TTL values.</returns>
    /// <exception cref="ArgumentException">If entityId is zero.</exception>
    public async Task<TtlSetResponse> SetTtlAsync(UInt128 entityId, uint ttlSeconds)
    {
        if (entityId == UInt128.Zero)
        {
            throw new ArgumentException("entityId must not be zero", nameof(entityId));
        }

        var request = new TtlSetRequest
        {
            EntityId = entityId,
            TtlSeconds = ttlSeconds,
            Flags = 0,
        };

        var results = await nativeClient.CallRequestAsync<TtlSetResponse, TtlSetRequest>(TBOperation.TtlSet, new[] { request })
            .ConfigureAwait(false);

        if (results.Length == 0)
        {
            throw new InvalidOperationException("No response from TTL set operation");
        }

        return results[0];
    }

    /// <summary>
    /// Extends an entity's TTL by a relative amount.
    /// </summary>
    /// <param name="entityId">Entity UUID to extend TTL for.</param>
    /// <param name="extendBySeconds">Number of seconds to extend the TTL by.</param>
    /// <returns>TTL extend response with previous and new TTL values.</returns>
    /// <exception cref="ArgumentException">If entityId is zero.</exception>
    /// <example>
    /// <code>
    /// // Extend TTL by 1 day
    /// var response = client.ExtendTtl(entityId, 86400);
    /// Console.WriteLine($"Previous TTL: {response.PreviousTtlSeconds}s");
    /// Console.WriteLine($"New TTL: {response.NewTtlSeconds}s");
    /// </code>
    /// </example>
    public TtlExtendResponse ExtendTtl(UInt128 entityId, uint extendBySeconds)
    {
        if (entityId == UInt128.Zero)
        {
            throw new ArgumentException("entityId must not be zero", nameof(entityId));
        }

        var request = new TtlExtendRequest
        {
            EntityId = entityId,
            ExtendBySeconds = extendBySeconds,
            Flags = 0,
        };

        var results = nativeClient.CallRequest<TtlExtendResponse, TtlExtendRequest>(TBOperation.TtlExtend, new[] { request });

        if (results.Length == 0)
        {
            throw new InvalidOperationException("No response from TTL extend operation");
        }

        return results[0];
    }

    /// <summary>
    /// Extends an entity's TTL by a relative amount asynchronously.
    /// </summary>
    /// <param name="entityId">Entity UUID to extend TTL for.</param>
    /// <param name="extendBySeconds">Number of seconds to extend the TTL by.</param>
    /// <returns>TTL extend response with previous and new TTL values.</returns>
    /// <exception cref="ArgumentException">If entityId is zero.</exception>
    public async Task<TtlExtendResponse> ExtendTtlAsync(UInt128 entityId, uint extendBySeconds)
    {
        if (entityId == UInt128.Zero)
        {
            throw new ArgumentException("entityId must not be zero", nameof(entityId));
        }

        var request = new TtlExtendRequest
        {
            EntityId = entityId,
            ExtendBySeconds = extendBySeconds,
            Flags = 0,
        };

        var results = await nativeClient.CallRequestAsync<TtlExtendResponse, TtlExtendRequest>(TBOperation.TtlExtend, new[] { request })
            .ConfigureAwait(false);

        if (results.Length == 0)
        {
            throw new InvalidOperationException("No response from TTL extend operation");
        }

        return results[0];
    }

    /// <summary>
    /// Clears an entity's TTL, making it never expire.
    /// </summary>
    /// <param name="entityId">Entity UUID to clear TTL for.</param>
    /// <returns>TTL clear response with previous TTL value.</returns>
    /// <exception cref="ArgumentException">If entityId is zero.</exception>
    /// <example>
    /// <code>
    /// // Make entity permanent (no expiration)
    /// var response = client.ClearTtl(entityId);
    /// Console.WriteLine($"Previous TTL: {response.PreviousTtlSeconds}s");
    /// </code>
    /// </example>
    public TtlClearResponse ClearTtl(UInt128 entityId)
    {
        if (entityId == UInt128.Zero)
        {
            throw new ArgumentException("entityId must not be zero", nameof(entityId));
        }

        var request = new TtlClearRequest
        {
            EntityId = entityId,
            Flags = 0,
        };

        var results = nativeClient.CallRequest<TtlClearResponse, TtlClearRequest>(TBOperation.TtlClear, new[] { request });

        if (results.Length == 0)
        {
            throw new InvalidOperationException("No response from TTL clear operation");
        }

        return results[0];
    }

    /// <summary>
    /// Clears an entity's TTL, making it never expire, asynchronously.
    /// </summary>
    /// <param name="entityId">Entity UUID to clear TTL for.</param>
    /// <returns>TTL clear response with previous TTL value.</returns>
    /// <exception cref="ArgumentException">If entityId is zero.</exception>
    public async Task<TtlClearResponse> ClearTtlAsync(UInt128 entityId)
    {
        if (entityId == UInt128.Zero)
        {
            throw new ArgumentException("entityId must not be zero", nameof(entityId));
        }

        var request = new TtlClearRequest
        {
            EntityId = entityId,
            Flags = 0,
        };

        var results = await nativeClient.CallRequestAsync<TtlClearResponse, TtlClearRequest>(TBOperation.TtlClear, new[] { request })
            .ConfigureAwait(false);

        if (results.Length == 0)
        {
            throw new InvalidOperationException("No response from TTL clear operation");
        }

        return results[0];
    }

    // ========================================================================
    // Dispose
    // ========================================================================

    /// <summary>
    /// Disposes of the client and releases all resources.
    /// </summary>
    public void Dispose()
    {
        GC.SuppressFinalize(this);
        Dispose(disposing: true);
    }

    private void Dispose(bool disposing)
    {
        _ = disposing;
        nativeClient.Dispose();
    }
}
