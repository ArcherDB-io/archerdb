// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
const Docs = @import("../docs_types.zig").Docs;

pub const DotnetDocs = Docs{
    .directory = "dotnet",

    .markdown_name = "cs",
    .extension = "cs",
    .proper_name = ".NET",

    .test_source_path = "",

    .name = "archerdb-dotnet",
    .description =
    \\The ArcherDB client for .NET.
    ,

    .prerequisites =
    \\* .NET >= 8.0.
    \\
    \\And if you do not already have NuGet.org as a package
    \\source, make sure to add it:
    \\
    \\```console
    \\dotnet nuget add source https://api.nuget.org/v3/index.json -n nuget.org
    \\```
    ,

    .project_file_name = "",
    .project_file = "",

    .test_file_name = "Program",

    .install_commands =
    \\dotnet new console
    \\dotnet add package archerdb
    ,
    .run_commands = "dotnet run",

    .examples = "",

    .client_object_documentation = "",

    .insert_events_documentation =
    \\The `UInt128` fields like `Id`, `EntityId`, `S2CellId` and
    \\`CompositeId` have a few extension methods to make it easier
    \\to convert 128-bit little-endian unsigned integers between
    \\`BigInteger`, `byte[]`, and `Guid`.
    \\
    \\See the class [UInt128Extensions](/src/clients/dotnet/ArcherDB/UInt128Extensions.cs)
    \\for more details.
    ,

    .geo_event_flags_documentation =
    \\To toggle behavior for a geo event, combine enum values stored in the
    \\`GeoEventFlags` object with bitwise-or:
    \\
    \\* `GeoEventFlags.None`
    \\* `GeoEventFlags.HasAltitude`
    \\* `GeoEventFlags.Tombstone`
    ,

    .insert_events_errors_documentation =
    \\To handle errors, check the result returned from `client.InsertEvents()`.
    \\Each result contains an `Index` field to map back to the input event
    \\and a `Result` field with the `InsertGeoEventResult` enum.
    ,

    .query_operations_documentation =
    \\ArcherDB supports several query operations:
    \\
    \\* `QueryUuid()` - Query events by entity UUID
    \\* `QueryLatest()` - Query latest events for entities
    \\* `QueryRadius()` - Query events within a radius of a point
    \\* `QueryPolygon()` - Query events within a polygon
    ,

    .delete_entities_documentation =
    \\To delete entities, pass an array of entity IDs to `DeleteEntities()`.
    \\This will mark all events for those entities as tombstoned.
    ,
};
