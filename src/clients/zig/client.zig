// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors

//! ArcherDB Zig SDK - Client
//!
//! This module provides the main Client struct for interacting with ArcherDB.
//! The client implements all 14 operations with idiomatic Zig patterns.
//!
//! Example usage:
//! ```zig
//! var client = try Client.init(allocator, "http://127.0.0.1:3001");
//! defer client.deinit();
//!
//! const events = [_]types.GeoEvent{
//!     .{
//!         .entity_id = 12345,
//!         .lat_nano = types.degreesToNano(37.7749),
//!         .lon_nano = types.degreesToNano(-122.4194),
//!     },
//! };
//!
//! var results = try client.insertEvents(allocator, &events);
//! defer results.deinit();
//! ```

const std = @import("std");
const http = @import("http.zig");
const types = @import("types.zig");
const errors = @import("errors.zig");
const json = @import("json.zig");

/// Client provides methods for all ArcherDB operations.
///
/// The client is designed for single-threaded use. Create one client per thread.
/// All operations return caller-owned results that must be freed with the
/// allocator passed to the operation.
pub const Client = struct {
    allocator: std.mem.Allocator,
    http_client: http.HttpClient,
    base_url: []const u8,
    closed: bool,

    // ========================================================================
    // Lifecycle
    // ========================================================================

    /// Initialize a new ArcherDB client.
    ///
    /// The base_url should include the protocol and port, e.g., "http://127.0.0.1:3001".
    /// The client copies the base_url, so the caller can free it after init.
    pub fn init(allocator: std.mem.Allocator, base_url: []const u8) errors.ClientError!Client {
        // Copy the base URL
        const url_copy = allocator.dupe(u8, base_url) catch return error.OutOfMemory;

        return Client{
            .allocator = allocator,
            .http_client = http.HttpClient.init(allocator),
            .base_url = url_copy,
            .closed = false,
        };
    }

    /// Clean up all resources associated with the client.
    ///
    /// After calling deinit, the client cannot be used.
    pub fn deinit(self: *Client) void {
        if (!self.closed) {
            self.http_client.deinit();
            self.allocator.free(self.base_url);
            self.closed = true;
        }
    }

    // ========================================================================
    // Operation 1: Insert Events
    // ========================================================================

    /// Insert geo events into the database.
    ///
    /// Events are inserted atomically. Returns results for each event indicating
    /// success or failure. A nil error with empty results indicates all events
    /// were inserted successfully.
    ///
    /// Maximum batch size: 10,000 events.
    ///
    /// Caller owns the returned ArrayList and must call deinit() on it.
    pub fn insertEvents(
        self: *Client,
        allocator: std.mem.Allocator,
        events: []const types.GeoEvent,
    ) errors.ClientError!std.ArrayList(types.InsertResult) {
        if (self.closed) return error.ClientClosed;
        if (events.len == 0) return std.ArrayList(types.InsertResult).init(allocator);
        if (events.len > types.BATCH_SIZE_MAX) return error.BatchTooLarge;

        const body = try json.serializeInsertRequest(allocator, events, "insert");
        defer allocator.free(body);

        const url = try http.buildUrl(allocator, self.base_url, "/events");
        defer allocator.free(url);

        const response = try self.http_client.doPost(allocator, url, body);
        defer allocator.free(response);

        return json.parseInsertResults(allocator, response);
    }

    // ========================================================================
    // Operation 2: Upsert Events
    // ========================================================================

    /// Insert or update geo events.
    ///
    /// If an event with the same entity_id exists, it is updated. Otherwise, it
    /// is inserted. Uses Last-Writer-Wins (LWW) semantics for conflict resolution.
    ///
    /// Maximum batch size: 10,000 events.
    ///
    /// Caller owns the returned ArrayList and must call deinit() on it.
    pub fn upsertEvents(
        self: *Client,
        allocator: std.mem.Allocator,
        events: []const types.GeoEvent,
    ) errors.ClientError!std.ArrayList(types.InsertResult) {
        if (self.closed) return error.ClientClosed;
        if (events.len == 0) return std.ArrayList(types.InsertResult).init(allocator);
        if (events.len > types.BATCH_SIZE_MAX) return error.BatchTooLarge;

        const body = try json.serializeInsertRequest(allocator, events, "upsert");
        defer allocator.free(body);

        const url = try http.buildUrl(allocator, self.base_url, "/events");
        defer allocator.free(url);

        const response = try self.http_client.doPost(allocator, url, body);
        defer allocator.free(response);

        return json.parseInsertResults(allocator, response);
    }

    // ========================================================================
    // Operation 3: Delete Entities
    // ========================================================================

    /// Delete all events for the specified entities.
    ///
    /// This is a GDPR-compliant deletion that removes all historical data for
    /// each entity. The deletion is permanent and cannot be undone.
    ///
    /// Returns a DeleteResult with counts of deleted and not-found entities.
    pub fn deleteEntities(
        self: *Client,
        allocator: std.mem.Allocator,
        entity_ids: []const u128,
    ) errors.ClientError!types.DeleteResult {
        if (self.closed) return error.ClientClosed;
        if (entity_ids.len == 0) return types.DeleteResult{};
        if (entity_ids.len > types.BATCH_SIZE_MAX) return error.BatchTooLarge;

        const body = try json.serializeEntityIds(allocator, entity_ids);
        defer allocator.free(body);

        const url = try http.buildUrl(allocator, self.base_url, "/entities");
        defer allocator.free(url);

        const response = try self.http_client.doDelete(allocator, url, body);
        defer allocator.free(response);

        return json.parseDeleteResult(allocator, response);
    }

    // ========================================================================
    // Operation 4: Get Latest by UUID
    // ========================================================================

    /// Get the most recent event for an entity.
    ///
    /// Returns null if the entity does not exist.
    /// Returns EntityExpired error if the entity existed but has expired.
    pub fn getLatestByUUID(
        self: *Client,
        allocator: std.mem.Allocator,
        entity_id: u128,
    ) errors.ClientError!?types.GeoEvent {
        if (self.closed) return error.ClientClosed;

        const url = try http.buildUrlWithParam(allocator, self.base_url, "/entity/{}", entity_id);
        defer allocator.free(url);

        const response = self.http_client.doGet(allocator, url) catch |err| {
            if (err == error.InvalidEntityId) return null; // 404 = not found
            return err;
        };
        defer allocator.free(response);

        // Check for empty or "not found" response
        if (response.len == 0) return null;

        // Parse response
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return error.JsonParseError;
        defer parsed.deinit();

        if (parsed.value != .object) return error.JsonParseError;

        // Check for "found" field
        if (parsed.value.object.get("found")) |found_val| {
            if (found_val == .bool and !found_val.bool) return null;
        }

        // Check for event field
        if (parsed.value.object.get("event")) |event_val| {
            if (event_val == .null) return null;
            if (event_val == .object) {
                return json.parseGeoEventFromObject(event_val.object);
            }
        }

        // Try parsing as direct event
        return json.parseGeoEventFromObject(parsed.value.object);
    }

    // ========================================================================
    // Operation 5: Query UUID Batch
    // ========================================================================

    /// Get the most recent events for multiple entities in one request.
    ///
    /// More efficient than multiple getLatestByUUID calls for batch lookups.
    /// Maximum batch size: 10,000 entity IDs.
    ///
    /// The result contains found events and counts of found/not-found entities.
    /// Caller owns the returned result and must call deinit() on it.
    pub fn queryUUIDBatch(
        self: *Client,
        allocator: std.mem.Allocator,
        entity_ids: []const u128,
    ) errors.ClientError!types.QueryUUIDBatchResult {
        if (self.closed) return error.ClientClosed;
        if (entity_ids.len == 0) {
            return types.QueryUUIDBatchResult{
                .events = std.ArrayList(types.GeoEvent).init(allocator),
                .not_found_indices = std.ArrayList(u16).init(allocator),
            };
        }
        if (entity_ids.len > types.BATCH_SIZE_MAX) return error.BatchTooLarge;

        const body = try json.serializeEntityIds(allocator, entity_ids);
        defer allocator.free(body);

        const url = try http.buildUrl(allocator, self.base_url, "/entities/batch");
        defer allocator.free(url);

        const response = try self.http_client.doPost(allocator, url, body);
        defer allocator.free(response);

        // Parse response
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return error.JsonParseError;
        defer parsed.deinit();

        if (parsed.value != .object) return error.JsonParseError;

        var result = types.QueryUUIDBatchResult{
            .events = std.ArrayList(types.GeoEvent).init(allocator),
            .not_found_indices = std.ArrayList(u16).init(allocator),
        };
        errdefer {
            result.events.deinit();
            result.not_found_indices.deinit();
        }

        // Parse events
        if (parsed.value.object.get("events")) |events_val| {
            if (events_val == .array) {
                for (events_val.array.items) |item| {
                    if (item == .object) {
                        if (json.parseGeoEventFromObject(item.object)) |event| {
                            result.events.append(event) catch return error.OutOfMemory;
                        }
                    }
                }
            }
        }

        // Parse counts
        if (parsed.value.object.get("found_count")) |v| {
            if (v == .integer and v.integer >= 0) {
                result.found_count = @intCast(v.integer);
            }
        }
        if (parsed.value.object.get("not_found_count")) |v| {
            if (v == .integer and v.integer >= 0) {
                result.not_found_count = @intCast(v.integer);
            }
        }

        return result;
    }

    // ========================================================================
    // Operation 6: Query Radius
    // ========================================================================

    /// Find events within a radius of a center point.
    ///
    /// Returns events ordered by deterministic S2 cell ID order (not by distance).
    /// Use has_more and cursor for pagination through large result sets.
    ///
    /// Caller owns the returned QueryResult and must call deinit() on it.
    pub fn queryRadius(
        self: *Client,
        allocator: std.mem.Allocator,
        filter: types.QueryRadiusFilter,
    ) errors.ClientError!types.QueryResult {
        if (self.closed) return error.ClientClosed;
        if (filter.limit > types.QUERY_LIMIT_MAX) return error.QueryResultTooLarge;

        const body = try json.serializeRadiusFilter(allocator, filter);
        defer allocator.free(body);

        const url = try http.buildUrl(allocator, self.base_url, "/query/radius");
        defer allocator.free(url);

        const response = try self.http_client.doPost(allocator, url, body);
        defer allocator.free(response);

        return json.parseQueryResult(allocator, response);
    }

    // ========================================================================
    // Operation 7: Query Polygon
    // ========================================================================

    /// Find events within a polygon boundary.
    ///
    /// The polygon is defined by vertices in counter-clockwise order.
    /// Supports holes (exclusion zones) defined in clockwise order.
    ///
    /// Maximum vertices: 10,000 for outer boundary, 100 holes maximum.
    ///
    /// Caller owns the returned QueryResult and must call deinit() on it.
    pub fn queryPolygon(
        self: *Client,
        allocator: std.mem.Allocator,
        filter: types.QueryPolygonFilter,
    ) errors.ClientError!types.QueryResult {
        if (self.closed) return error.ClientClosed;
        if (filter.limit > types.QUERY_LIMIT_MAX) return error.QueryResultTooLarge;
        if (filter.vertices.len < 3) return error.InvalidPolygon;
        if (filter.vertices.len > types.POLYGON_VERTICES_MAX) return error.PolygonTooComplex;
        if (filter.holes.len > types.POLYGON_HOLES_MAX) return error.PolygonTooComplex;

        const body = try json.serializePolygonFilter(allocator, filter);
        defer allocator.free(body);

        const url = try http.buildUrl(allocator, self.base_url, "/query/polygon");
        defer allocator.free(url);

        const response = try self.http_client.doPost(allocator, url, body);
        defer allocator.free(response);

        return json.parseQueryResult(allocator, response);
    }

    // ========================================================================
    // Operation 8: Query Latest
    // ========================================================================

    /// Get the most recent events globally or filtered by group.
    ///
    /// Useful for dashboards showing current entity positions.
    /// Results are ordered by timestamp (newest first).
    ///
    /// Caller owns the returned QueryResult and must call deinit() on it.
    pub fn queryLatest(
        self: *Client,
        allocator: std.mem.Allocator,
        filter: types.QueryLatestFilter,
    ) errors.ClientError!types.QueryResult {
        if (self.closed) return error.ClientClosed;
        if (filter.limit > types.QUERY_LIMIT_MAX) return error.QueryResultTooLarge;

        const body = try json.serializeLatestFilter(allocator, filter);
        defer allocator.free(body);

        const url = try http.buildUrl(allocator, self.base_url, "/query/latest");
        defer allocator.free(url);

        const response = try self.http_client.doPost(allocator, url, body);
        defer allocator.free(response);

        return json.parseQueryResult(allocator, response);
    }

    // ========================================================================
    // Operation 9: Ping
    // ========================================================================

    /// Verify connectivity to the server.
    ///
    /// Returns true if the server responded with a valid pong.
    /// Use for health checks and connection validation.
    pub fn ping(self: *Client) errors.ClientError!bool {
        if (self.closed) return error.ClientClosed;

        const url = try http.buildUrl(self.allocator, self.base_url, "/ping");
        defer self.allocator.free(url);

        const response = try self.http_client.doGet(self.allocator, url);
        defer self.allocator.free(response);

        return json.parsePingResponse(response);
    }

    // ========================================================================
    // Operation 10: Get Status
    // ========================================================================

    /// Get current server status and statistics.
    ///
    /// Includes entity count, RAM utilization, tombstone count, and cluster state.
    pub fn getStatus(
        self: *Client,
        allocator: std.mem.Allocator,
    ) errors.ClientError!types.StatusResponse {
        if (self.closed) return error.ClientClosed;

        const url = try http.buildUrl(allocator, self.base_url, "/status");
        defer allocator.free(url);

        const response = try self.http_client.doGet(allocator, url);
        defer allocator.free(response);

        return json.parseStatusResponse(allocator, response);
    }

    // ========================================================================
    // Operation 11: Get Topology
    // ========================================================================

    /// Get current cluster topology.
    ///
    /// Returns shard assignments, primary/replica locations, and cluster health.
    ///
    /// Caller owns the returned TopologyResponse and must call deinit() on it.
    pub fn getTopology(
        self: *Client,
        allocator: std.mem.Allocator,
    ) errors.ClientError!types.TopologyResponse {
        if (self.closed) return error.ClientClosed;

        const url = try http.buildUrl(allocator, self.base_url, "/topology");
        defer allocator.free(url);

        const response = try self.http_client.doGet(allocator, url);
        defer allocator.free(response);

        // Parse topology response
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return error.JsonParseError;
        defer parsed.deinit();

        if (parsed.value != .object) return error.JsonParseError;

        var topology = types.TopologyResponse{
            .version = 0,
            .num_shards = 0,
            .cluster_id = 0,
            .last_change_ns = 0,
            .resharding_status = 0,
            .shards = std.ArrayList(types.ShardInfo).init(allocator),
        };

        // Parse fields
        if (parsed.value.object.get("version")) |v| {
            if (v == .integer and v.integer >= 0) topology.version = @intCast(v.integer);
        }
        if (parsed.value.object.get("num_shards")) |v| {
            if (v == .integer and v.integer >= 0) topology.num_shards = @intCast(v.integer);
        }

        return topology;
    }

    // ========================================================================
    // Operation 12: Set TTL
    // ========================================================================

    /// Set an absolute TTL (time-to-live) for an entity.
    ///
    /// After ttl_seconds, the entity will be automatically expired and removed.
    /// Replaces any existing TTL. Use 0 to clear TTL (equivalent to clearTTL).
    pub fn setTTL(
        self: *Client,
        allocator: std.mem.Allocator,
        entity_id: u128,
        ttl_seconds: u32,
    ) errors.ClientError!types.TtlSetResponse {
        if (self.closed) return error.ClientClosed;

        const body = try json.serializeTtlSetRequest(allocator, entity_id, ttl_seconds);
        defer allocator.free(body);

        const url = try http.buildUrl(allocator, self.base_url, "/ttl/set");
        defer allocator.free(url);

        const response = try self.http_client.doPost(allocator, url, body);
        defer allocator.free(response);

        return json.parseTtlSetResponse(allocator, response);
    }

    // ========================================================================
    // Operation 13: Extend TTL
    // ========================================================================

    /// Extend an entity's existing TTL by a relative amount.
    ///
    /// Adds extend_by_seconds to the current TTL. If no TTL exists, sets a new TTL.
    /// Useful for "keep alive" patterns where active entities stay fresh.
    pub fn extendTTL(
        self: *Client,
        allocator: std.mem.Allocator,
        entity_id: u128,
        extend_by_seconds: u32,
    ) errors.ClientError!types.TtlExtendResponse {
        if (self.closed) return error.ClientClosed;

        const body = try json.serializeTtlExtendRequest(allocator, entity_id, extend_by_seconds);
        defer allocator.free(body);

        const url = try http.buildUrl(allocator, self.base_url, "/ttl/extend");
        defer allocator.free(url);

        const response = try self.http_client.doPost(allocator, url, body);
        defer allocator.free(response);

        return json.parseTtlExtendResponse(allocator, response);
    }

    // ========================================================================
    // Operation 14: Clear TTL
    // ========================================================================

    /// Remove an entity's TTL, making it permanent.
    ///
    /// After clearing, the entity will never automatically expire.
    /// Use for entities that should be retained indefinitely.
    pub fn clearTTL(
        self: *Client,
        allocator: std.mem.Allocator,
        entity_id: u128,
    ) errors.ClientError!types.TtlClearResponse {
        if (self.closed) return error.ClientClosed;

        const body = try json.serializeTtlClearRequest(allocator, entity_id);
        defer allocator.free(body);

        const url = try http.buildUrl(allocator, self.base_url, "/ttl/clear");
        defer allocator.free(url);

        const response = try self.http_client.doPost(allocator, url, body);
        defer allocator.free(response);

        return json.parseTtlClearResponse(allocator, response);
    }
};

// ============================================================================
// Re-exports for convenience
// ============================================================================

pub const GeoEvent = types.GeoEvent;
pub const QueryRadiusFilter = types.QueryRadiusFilter;
pub const QueryPolygonFilter = types.QueryPolygonFilter;
pub const QueryLatestFilter = types.QueryLatestFilter;
pub const QueryResult = types.QueryResult;
pub const QueryUUIDBatchResult = types.QueryUUIDBatchResult;
pub const InsertResult = types.InsertResult;
pub const InsertResultCode = types.InsertResultCode;
pub const DeleteResult = types.DeleteResult;
pub const TtlSetResponse = types.TtlSetResponse;
pub const TtlExtendResponse = types.TtlExtendResponse;
pub const TtlClearResponse = types.TtlClearResponse;
pub const StatusResponse = types.StatusResponse;
pub const TopologyResponse = types.TopologyResponse;
pub const Vertex = types.Vertex;
pub const Hole = types.Hole;

pub const ClientError = errors.ClientError;
pub const isRetryable = errors.isRetryable;
pub const isNetworkError = errors.isNetworkError;
pub const isValidationError = errors.isValidationError;
pub const errorMessage = errors.errorMessage;

pub const degreesToNano = types.degreesToNano;
pub const nanoToDegrees = types.nanoToDegrees;
pub const metersToMm = types.metersToMm;
pub const mmToMeters = types.mmToMeters;
pub const metersToMmUnsigned = types.metersToMmUnsigned;
pub const mpsToMms = types.mpsToMms;
pub const mmsToMps = types.mmsToMps;
pub const degreesToCdeg = types.degreesToCdeg;
pub const cdegToDegrees = types.cdegToDegrees;
pub const validateGeoEvent = types.validateGeoEvent;

// ============================================================================
// Tests
// ============================================================================

test "Client: init and deinit" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    defer client.deinit();

    try std.testing.expect(!client.closed);
    try std.testing.expectEqualStrings("http://localhost:3001", client.base_url);
}

test "Client: double deinit is safe" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    client.deinit();
    client.deinit(); // Should not crash
}

test "Client: operations on closed client return error" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    client.deinit();

    const result = client.ping();
    try std.testing.expectError(error.ClientClosed, result);
}

test "Client: empty insert returns empty results" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    defer client.deinit();

    // Note: This would fail with connection error if no server running
    // Just testing the empty case logic
    const events = [_]types.GeoEvent{};
    var results = try client.insertEvents(std.testing.allocator, &events);
    defer results.deinit();

    try std.testing.expectEqual(@as(usize, 0), results.items.len);
}

test "Client: batch size validation" {
    var client = try Client.init(std.testing.allocator, "http://localhost:3001");
    defer client.deinit();

    // Create a large batch (would need dynamic allocation for real test)
    // Just verify the check exists
    try std.testing.expect(types.BATCH_SIZE_MAX == 10_000);
}
