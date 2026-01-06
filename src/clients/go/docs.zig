// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
const Docs = @import("../docs_types.zig").Docs;

pub const GoDocs = Docs{
    .directory = "go",

    .markdown_name = "go",
    .extension = "go",
    .proper_name = "Go",

    .test_source_path = "",

    .name = "archerdb-go",
    .description =
    \\The ArcherDB client for Go.
    \\
    \\[![Go Reference](https://pkg.go.dev/badge/github.com/archerdb-io/archerdb-go.svg)](https://pkg.go.dev/github.com/archerdb-io/archerdb-go)
    ,

    .prerequisites =
    \\* Go >= 1.21
    \\
    \\**Additionally on Windows**: you must install [Zig
    \\0.14.1](https://ziglang.org/download/#release-0.14.1) and set the
    \\`CC` environment variable to `zig.exe cc`. Use the full path for
    \\`zig.exe`.
    ,

    .project_file = "",
    .project_file_name = "",

    .test_file_name = "main",

    .install_commands =
    \\go mod init archertest
    \\go get github.com/archerdb-io/archerdb-go
    ,
    .run_commands = "go run main.go",

    .examples = "",

    .client_object_documentation = "",

    .insert_events_documentation =
    \\The `Uint128` fields like `ID`, `EntityID`, `S2CellID` and
    \\`CompositeID` have helper functions to make it easier
    \\to convert 128-bit little-endian unsigned integers between
    \\`string`, `math/big.Int`, and `[]byte`.
    \\
    \\See the type [Uint128](https://pkg.go.dev/github.com/archerdb-io/archerdb-go/pkg/types#Uint128) for more details.
    ,

    .geo_event_flags_documentation =
    \\To toggle behavior for a geo event, use the `types.GeoEventFlags` struct
    \\to combine enum values and generate a `uint32`. Here are a
    \\few examples:
    \\
    \\* `GeoEventFlags{HasAltitude: true}.ToUint32()`
    \\* `GeoEventFlags{Tombstone: true}.ToUint32()`
    ,

    .insert_events_errors_documentation =
    \\To handle errors you can either 1) exactly match error codes returned
    \\from `client.InsertEvents` with enum values in the
    \\`InsertGeoEventResult` object, or you can 2) look up the error code in
    \\the `InsertGeoEventResult` object for a human-readable string.
    ,

    .query_operations_documentation =
    \\ArcherDB supports several query operations:
    \\
    \\* `QueryUuid` - Query events by entity UUID
    \\* `QueryLatest` - Query latest events for entities
    \\* `QueryRadius` - Query events within a radius of a point
    \\* `QueryPolygon` - Query events within a polygon
    ,

    .delete_entities_documentation =
    \\To delete entities, pass a slice of entity IDs to `DeleteEntities`.
    \\This will mark all events for those entities as tombstoned.
    ,
};
