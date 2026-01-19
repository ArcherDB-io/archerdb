// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
const Sample = @import("./docs_types.zig").Sample;

pub const samples = [_]Sample{
    .{
        .proper_name = "Basic",
        .directory = "basic",
        .short_description = "Insert GeoEvents and query by radius and UUID.",
        .long_description =
        \\## 1. Insert GeoEvents
        \\
        \\This project inserts a small batch of GeoEvents around a base coordinate.
        \\
        \\## 2. Query by radius
        \\
        \\It then queries for events within a radius of the base coordinate to
        \\validate spatial filtering.
        \\
        \\## 3. Query by UUID
        \\
        \\Finally, it performs a UUID lookup to fetch the latest event for a single
        \\entity.
        ,
    },
    .{
        .proper_name = "Radius Query",
        .directory = "radius-query",
        .short_description = "Run radius queries with pagination over GeoEvents.",
        .long_description =
        \\## 1. Insert GeoEvents
        \\
        \\This project inserts a batch of GeoEvents distributed around a center point.
        \\
        \\## 2. Query by radius
        \\
        \\It queries within a radius and demonstrates paging using the cursor returned
        \\by the query response.
        ,
    },
    .{
        .proper_name = "Polygon Query",
        .directory = "polygon-query",
        .short_description = "Run polygon (geofence) queries over GeoEvents.",
        .long_description =
        \\## 1. Insert GeoEvents
        \\
        \\This project inserts GeoEvents in and around a polygonal geofence.
        \\
        \\## 2. Query by polygon
        \\
        \\It queries the polygon and validates that only events inside the
        \\geofence are returned.
        ,
    },
    .{
        .proper_name = "Walkthrough",
        .directory = "walkthrough",
        .short_description = "Track a moving entity with upserts, queries, and deletes.",
        .long_description =
        \\## 1. Insert initial position
        \\
        \\This project inserts an initial GeoEvent for a tracked entity.
        \\
        \\## 2. Update positions
        \\
        \\It then upserts multiple GeoEvents to represent a movement path.
        \\
        \\## 3. Validate latest position
        \\
        \\It queries the latest position by UUID and validates the final stop.
        \\
        \\## 4. Delete entity
        \\
        \\Finally, it deletes the entity and verifies the delete took effect.
        ,
    },
};
