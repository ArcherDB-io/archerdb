// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
const Docs = @import("../docs_types.zig").Docs;

pub const NodeDocs = Docs{
    .directory = "node",

    .markdown_name = "javascript",
    .extension = "js",
    .proper_name = "Node.js",

    .test_source_path = "",

    .name = "archerdb-node",
    .description =
    \\The ArcherDB client for Node.js.
    ,
    .prerequisites =
    \\* Node.js >= `18`
    ,

    .project_file = "",
    .project_file_name = "",
    .test_file_name = "main",

    .install_commands = "npm install --save-exact archerdb-node",
    .run_commands = "node main.js",

    .examples =
    \\### Sidenote: `BigInt`
    \\ArcherDB uses 64-bit integers for many fields while JavaScript's
    \\builtin `Number` maximum value is `2^53-1`. The `n` suffix in JavaScript
    \\means the value is a `BigInt`. This is useful for literal numbers. If
    \\you already have a `Number` variable though, you can call the `BigInt`
    \\constructor to get a `BigInt` from it. For example, `1n` is the same as
    \\`BigInt(1)`.
    ,

    .client_object_documentation = "",

    .insert_events_documentation =
    \\Insert geospatial events using `client.insertEvents()`. Each event
    \\contains location data (latitude, longitude), entity ID, and metadata.
    ,

    .geo_event_flags_documentation =
    \\To toggle behavior for a geo event, combine enum values stored in the
    \\`GeoEventFlags` object (in TypeScript it is an actual enum) with
    \\bitwise-or:
    \\
    \\* `GeoEventFlags.has_altitude`
    \\* `GeoEventFlags.tombstone`
    \\
    ,

    .insert_events_errors_documentation =
    \\To handle errors you can either 1) exactly match error codes returned
    \\from `client.insertEvents` with enum values in the
    \\`InsertGeoEventResult` object, or you can 2) look up the error code in
    \\the `InsertGeoEventResult` object for a human-readable string.
    ,

    .query_operations_documentation =
    \\ArcherDB supports several query operations:
    \\
    \\* `queryUuid()` - Query events by entity UUID
    \\* `queryLatest()` - Query latest events for entities
    \\* `queryRadius()` - Query events within a radius of a point
    \\* `queryPolygon()` - Query events within a polygon
    ,

    .delete_entities_documentation =
    \\To delete entities, pass an array of entity IDs to `deleteEntities()`.
    \\This will mark all events for those entities as tombstoned.
    ,
};
