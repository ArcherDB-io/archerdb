// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
const Docs = @import("../docs_types.zig").Docs;

pub const PythonDocs = Docs{
    .directory = "python",

    .markdown_name = "python",
    .extension = "py",
    .proper_name = "Python",

    .test_source_path = "",

    .name = "archerdb-python",
    .description =
    \\The ArcherDB client for Python.
    ,
    .prerequisites =
    \\* Python (or PyPy, etc) >= `3.7`
    ,

    .project_file = "",
    .project_file_name = "",
    .test_file_name = "main",

    .install_commands = "pip install archerdb",
    .run_commands = "python3 main.py",

    .examples = "",

    .client_object_documentation = "",

    .insert_events_documentation =
    \\Insert geospatial events using `client.insert_events()`. Each event
    \\contains location data (latitude, longitude), entity ID, and metadata.
    ,

    .geo_event_flags_documentation =
    \\To toggle behavior for a geo event, combine enum values stored in the
    \\`GeoEventFlags` object (it's an `enum.IntFlag`) with bitwise-or:
    \\
    \\* `GeoEventFlags.has_altitude`
    \\* `GeoEventFlags.tombstone`
    \\
    ,

    .insert_events_errors_documentation =
    \\To handle errors you can compare the result code returned
    \\from `client.insert_events` with enum values in the
    \\`InsertGeoEventResult` object.
    ,

    .query_operations_documentation =
    \\ArcherDB supports several query operations:
    \\
    \\* `query_uuid` - Query events by entity UUID
    \\* `query_latest` - Query latest events for entities
    \\* `query_radius` - Query events within a radius of a point
    \\* `query_polygon` - Query events within a polygon
    ,

    .delete_entities_documentation =
    \\To delete entities, pass a list of entity IDs to `delete_entities`.
    \\This will mark all events for those entities as tombstoned.
    ,
};
