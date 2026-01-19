// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
const Docs = @import("../docs_types.zig").Docs;

pub const RustDocs = Docs{
    .directory = "rust",

    .markdown_name = "rust",
    .extension = "rs",
    .proper_name = "Rust",

    .test_source_path = "src/",

    .name = "archerdb-rust",
    .description =
    \\The ArcherDB client for Rust.
    \\
    \\[![crates.io](https://img.shields.io/crates/v/archerdb)](https://crates.io/crates/archerdb)
    \\[![docs.rs](https://img.shields.io/docsrs/archerdb)](https://docs.rs/archerdb)
    ,

    .prerequisites =
    \\* Rust 1.68+
    ,

    .project_file_name = "Cargo.toml",
    .project_file =
    \\[package]
    \\name = "archerdb-test"
    \\version = "0.1.0"
    \\edition = "2024"
    \\
    \\[dependencies]
    \\archerdb.path = "../.."
    \\futures = "0.3"
    ,

    .test_file_name = "main",

    .install_commands = "",

    .run_commands = "cargo run",

    .examples = "",

    .client_object_documentation = "",

    .insert_events_documentation =
    \\Insert geospatial events using `client.insert_events()`. Each event
    \\contains location data (latitude, longitude), entity ID, and metadata.
    \\
    \\```rust
    \\let event = GeoEvent {
    \\    id: archerdb::id(),
    \\    entity_id: entity_uuid,
    \\    latitude_e7: 407_128_000, // NYC latitude * 1e7
    \\    longitude_e7: -740_060_000, // NYC longitude * 1e7
    \\    ..Default::default()
    \\};
    \\client.insert_events(&[event]).await?;
    \\```
    ,

    .geo_event_flags_documentation =
    \\To toggle behavior for a geo event, use the `GeoEventFlags` bitflags.
    \\You can combine multiple flags using the `|` operator. Here are a
    \\few examples:
    \\
    \\* `GeoEventFlags::HasAltitude`
    \\* `GeoEventFlags::Tombstone`
    \\* `GeoEventFlags::HasAltitude | GeoEventFlags::Tombstone`
    ,

    .insert_events_errors_documentation =
    \\To handle errors, iterate over the `Vec<InsertGeoEventsResult>` returned
    \\from `client.insert_events()`. Each result contains an `index` field
    \\to map back to the input event and a `result` field with the
    \\`InsertGeoEventResult` enum.
    ,

    .query_operations_documentation =
    \\ArcherDB supports several query operations:
    \\
    \\* `get_latest_by_uuid()` - Query latest event by entity UUID
    \\* `get_latest_by_uuid_batch()` - Batch query latest events by UUID
    \\* `query_latest()` - Query latest events across all entities
    \\* `query_radius()` - Query events within a radius of a point
    \\* `query_polygon()` - Query events within a polygon
    \\
    \\```rust
    \\// Query events within 1km of a point
    \\let query = RadiusQuery::new(40.7128, -74.0060, 1000.0, 100)?;
    \\let results = client.query_radius(&query).await?;
    \\```
    ,

    .delete_entities_documentation =
    \\To delete entities, pass a slice of entity IDs to `delete_entities()`.
    \\This will mark all events for those entities as tombstoned.
    ,
};
