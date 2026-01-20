// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Parse and validate command-line arguments for the archerdb binary.
//!
//! Everything that can be validated without reading the data file must be validated here.
//! Caller must additionally assert validity of arguments as a defense in depth.
//!
//! Some flags are experimental: intentionally undocumented and are not a part of the official
//! surface area. Even experimental features must adhere to the same strict standard of safety,
//! but they come without any performance or usability guarantees.
//!
//! Experimental features are not gated by comptime option for safety: it is much easier to review
//! code for correctness when it is initially added to the main branch, rather when a comptime flag
//! is lifted.

const std = @import("std");
const assert = std.debug.assert;
const fmt = std.fmt;
const net = std.net;

const vsr = @import("vsr");
const stdx = vsr.stdx;
const constants = vsr.constants;
const archerdb = vsr.archerdb;
const sharding = vsr.sharding;
const data_file_size_min = vsr.superblock.data_file_size_min;
const StateMachine = @import("./main.zig").StateMachine;
const Grid = @import("./main.zig").Grid;
const Ratio = stdx.PRNG.Ratio;
const ByteSize = stdx.ByteSize;
const Operation = archerdb.Operation;
const backup_config = vsr.backup_config;

comptime {
    // Make sure we are running the GeoStateMachine.
    assert(StateMachine.Operation == archerdb.Operation);
}

const KiB = stdx.KiB;
const GiB = stdx.GiB;

/// Log level for runtime filtering.
pub const LogLevel = enum {
    err,
    warn,
    info,
    debug,

    pub fn toStdLogLevel(self: LogLevel) std.log.Level {
        return switch (self) {
            .err => .err,
            .warn => .warn,
            .info => .info,
            .debug => .debug,
        };
    }
};

/// Log output format.
pub const LogFormat = enum {
    text,
    json,
};

const CLIArgs = union(enum) {
    const Format = struct {
        cluster: ?u128 = null,
        replica: ?u8 = null,
        // Experimental: standbys don't have a concrete practical use-case yet.
        standby: ?u8 = null,
        replica_count: u8,
        development: bool = false,
        log_level: LogLevel = .info,
        // Per add-jump-consistent-hash/spec.md: sharding strategy for this cluster
        @"sharding-strategy": ?[]const u8 = null,

        @"--": void,
        path: []const u8,
    };

    const Recover = struct {
        cluster: u128,
        addresses: []const u8,
        replica: u8,
        replica_count: u8,
        development: bool = false,
        log_level: LogLevel = .info,
        // Per add-jump-consistent-hash/spec.md: sharding strategy for this cluster
        @"sharding-strategy": ?[]const u8 = null,

        @"--": void,
        path: []const u8,
    };

    const Info = struct {
        log_level: LogLevel = .info,

        @"--": void,
        path: []const u8,
    };

    const Start = struct {
        // Stable CLI arguments.
        addresses: []const u8,
        cache_grid: ?ByteSize = null,
        development: bool = false,
        log_level: LogLevel = .info,
        log_format: LogFormat = .text,
        log_file: ?[]const u8 = null,
        log_rotate_size: ?ByteSize = null,
        log_rotate_count: ?u32 = null,
        metrics_port: ?u16 = null,
        metrics_bind: ?[]const u8 = null,
        metrics_auth_token: ?[]const u8 = null,

        // Backup configuration (F5.5 - Backup & Restore)
        backup_enabled: bool = false,
        backup_provider: ?[]const u8 = null, // s3, gcs, azure, local
        backup_bucket: ?[]const u8 = null,
        backup_region: ?[]const u8 = null,
        backup_credentials: ?[]const u8 = null,
        backup_mode: ?[]const u8 = null, // best-effort, mandatory
        backup_encryption: ?[]const u8 = null, // none, sse, sse-kms
        backup_kms_key_id: ?[]const u8 = null,
        backup_compress: ?[]const u8 = null, // none, zstd
        backup_queue_soft_limit: u32 = 50,
        backup_queue_hard_limit: u32 = 100,
        backup_retention_days: u32 = 0,
        backup_primary_only: bool = false,

        // Per ttl-retention/spec.md: Global default TTL for events
        // default_ttl_days = 0 means infinite (no expiration)
        // default_ttl_days > 0 means events expire after that many days by default
        // When clients set event.ttl_seconds = 0, this default is applied
        default_ttl_days: ?u32 = null,

        // Hybrid-memory/spec.md: Enable memory-mapped RAM index fallback.
        memory_mapped_index_enabled: bool = false,

        // Per add-v2-distributed-features/specs/ttl-retention/spec.md: TTL Extension on Read
        // When enabled, accessing an entity extends its TTL automatically
        ttl_extension_enabled: bool = false,
        // Amount to extend TTL by on access (seconds, default 86400 = 1 day)
        ttl_extension_amount: ?u32 = null,
        // Maximum total TTL after extensions (seconds, default 2592000 = 30 days)
        ttl_extension_max: ?u32 = null,
        // Minimum time between extensions for same entity (seconds, default 3600 = 1 hour)
        ttl_extension_cooldown: ?u32 = null,

        // v2.0 Multi-Region Replication options
        region_role: ?[]const u8 = null, // "primary" or "follower"
        region_id: ?u32 = null, // Unique region identifier
        primary_region: ?[]const u8 = null, // Primary endpoint (follower only)
        follower_regions: ?[]const u8 = null, // Comma-separated follower endpoints (primary only)

        // v2.0 Encryption at Rest options
        encryption_enabled: bool = false,
        encryption_key_provider: ?[]const u8 = null, // "aws-kms", "vault", "file"
        encryption_key_id: ?[]const u8 = null, // KMS ARN, Vault path, or key name
        encryption_key_file: ?[]const u8 = null, // Path to key file (file provider)
        allow_software_crypto: bool = false, // Allow software crypto when AES-NI unavailable

        // Everything from here until positional arguments is considered experimental, and requires
        // `--experimental` to be set. Experimental flags disable automatic upgrades with
        // multiversion binaries; each replica has to be manually restarted. Experimental flags must
        // default to null, except for bools which must be false.
        experimental: bool = false,

        limit_storage: ?ByteSize = null,
        limit_pipeline_requests: ?u32 = null,
        limit_request: ?ByteSize = null,
        cache_geo_events: ?ByteSize = null,
        memory_lsm_manifest: ?ByteSize = null,
        memory_lsm_compaction: ?ByteSize = null,
        trace: ?[]const u8 = null,
        log_trace: bool = false,
        timeout_prepare_ms: ?u64 = null,
        timeout_grid_repair_message_ms: ?u64 = null,
        commit_stall_probability: ?Ratio = null,

        // TTL-aware compaction prioritization threshold (0-100 percent)
        // Per add-ttl-aware-compaction spec: levels with expired_ratio > threshold are prioritized
        // Default: 30 (30% expired data triggers prioritization)
        // Set to 100 to disable TTL prioritization
        ttl_priority_threshold: ?u8 = null,

        // Highly experimental options that will be removed in a future release:
        replicate_star: bool = false,

        statsd: ?[]const u8 = null,

        /// AOF (Append Only File) logs all transactions synchronously to disk before replying
        /// to the client. The logic behind this code has been kept as simple as possible -
        /// io_uring or kqueue aren't used, there aren't any fancy data structures. Just a simple
        /// log consisting of logged requests. Much like a redis AOF with fsync=on.
        /// Enabling this will have performance implications.
        aof_file: ?[]const u8 = null,

        /// Legacy AOF option. Mututally exclusive with aof_file, and will have the same effect as
        /// setting aof_file to '<data file path>.aof'.
        aof: bool = false,

        @"--": void,
        path: []const u8,
    };

    const Version = struct {
        verbose: bool = false,
    };

    const Status = struct {
        address: []const u8 = "127.0.0.1",
        port: u16 = 9100, // Default metrics port
    };

    const Repl = struct {
        addresses: []const u8,
        cluster: u128,
        verbose: bool = false,
        command: []const u8 = "",
        log_level: LogLevel = .info,
    };

    // Experimental: the interface is subject to change.
    // ArcherDB geospatial benchmark configuration
    const Benchmark = struct {
        cache_geo_events: ?[]const u8 = null,
        cache_grid: ?[]const u8 = null,
        log_level: LogLevel = .info,
        log_debug_replica: bool = false,
        flag_imported: bool = false,
        validate: bool = false,
        checksum_performance: bool = false,
        print_batch_timings: bool = false,
        id_order: Command.Benchmark.IdOrder = .sequential,
        clients: u32 = 1,
        statsd: ?[]const u8 = null,
        trace: ?[]const u8 = null,
        /// When set, don't delete the data file when the benchmark completes.
        file: ?[]const u8 = null,
        addresses: ?[]const u8 = null,
        seed: ?[]const u8 = null,
        // GeoEvent benchmarking parameters
        /// Number of GeoEvents to insert (default: 1M for throughput target)
        event_count: u64 = 1_000_000,
        /// Number of unique entities (default: 100K)
        entity_count: u32 = 100_000,
        /// Batch size for insert operations
        event_batch_size: u32 = Operation.insert_events.event_max(
            constants.message_body_size_max,
        ),
        /// Number of UUID lookup queries
        query_uuid_count: u32 = 10_000,
        /// Number of radius queries
        query_radius_count: u32 = 1_000,
        /// Number of polygon queries
        query_polygon_count: u32 = 100,
        /// Radius for geo queries in meters (default: 1km)
        query_radius_meters: u32 = 1_000,
    };

    // Experimental: the interface is subject to change.
    const Inspect = union(enum) {
        constants,
        metrics,
        op: struct {
            @"--": void,
            op: u64,
        },
        superblock: struct {
            @"--": void,
            path: []const u8,
        },
        wal: struct {
            slot: ?usize = null,

            @"--": void,
            path: []const u8,
        },
        replies: struct {
            slot: ?usize = null,
            superblock_copy: ?u8 = null,

            @"--": void,
            path: []const u8,
        },
        grid: struct {
            block: ?u64 = null,
            superblock_copy: ?u8 = null,

            @"--": void,
            path: []const u8,
        },
        manifest: struct {
            superblock_copy: ?u8 = null,

            @"--": void,
            path: []const u8,
        },
        tables: struct {
            superblock_copy: ?u8 = null,
            tree: []const u8,
            level: ?u6 = null,

            @"--": void,
            path: []const u8,
        },
        integrity: struct {
            log_level: LogLevel = .info,
            seed: ?[]const u8 = null,
            memory_lsm_manifest: ?ByteSize = null,
            skip_wal: bool = false,
            skip_client_replies: bool = false,
            skip_grid: bool = false,

            @"--": void,
            path: [:0]const u8,
        },

        pub const help =
            \\Usage:
            \\
            \\  archerdb inspect [-h | --help]
            \\
            \\  archerdb inspect constants
            \\
            \\  archerdb inspect metrics
            \\
            \\  archerdb inspect op <op>
            \\
            \\  archerdb inspect superblock <path>
            \\
            \\  archerdb inspect wal [--slot=<slot>] <path>
            \\
            \\  archerdb inspect replies [--slot=<slot>] <path>
            \\
            \\  archerdb inspect grid [--block=<address>] <path>
            \\
            \\  archerdb inspect manifest <path>
            \\
            \\  archerdb inspect tables --tree=<name|id> [--level=<integer>] <path>
            \\
            \\  archerdb inspect integrity [--log-debug] [--seed=<seed>]
            \\                                [--memory-lsm-manifest=<size>]
            \\                                [--skip-wal] [--skip-client-replies] [--skip-grid]
            \\                                <path>
            \\
            \\Options:
            \\
            \\  When `--superblock-copy` is set, use the trailer referenced by that superblock copy.
            \\  Otherwise, the current quorum will be used by default.
            \\
            \\  -h, --help
            \\        Print this help message and exit.
            \\
            \\  constants
            \\        Print most important compile-time parameters.
            \\
            \\  metrics
            \\        List metrics and their cardinalities.
            \\
            \\  op
            \\        Print op numbers for adjacent checkpoints and triggers.
            \\
            \\  superblock
            \\        Inspect the superblock header copies.
            \\
            \\  wal
            \\        Inspect the WAL headers and prepares.
            \\
            \\  wal --slot=<slot>
            \\        Inspect the WAL header/prepare in the given slot.
            \\
            \\  replies [--superblock-copy=<copy>]
            \\        Inspect the client reply headers and session numbers.
            \\
            \\  replies --slot=<slot> [--superblock-copy=<copy>]
            \\        Inspect a particular client reply.
            \\
            \\  grid [--superblock-copy=<copy>]
            \\        Inspect the free set.
            \\
            \\  grid --block=<address>
            \\        Inspect the block at the given address.
            \\
            \\  manifest [--superblock-copy=<copy>]
            \\        Inspect the LSM manifest.
            \\
            \\  tables --tree=<name|id> [--level=<integer>] [--superblock-copy=<copy>]
            \\        List the tables matching the given tree/level.
            \\        Example tree names: "geo_events" (object table), "geo_events.timestamp" (index table).
            \\
            \\  integrity
            \\        Scans the data file and checks all internal checksums to verify internal
            \\        integrity.
            \\
        ;
    };

    // Internal: used to validate multiversion binaries.
    const Multiversion = struct {
        log_level: LogLevel = .info,

        @"--": void,
        path: []const u8,
    };

    // CDC connector for AMQP targets.
    const AMQP = struct {
        addresses: []const u8,
        cluster: u128,
        host: []const u8,
        user: []const u8,
        password: []const u8,
        vhost: []const u8,
        publish_exchange: ?[]const u8 = null,
        publish_routing_key: ?[]const u8 = null,
        event_count_max: ?u32 = null,
        idle_interval_ms: ?u32 = null,
        requests_per_second_limit: ?u32 = null,
        timestamp_last: ?u64 = null,
        log_level: LogLevel = .info,
    };

    // Data export command (F-Data-Portability).
    const Export = struct {
        /// Export format: json, geojson, ndjson, csv
        format: []const u8 = "json",
        /// Output file path (stdout if not specified)
        output: ?[]const u8 = null,
        /// Entity ID filter (optional)
        entity_id: ?[]const u8 = null,
        /// Start timestamp filter (nanoseconds, optional)
        start_time: ?u64 = null,
        /// End timestamp filter (nanoseconds, optional)
        end_time: ?u64 = null,
        /// Exclude metadata from export (default: include metadata)
        no_metadata: bool = false,
        /// Pretty-print output (json/geojson only)
        pretty: bool = false,
        /// Maximum events to export (0 = unlimited)
        limit: u64 = 0,
        log_level: LogLevel = .info,

        @"--": void,
        /// Path to the data file to export from
        path: []const u8,

        pub const help =
            \\Usage:
            \\
            \\  archerdb export [options] <path>
            \\
            \\Options:
            \\
            \\  --format=<json|geojson|ndjson|csv>
            \\        Export format. Defaults to json.
            \\
            \\  --output=<file>
            \\        Output file path. Writes to stdout if not specified.
            \\
            \\  --entity-id=<uuid>
            \\        Filter by entity ID.
            \\
            \\  --start-time=<ns>
            \\        Filter events after this timestamp (nanoseconds).
            \\
            \\  --end-time=<ns>
            \\        Filter events before this timestamp (nanoseconds).
            \\
            \\  --no-metadata
            \\        Exclude schema version and metadata from output. Metadata included by default.
            \\
            \\  --pretty
            \\        Pretty-print output with indentation (json/geojson only).
            \\
            \\  --limit=<n>
            \\        Maximum events to export. 0 for unlimited.
            \\
            \\Examples:
            \\
            \\  archerdb export 0_0.archerdb > events.json
            \\  archerdb export --format=geojson --output=locations.geojson 0_0.archerdb
            \\  archerdb export --format=csv --entity-id=abc123 0_0.archerdb
            \\  archerdb export --start-time=1704067200000000000 --limit=1000 0_0.archerdb
            \\
        ;
    };

    // Data import command (F-Data-Portability).
    const Import = struct {
        /// Import format: json, geojson, csv (auto-detected from file extension if not specified)
        format: ?[]const u8 = null,
        /// Validate only, don't actually import
        dry_run: bool = false,
        /// Skip records with validation errors
        skip_errors: bool = false,
        /// Batch size for import operations
        batch_size: u32 = 1000,
        /// Hide progress during import (default: show progress)
        no_progress: bool = false,
        /// ArcherDB cluster addresses
        addresses: []const u8,
        /// Cluster ID
        cluster: u128,
        log_level: LogLevel = .info,

        @"--": void,
        /// Path to the file to import
        path: []const u8,

        pub const help =
            \\Usage:
            \\
            \\  archerdb import [options] --addresses=<addresses> --cluster=<id> <path>
            \\
            \\Options:
            \\
            \\  --format=<json|geojson|csv>
            \\        Import format. Auto-detected from file extension if not specified.
            \\
            \\  --addresses=<addresses>
            \\        ArcherDB cluster addresses (required).
            \\
            \\  --cluster=<integer>
            \\        Cluster ID (required).
            \\
            \\  --dry-run
            \\        Validate the file without importing.
            \\
            \\  --skip-errors
            \\        Continue importing even if some records fail validation.
            \\
            \\  --batch-size=<n>
            \\        Number of events per batch. Defaults to 1000.
            \\
            \\  --no-progress
            \\        Hide import progress. Progress is shown by default.
            \\
            \\Examples:
            \\
            \\  archerdb import --addresses=3000 --cluster=0 events.json
            \\  archerdb import --format=geojson --addresses=3000,3001,3002 --cluster=0 locations.geojson
            \\  archerdb import --dry-run --addresses=3000 --cluster=0 data.csv
            \\
        ;
    };

    // v2.0 Shard management commands
    const Shard = union(enum) {
        /// List all shards in the cluster
        list: struct {
            /// ArcherDB cluster addresses
            addresses: []const u8,
            /// Cluster ID
            cluster: u128,
            /// Output format (text, json)
            format: ?[]const u8 = null,
            @"log-level": LogLevel = .info,
        },
        /// Show status of a specific shard
        status: struct {
            /// ArcherDB cluster addresses
            addresses: []const u8,
            /// Cluster ID
            cluster: u128,
            /// Shard ID to query
            shard: u32,
            /// Output format (text, json)
            format: ?[]const u8 = null,
            @"log-level": LogLevel = .info,
        },
        /// Initiate resharding operation
        reshard: struct {
            /// ArcherDB cluster addresses
            addresses: []const u8,
            /// Cluster ID
            cluster: u128,
            /// Target shard count (must be power of 2)
            to: u32,
            /// Resharding mode (offline, online)
            mode: ?[]const u8 = null,
            /// Dry run - show what would happen
            @"dry-run": bool = false,
            @"log-level": LogLevel = .info,
        },

        pub const help =
            \\Usage:
            \\
            \\  archerdb shard [-h | --help]
            \\
            \\  archerdb shard list --addresses=<addresses> --cluster=<id> [--format=<text|json>]
            \\
            \\  archerdb shard status --addresses=<addresses> --cluster=<id> --shard=<id>
            \\                        [--format=<text|json>]
            \\
            \\  archerdb shard reshard --addresses=<addresses> --cluster=<id> --to=<count>
            \\                         [--mode=<offline|online>] [--dry-run]
            \\
            \\Commands:
            \\
            \\  list       List all shards in the cluster with their status.
            \\
            \\  status     Show detailed status for a specific shard.
            \\
            \\  reshard    Initiate resharding to change the number of shards.
            \\             The target count must be a power of 2.
            \\             Default mode is 'offline' (stop-the-world).
            \\
            \\Options:
            \\
            \\  --addresses=<addresses>
            \\        ArcherDB cluster addresses (required).
            \\
            \\  --cluster=<integer>
            \\        Cluster ID (required).
            \\
            \\  --shard=<integer>
            \\        Shard ID for status command.
            \\
            \\  --to=<integer>
            \\        Target shard count for resharding. Must be a power of 2.
            \\
            \\  --mode=<offline|online>
            \\        Resharding mode. 'offline' is stop-the-world (default).
            \\        'online' allows reads during migration (v2.1+).
            \\
            \\  --format=<text|json>
            \\        Output format. Defaults to 'text'.
            \\
            \\  --dry-run
            \\        Show what resharding would do without making changes.
            \\
            \\Examples:
            \\
            \\  archerdb shard list --addresses=3000 --cluster=0
            \\  archerdb shard status --addresses=3000 --cluster=0 --shard=0
            \\  archerdb shard reshard --addresses=3000 --cluster=0 --to=8 --dry-run
            \\
        ;
    };

    // v2.1 TTL management command (per add-v2-distributed-features/specs/ttl-retention/spec.md)
    const TTL = union(enum) {
        /// Set absolute TTL for an entity
        set: struct {
            /// ArcherDB cluster addresses
            addresses: []const u8,
            /// Cluster ID
            cluster: u128,
            /// Entity ID (UUID)
            entity: []const u8,
            /// TTL in seconds
            ttl: u64,
            @"log-level": LogLevel = .info,
        },
        /// Extend TTL for an entity
        extend: struct {
            /// ArcherDB cluster addresses
            addresses: []const u8,
            /// Cluster ID
            cluster: u128,
            /// Entity ID (UUID)
            entity: []const u8,
            /// Extension amount in seconds
            by: u64,
            @"log-level": LogLevel = .info,
        },
        /// Clear TTL for an entity (make it non-expiring)
        clear: struct {
            /// ArcherDB cluster addresses
            addresses: []const u8,
            /// Cluster ID
            cluster: u128,
            /// Entity ID (UUID)
            entity: []const u8,
            @"log-level": LogLevel = .info,
        },

        pub const help =
            \\Usage:
            \\
            \\  archerdb ttl [-h | --help]
            \\
            \\  archerdb ttl set --addresses=<addresses> --cluster=<id> --entity=<uuid> --ttl=<seconds>
            \\
            \\  archerdb ttl extend --addresses=<addresses> --cluster=<id> --entity=<uuid> --by=<seconds>
            \\
            \\  archerdb ttl clear --addresses=<addresses> --cluster=<id> --entity=<uuid>
            \\
            \\Commands:
            \\
            \\  set        Set absolute TTL for an entity.
            \\
            \\  extend     Extend TTL for an entity by a specified amount.
            \\
            \\  clear      Clear TTL for an entity (make it non-expiring).
            \\
            \\Options:
            \\
            \\  --addresses=<addresses>
            \\        ArcherDB cluster addresses (required).
            \\
            \\  --cluster=<integer>
            \\        Cluster ID (required).
            \\
            \\  --entity=<uuid>
            \\        Entity ID in UUID format (required).
            \\
            \\  --ttl=<seconds>
            \\        Absolute TTL in seconds (for 'set' command).
            \\
            \\  --by=<seconds>
            \\        Extension amount in seconds (for 'extend' command).
            \\
            \\Examples:
            \\
            \\  archerdb ttl set --addresses=3000 --cluster=0 \
            \\    --entity=550e8400-e29b-41d4-a716-446655440000 --ttl=86400
            \\  archerdb ttl extend --addresses=3000 --cluster=0 \
            \\    --entity=550e8400-e29b-41d4-a716-446655440000 --by=3600
            \\  archerdb ttl clear --addresses=3000 --cluster=0 \
            \\    --entity=550e8400-e29b-41d4-a716-446655440000
            \\
        ;
    };

    // v2.0 Encryption verification command
    const Verify = struct {
        /// Verify encryption status
        encryption: bool = false,
        @"log-level": LogLevel = .info,

        /// Path to data file
        @"--": void,
        path: []const u8,

        pub const help =
            \\Usage:
            \\
            \\  archerdb verify [--encryption] <path>
            \\
            \\Options:
            \\
            \\  --encryption
            \\        Verify encryption status and integrity of all data files.
            \\        Checks that all files have valid encryption headers,
            \\        DEKs can be unwrapped, and GCM auth tags are valid.
            \\
            \\Examples:
            \\
            \\  archerdb verify --encryption /data/archerdb/0_0.archerdb
            \\
        ;
    };

    // v2.0 Coordinator mode (per add-coordinator-mode/spec.md)
    // v2.0 Cluster management commands (per add-dynamic-membership/spec.md)
    // Provides dynamic membership management: add/remove nodes from running cluster
    const Cluster = union(enum) {
        /// Add a new node to the cluster
        @"add-node": struct {
            /// ArcherDB cluster addresses
            addresses: []const u8,
            /// Cluster ID
            cluster: u128,
            /// Address of the new node to add (host:port)
            node: []const u8,
            /// Don't wait for node to catch up (return immediately)
            @"no-wait": bool = false,
            /// Timeout in seconds for catchup (default 300)
            timeout: u32 = 300,
            /// Output format
            format: ?[]const u8 = null,
            @"log-level": LogLevel = .info,
        },
        /// Remove a node from the cluster
        @"remove-node": struct {
            /// ArcherDB cluster addresses
            addresses: []const u8,
            /// Cluster ID
            cluster: u128,
            /// Node index or address to remove
            node: []const u8,
            /// Force removal even if node is unhealthy
            force: bool = false,
            /// Timeout in seconds for graceful drain (default 60)
            timeout: u32 = 60,
            /// Output format
            format: ?[]const u8 = null,
            @"log-level": LogLevel = .info,
        },
        /// Show cluster membership status
        status: struct {
            /// ArcherDB cluster addresses
            addresses: []const u8,
            /// Cluster ID
            cluster: u128,
            /// Output format (text, json)
            format: ?[]const u8 = null,
            @"log-level": LogLevel = .info,
        },

        pub const help =
            \\Usage:
            \\
            \\  archerdb cluster [-h | --help]
            \\
            \\  archerdb cluster add-node --addresses=<addresses> --cluster=<id> --node=<host:port>
            \\                            [--no-wait] [--timeout=<seconds>] [--format=<text|json>]
            \\
            \\  archerdb cluster remove-node --addresses=<addresses> --cluster=<id> --node=<id|addr>
            \\                               [--force] [--timeout=<seconds>] [--format=<text|json>]
            \\
            \\  archerdb cluster status --addresses=<addresses> --cluster=<id>
            \\                          [--format=<text|json>]
            \\
            \\Commands:
            \\
            \\  add-node     Add a new node to the cluster as a learner, then promote.
            \\               Uses joint consensus for safe membership changes.
            \\
            \\  remove-node  Remove a node from the cluster gracefully.
            \\               Drains in-flight operations before removal.
            \\
            \\  status       Show cluster membership status, node roles, and health.
            \\
            \\Options:
            \\
            \\  --addresses=<addresses>
            \\        ArcherDB cluster addresses (required).
            \\
            \\  --cluster=<integer>
            \\        Cluster ID (required).
            \\
            \\  --node=<host:port|id>
            \\        Node address for add-node, or node ID/address for remove-node.
            \\
            \\  --no-wait
            \\        Return immediately without waiting for node to catch up (add-node only).
            \\
            \\  --timeout=<seconds>
            \\        Timeout for catchup or drain operation. Defaults to 300 for add, 60 for remove.
            \\
            \\  --force
            \\        Force removal even if node is unhealthy (remove-node only).
            \\
            \\  --format=<text|json>
            \\        Output format. Defaults to 'text'.
            \\
            \\Examples:
            \\
            \\  archerdb cluster status --addresses=3000,3001,3002 --cluster=0
            \\  archerdb cluster add-node --addresses=3000,3001,3002 --cluster=0 --node=192.168.1.4:3003
            \\  archerdb cluster remove-node --addresses=3000,3001,3002 --cluster=0 --node=2 --force
            \\
        ;
    };

    // v2.0 Index management commands (per add-online-index-rehash/spec.md)
    // Provides online index resize operations without blocking queries
    const Index = union(enum) {
        /// Resize an index to a new capacity
        resize: struct {
            /// ArcherDB cluster addresses
            addresses: []const u8,
            /// Cluster ID
            cluster: u128,
            /// New capacity (number of buckets)
            @"new-capacity": ?u64 = null,
            /// Output format
            format: ?[]const u8 = null,
            @"log-level": LogLevel = .info,

            @"--": void,
            /// Action: check, status, abort (or none for start)
            action: ?[]const u8 = null,
        },
        /// Show index statistics
        stats: struct {
            /// ArcherDB cluster addresses
            addresses: []const u8,
            /// Cluster ID
            cluster: u128,
            /// Output format (text, json)
            format: ?[]const u8 = null,
            @"log-level": LogLevel = .info,
        },

        pub const help =
            \\Usage:
            \\
            \\  archerdb index [-h | --help]
            \\
            \\  archerdb index resize --addresses=<addresses> --cluster=<id>
            \\                        [--new-capacity=<buckets>] [--format=<text|json>] [check|status|abort]
            \\
            \\  archerdb index stats --addresses=<addresses> --cluster=<id>
            \\                       [--format=<text|json>]
            \\
            \\Commands:
            \\
            \\  resize     Manage online index resize operations.
            \\             Resizing happens in the background without blocking queries.
            \\             Actions: check (dry run), status (show progress), abort (cancel resize).
            \\
            \\  stats      Show index statistics (capacity, usage, health).
            \\
            \\Options:
            \\
            \\  --addresses=<addresses>
            \\        ArcherDB cluster addresses (required).
            \\
            \\  --cluster=<integer>
            \\        Cluster ID (required).
            \\
            \\  --new-capacity=<buckets>
            \\        New index capacity in number of buckets.
            \\        Must be greater than current capacity.
            \\
            \\  --format=<text|json>
            \\        Output format. Defaults to 'text'.
            \\
            \\Actions (for resize):
            \\
            \\  check      Check if resize to --new-capacity is safe.
            \\  status     Show progress of an ongoing resize operation.
            \\  abort      Abort an ongoing resize operation.
            \\
            \\Examples:
            \\
            \\  archerdb index stats --addresses=3000 --cluster=0
            \\  archerdb index resize --addresses=3000 --cluster=0 status
            \\  archerdb index resize --addresses=3000 --cluster=0 --new-capacity=2000000 check
            \\  archerdb index resize --addresses=3000 --cluster=0 --new-capacity=2000000
            \\  archerdb index resize --addresses=3000 --cluster=0 abort
            \\
        ;
    };

    // Provides centralized query routing for complex multi-shard deployments
    const Coordinator = union(enum) {
        /// Start coordinator process
        start: struct {
            /// Bind address for client connections (host:port)
            bind: []const u8 = "0.0.0.0:5000",
            /// Explicit shard list (comma-separated addresses)
            /// Mutually exclusive with --seed-nodes
            shards: ?[]const u8 = null,
            /// Seed nodes for topology discovery (comma-separated addresses)
            /// Mutually exclusive with --shards
            @"seed-nodes": ?[]const u8 = null,
            /// Maximum concurrent client connections
            @"max-connections": u32 = 10000,
            /// Query timeout in milliseconds
            @"query-timeout-ms": u32 = 30_000,
            /// Health check interval in milliseconds
            @"health-check-ms": u32 = 5_000,
            /// Connections per shard
            @"connections-per-shard": u32 = 10,
            /// Disable read-from-replica load balancing (enabled by default)
            @"no-read-from-replicas": bool = false,
            /// Fan-out policy: all, majority, or first
            @"fan-out-policy": ?[]const u8 = null,
            /// Log level
            @"log-level": LogLevel = .info,
            /// Metrics port (optional)
            @"metrics-port": ?u16 = null,
        },
        /// Show coordinator status
        status: struct {
            /// Coordinator address to query
            address: []const u8 = "127.0.0.1:5000",
            /// Output format
            format: ?[]const u8 = null,
        },
        /// Stop coordinator gracefully
        stop: struct {
            /// Coordinator address
            address: []const u8 = "127.0.0.1:5000",
            /// Timeout for graceful shutdown in seconds
            timeout: u32 = 30,
        },

        pub const help =
            \\Usage:
            \\
            \\  archerdb coordinator [-h | --help]
            \\
            \\  archerdb coordinator start [--bind=<host:port>] [--shards=<addresses>]
            \\                             [--seed-nodes=<addresses>] [--max-connections=<n>]
            \\                             [--query-timeout-ms=<ms>] [--health-check-ms=<ms>]
            \\                             [--no-read-from-replicas] [--fan-out-policy=<policy>]
            \\
            \\  archerdb coordinator status [--address=<host:port>] [--format=<text|json>]
            \\
            \\  archerdb coordinator stop [--address=<host:port>] [--timeout=<seconds>]
            \\
            \\Commands:
            \\
            \\  start      Start coordinator process for multi-shard query routing.
            \\             Requires either --shards (explicit list) or --seed-nodes (discovery).
            \\
            \\  status     Show coordinator status including topology and health.
            \\
            \\  stop       Stop coordinator gracefully, draining connections.
            \\
            \\Options:
            \\
            \\  --bind=<host:port>
            \\        Address to bind for client connections. Defaults to 0.0.0.0:5000.
            \\
            \\  --shards=<addresses>
            \\        Comma-separated list of shard addresses (e.g., 10.0.0.1:3000,10.0.0.2:3000).
            \\        Mutually exclusive with --seed-nodes.
            \\
            \\  --seed-nodes=<addresses>
            \\        Comma-separated list of seed nodes for topology discovery.
            \\        Mutually exclusive with --shards.
            \\
            \\  --max-connections=<n>
            \\        Maximum concurrent client connections. Defaults to 10000.
            \\
            \\  --query-timeout-ms=<ms>
            \\        Query timeout in milliseconds. Defaults to 30000.
            \\
            \\  --health-check-ms=<ms>
            \\        Health check interval in milliseconds. Defaults to 5000.
            \\
            \\  --connections-per-shard=<n>
            \\        Number of connections to maintain per shard. Defaults to 10.
            \\
            \\  --no-read-from-replicas
            \\        Disable read load balancing across replicas (enabled by default).
            \\
            \\  --fan-out-policy=<policy>
            \\        Policy for fan-out queries: 'all' (wait for all), 'majority',
            \\        or 'first' (return first response). Defaults to 'all'.
            \\
            \\  --format=<text|json>
            \\        Output format for status command. Defaults to 'text'.
            \\
            \\Examples:
            \\
            \\  archerdb coordinator start --shards=10.0.0.1:3000,10.0.0.2:3000
            \\  archerdb coordinator start --seed-nodes=10.0.0.1:3000 --bind=0.0.0.0:8080
            \\  archerdb coordinator status --format=json
            \\  archerdb coordinator stop --timeout=60
            \\
        ;
    };

    format: Format,
    recover: Recover,
    info: Info,
    start: Start,
    version: Version,
    status: Status,
    repl: Repl,
    benchmark: Benchmark,
    inspect: Inspect,
    multiversion: Multiversion,
    amqp: AMQP,
    @"export": Export,
    import: Import,
    shard: Shard,
    ttl: TTL,
    verify: Verify,
    coordinator: Coordinator,
    cluster: Cluster,
    index: Index,

    // TODO Document --cache-geo-events, --cache-grid, --limit-storage, --limit-pipeline-requests
    pub const help = fmt.comptimePrint(
        \\Usage:
        \\
        \\  archerdb [-h | --help]
        \\
        \\  archerdb format [--cluster=<integer>] --replica=<index> --replica-count=<integer>
        \\                 [--sharding-strategy=<strategy>] <path>
        \\
        \\  archerdb start --addresses=<addresses> [--cache-grid=<size><KiB|MiB|GiB>]
        \\                [--log-level=<level>] [--log-format=<format>] <path>
        \\
        \\  archerdb recover --cluster=<integer> --addresses=<addresses>
        \\                   --replica=<index> --replica-count=<integer>
        \\                   [--sharding-strategy=<strategy>] <path>
        \\
        \\  archerdb info <path>
        \\
        \\  archerdb version [--verbose]
        \\
        \\  archerdb repl --cluster=<integer> --addresses=<addresses>
        \\
        \\Commands:
        \\
        \\  format     Create an ArcherDB replica data file at <path>.
        \\             The --replica and --replica-count arguments are required.
        \\             Each ArcherDB replica must have its own data file.
        \\
        \\  start      Run an ArcherDB replica from the data file at <path>.
        \\
        \\  recover    Create an ArcherDB replica data file at <path> for recovery.
        \\             Used when a replica's data file is completely lost.
        \\             Replicas with recovered data files must sync with the cluster before
        \\             they can participate in consensus.
        \\
        \\  info       Show cluster metadata for the data file at <path>.
        \\
        \\  version    Print the ArcherDB build version and the compile-time config values.
        \\
        \\  repl       Enter the ArcherDB client REPL.
        \\
        \\  amqp       CDC connector for AMQP targets.
        \\
        \\  export     Export data from a replica data file (JSON, GeoJSON, NDJSON, CSV).
        \\
        \\  import     Import data into an ArcherDB cluster (JSON, GeoJSON, CSV).
        \\
        \\  shard      Manage cluster shards (list, status, reshard).
        \\
        \\  verify     Verify data file integrity (encryption, checksums).
        \\
        \\  coordinator  Start/stop/status of coordinator for multi-shard query routing.
        \\
        \\  cluster    Manage cluster membership (add-node, remove-node, status).
        \\
        \\  index      Manage index operations (resize).
        \\
        \\Options:
        \\
        \\  -h, --help
        \\        Print this help message and exit.
        \\
        \\  --cluster=<integer>
        \\        Set the cluster ID to the provided 128-bit unsigned decimal integer.
        \\        Defaults to generating a random cluster ID.
        \\
        \\  --replica=<index>
        \\        Set the zero-based index that will be used for the replica process.
        \\        An index greater than or equal to "replica-count" makes the replica a standby.
        \\        The value of this argument will be interpreted as an index into the --addresses array.
        \\
        \\  --replica-count=<integer>
        \\        Set the number of replicas participating in replication.
        \\
        \\  --sharding-strategy=<modulo|virtual_ring|jump_hash>
        \\        Set the sharding strategy for this cluster.
        \\        - modulo: Simple hash % shards. Requires power-of-2 shard counts.
        \\        - virtual_ring: Consistent hashing with virtual nodes.
        \\        - jump_hash: Jump Consistent Hash (recommended, default).
        \\        Defaults to "jump_hash" for optimal data movement on resharding.
        \\
        \\  --addresses=<addresses>
        \\        The addresses of all replicas in the cluster.
        \\        Accepts a comma-separated list of IPv4/IPv6 addresses with port numbers.
        \\        The order is significant and must match across all replicas and clients.
        \\        Either the address or port number (but not both) may be omitted,
        \\        in which case a default of {[default_address]s} or {[default_port]d} will be used.
        \\        "addresses[i]" corresponds to replica "i".
        \\
        \\  --cache-grid=<size><KiB|MiB|GiB>
        \\        Set the grid cache size. The grid cache acts like a page cache for ArcherDB,
        \\        and should be set as large as possible.
        \\        On a machine running only ArcherDB, this is somewhere around
        \\        (Total RAM) - 3GiB (ArcherDB) - 1GiB (System), eg 12GiB for a 16GiB machine.
        \\        Defaults to {[default_cache_grid_gb]d}GiB.
        \\
        \\  --log-level=<err|warn|info|debug>
        \\        Set the log level for runtime filtering.
        \\        Defaults to "info".
        \\
        \\  --log-format=<text|json>
        \\        Set the log output format.
        \\        Use "text" for human-readable output (development).
        \\        Use "json" for structured logging (production/log aggregation).
        \\        Defaults to "text".
        \\
        \\  --log-file=<path>
        \\        Log to the specified file instead of stderr.
        \\        When not set, logs are written to stderr.
        \\
        \\  --log-rotate-size=<size><KiB|MiB|GiB>
        \\        Rotate log file when it reaches this size.
        \\        Requires --log-file to be set.
        \\        Defaults to 100MiB.
        \\
        \\  --log-rotate-count=<n>
        \\        Keep the last N rotated log files.
        \\        Requires --log-file to be set.
        \\        Defaults to 10.
        \\
        \\  --metrics-port=<port>
        \\        Enable the metrics/health HTTP endpoint on the specified port.
        \\        When set, serves /metrics, /health/live, and /health/ready endpoints.
        \\        Default port when enabled: 9091.
        \\
        \\  --metrics-bind=<address>
        \\        Bind address for the metrics endpoint.
        \\
        \\  --metrics-auth-token=<token>
        \\        Bearer token for authenticating /metrics endpoint requests.
        \\        When set, requests must include "Authorization: Bearer <token>" header.
        \\        Recommended for production deployments with public binding.
        \\        Defaults to "127.0.0.1" for security (localhost only).
        \\        Use "0.0.0.0" to listen on all interfaces (requires explicit opt-in).
        \\
        \\  --verbose
        \\        Print compile-time configuration along with the build version.
        \\
        \\  --development
        \\        Allow the replica to format/start/recover even when Direct IO is unavailable.
        \\        Additionally, use smaller cache sizes and batch size by default.
        \\
        \\        Since this shrinks the batch size, note that:
        \\        * All replicas should use the same batch size. That is, if any replica in the cluster has
        \\          "--development", then all replicas should have "--development".
        \\        * It is always possible to increase the batch size by restarting without "--development".
        \\        * Shrinking the batch size of an existing cluster is possible, but not recommended.
        \\
        \\        For safety, production replicas should always enforce Direct IO -- this flag should only be
        \\        used for testing and development. It should not be used for production or benchmarks.
        \\
        \\  --memory-mapped-index-enabled=<true|false>
        \\        Enable memory-mapped RAM index fallback when RAM is insufficient.
        \\        Defaults to false.
        \\
        \\  --ttl-priority-threshold=<0-100>
        \\        (Experimental) Set the TTL-aware compaction priority threshold as a percentage.
        \\        LSM levels with an expired data ratio exceeding this threshold are prioritized
        \\        for compaction, helping reclaim storage from expired data more quickly.
        \\        Set to 100 to disable TTL-aware prioritization.
        \\        Defaults to 30 (30% expired data triggers prioritization).
        \\
        \\  --ttl-extension-enabled=<true|false>
        \\        Enable automatic TTL extension when entities are accessed (read).
        \\        When enabled, accessing an entity extends its remaining TTL.
        \\        Defaults to false.
        \\
        \\  --ttl-extension-amount=<seconds>
        \\        Amount to extend an entity's TTL on access (in seconds).
        \\        Defaults to 86400 (1 day).
        \\
        \\  --ttl-extension-max=<seconds>
        \\        Maximum total TTL an entity can reach through extensions (in seconds).
        \\        Prevents unbounded TTL growth. Defaults to 2592000 (30 days).
        \\
        \\  --ttl-extension-cooldown=<seconds>
        \\        Minimum time between TTL extensions for the same entity (in seconds).
        \\        Prevents excessive extensions from frequent reads. Defaults to 3600 (1 hour).
        \\
        \\Examples:
        \\
        \\  archerdb format --cluster=0 --replica=0 --replica-count=3 0_0.archerdb
        \\  archerdb format --cluster=0 --replica=1 --replica-count=3 0_1.archerdb
        \\  archerdb format --cluster=0 --replica=2 --replica-count=3 0_2.archerdb
        \\
        \\  archerdb start --addresses=127.0.0.1:3000,127.0.0.1:3001,127.0.0.1:3002 0_0.archerdb
        \\  archerdb start --addresses=3000,3001,3002 0_1.archerdb
        \\  archerdb start --addresses=3000,3001,3002 0_2.archerdb
        \\
        \\  archerdb start --addresses=192.168.0.1,192.168.0.2,192.168.0.3 0_0.archerdb
        \\
        \\  archerdb start --addresses='[::1]:3000,[::1]:3001,[::1]:3002' 0_0.archerdb
        \\
        \\  archerdb recover --cluster=0 --addresses=3003,3001,3002 \
        \\                   --replica=1 --replica-count=3 0_1.archerdb
        \\
        \\  archerdb version --verbose
        \\
        \\  archerdb repl --addresses=3000,3001,3002 --cluster=0
        \\
        \\  archerdb amqp --addresses=3000,3001,3002 --cluster=0 \
        \\      --host=127.0.0.1 --vhost=/ --user=guest --password=guest \
        \\      --publish-exchange=my_exhange_name
        \\
    , .{
        .default_address = constants.address,
        .default_port = constants.port,
        .default_cache_grid_gb = @divExact(
            constants.grid_cache_size_default,
            GiB,
        ),
    });
};

// ArcherDB geospatial defaults (F1.3.1)
const StartDefaults = struct {
    limit_pipeline_requests: u32,
    limit_request: ByteSize,
    cache_geo_events: ByteSize,
    cache_grid: ByteSize,
    memory_lsm_compaction: ByteSize,
};

const start_defaults_production = StartDefaults{
    .limit_pipeline_requests = vsr.stdx.div_ceil(constants.clients_max, 2) -
        constants.pipeline_prepare_queue_max,
    .limit_request = .{ .value = constants.message_size_max },
    .cache_geo_events = .{ .value = constants.cache_geo_events_size_default },
    .cache_grid = .{ .value = constants.grid_cache_size_default },
    .memory_lsm_compaction = .{
        // By default, add a few extra blocks for beat-scoped work.
        .value = (lsm_compaction_block_count_min + 16) * constants.block_size,
    },
};

const start_defaults_development = StartDefaults{
    .limit_pipeline_requests = 0,
    .limit_request = .{ .value = 32 * KiB },
    .cache_geo_events = .{ .value = 0 },
    .cache_grid = .{ .value = constants.block_size * Grid.Cache.value_count_max_multiple },
    .memory_lsm_compaction = .{ .value = lsm_compaction_block_memory_min },
};

const lsm_compaction_block_count_min = StateMachine.Forest.Options.compaction_block_count_min;
const lsm_compaction_block_memory_min = lsm_compaction_block_count_min * constants.block_size;

/// While CLIArgs store raw arguments as passed on the command line, Command ensures that arguments
/// are properly validated and desugared (e.g, sizes converted to counts where appropriate).
pub const Command = union(enum) {
    const Addresses = stdx.BoundedArrayType(std.net.Address, constants.members_max);
    const Path = stdx.BoundedArrayType(u8, std.fs.max_path_bytes);

    pub const Format = struct {
        cluster: u128,
        replica: u8,
        replica_count: u8,
        development: bool,
        path: []const u8,
        log_level: LogLevel,
        // Per add-jump-consistent-hash/spec.md: sharding strategy for this cluster
        sharding_strategy: sharding.ShardingStrategy,
    };

    pub const Recover = struct {
        cluster: u128,
        addresses: Addresses,
        replica: u8,
        replica_count: u8,
        development: bool,
        path: []const u8,
        log_level: LogLevel,
        // Per add-jump-consistent-hash/spec.md: sharding strategy for this cluster
        sharding_strategy: sharding.ShardingStrategy,
    };

    pub const Info = struct {
        path: []const u8,
        log_level: LogLevel,
    };

    // ArcherDB geospatial Start command structure (F1.3.1)
    pub const Start = struct {
        addresses: Addresses,
        // true when the value of `--addresses` is exactly `0`. Used to enable "magic zero" mode for
        // testing. We check the raw string rather then the parsed address to prevent triggering
        // this logic by accident.
        addresses_zero: bool,
        cache_geo_events: u32,
        storage_size_limit: u64,
        pipeline_requests_limit: u32,
        request_size_limit: u32,
        cache_grid_blocks: u32,
        lsm_forest_compaction_block_count: u32,
        lsm_forest_node_count: u32,
        timeout_prepare_ticks: ?u64,
        timeout_grid_repair_message_ticks: ?u64,
        commit_stall_probability: ?Ratio,
        trace: ?[]const u8,
        development: bool,
        experimental: bool,
        replicate_star: bool,
        aof_file: ?Path,
        path: []const u8,
        log_level: LogLevel,
        log_format: LogFormat,
        log_file: ?[]const u8,
        log_rotate_size: u64,
        log_rotate_count: u32,
        log_trace: bool,
        metrics_port: ?u16,
        metrics_bind: []const u8,
        metrics_auth_token: ?[]const u8,
        // Backup configuration (F5.5)
        backup_enabled: bool,
        backup_provider: backup_config.StorageProvider,
        backup_bucket: ?[]const u8,
        backup_region: ?[]const u8,
        backup_credentials: ?[]const u8,
        backup_mode: backup_config.BackupMode,
        backup_encryption: backup_config.EncryptionMode,
        backup_kms_key_id: ?[]const u8,
        backup_compress: backup_config.CompressionMode,
        backup_queue_soft_limit: u32,
        backup_queue_hard_limit: u32,
        backup_retention_days: u32,
        backup_primary_only: bool,
        statsd: ?std.net.Address,
        // Per ttl-retention/spec.md: Global default TTL in days
        // 0 = infinite (no expiration), > 0 = events expire after that many days
        default_ttl_days: u32,
        // Hybrid-memory/spec.md: memory-mapped index fallback flag
        memory_mapped_index_enabled: bool,
        // Per add-ttl-aware-compaction spec: TTL priority threshold (0.0-1.0)
        // Levels with expired_ratio > threshold are prioritized for compaction
        ttl_priority_threshold: f64,
        // Per add-v2-distributed-features/specs/ttl-retention/spec.md: TTL Extension on Read
        ttl_extension_enabled: bool,
        ttl_extension_amount: u32, // seconds, default 86400 (1 day)
        ttl_extension_max: u32, // seconds, default 2592000 (30 days)
        ttl_extension_cooldown: u32, // seconds, default 3600 (1 hour)
        // Per add-aesni-encryption spec: allow software fallback when AES-NI unavailable
        allow_software_crypto: bool,
    };

    pub const Version = struct {
        verbose: bool,
    };

    pub const Status = struct {
        address: []const u8,
        port: u16,
    };

    pub const Repl = struct {
        addresses: Addresses,
        cluster: u128,
        verbose: bool,
        statements: []const u8,
        log_level: LogLevel,
    };

    // ArcherDB geospatial benchmark command structure
    pub const Benchmark = struct {
        /// The ID order can affect the results of a benchmark significantly. Specifically,
        /// sequential is expected to be the best (since it can take advantage of various
        /// optimizations such as avoiding negative prefetch) while random/reversed can't.
        pub const IdOrder = enum { sequential, random, reversed };

        cache_geo_events: ?[]const u8,
        cache_grid: ?[]const u8,
        log_level: LogLevel,
        log_debug_replica: bool,
        flag_imported: bool,
        validate: bool,
        checksum_performance: bool,
        print_batch_timings: bool,
        id_order: IdOrder,
        clients: u32,
        statsd: ?[]const u8,
        trace: ?[]const u8,
        file: ?[]const u8,
        addresses: ?Addresses,
        seed: ?[]const u8,
        // GeoEvent benchmarking parameters
        event_count: u64,
        entity_count: u32,
        event_batch_size: u32,
        query_uuid_count: u32,
        query_radius_count: u32,
        query_polygon_count: u32,
        query_radius_meters: u32,
    };

    pub const Inspect = union(enum) {
        constants,
        metrics,
        op: u64,
        data_file: DataFile,
        integrity: Integrity,

        pub const DataFile = struct {
            path: []const u8,
            query: union(enum) {
                superblock,
                wal: struct {
                    slot: ?usize,
                },
                replies: struct {
                    slot: ?usize,
                    superblock_copy: ?u8,
                },
                grid: struct {
                    block: ?u64,
                    superblock_copy: ?u8,
                },
                manifest: struct {
                    superblock_copy: ?u8,
                },
                tables: struct {
                    superblock_copy: ?u8,
                    tree: []const u8,
                    level: ?u6,
                },
            },
        };

        pub const Integrity = struct {
            log_level: LogLevel,
            seed: ?[]const u8,
            lsm_forest_node_count: u32,
            skip_wal: bool,
            skip_client_replies: bool,
            skip_grid: bool,
            path: [:0]const u8,
        };
    };

    pub const Multiversion = struct {
        path: []const u8,
        log_level: LogLevel,
    };

    pub const AMQP = struct {
        addresses: Addresses,
        cluster: u128,
        host: std.net.Address,
        user: []const u8,
        password: []const u8,
        vhost: []const u8,
        publish_exchange: ?[]const u8,
        publish_routing_key: ?[]const u8,
        event_count_max: ?u32,
        idle_interval_ms: ?u32,
        requests_per_second_limit: ?u32,
        timestamp_last: ?u64,
        log_level: LogLevel,
    };

    /// Export format enumeration.
    pub const ExportFormat = enum {
        json,
        geojson,
        ndjson,
        csv,
    };

    /// Import format enumeration.
    pub const ImportFormat = enum {
        json,
        geojson,
        csv,
    };

    /// Data export command (F-Data-Portability).
    pub const Export = struct {
        format: ExportFormat,
        output: ?[]const u8,
        entity_id: ?[]const u8,
        start_time: ?u64,
        end_time: ?u64,
        include_metadata: bool,
        pretty: bool,
        limit: u64,
        path: []const u8,
        log_level: LogLevel,
    };

    /// Data import command (F-Data-Portability).
    pub const Import = struct {
        addresses: Addresses,
        cluster: u128,
        format: ImportFormat,
        dry_run: bool,
        skip_errors: bool,
        batch_size: u32,
        progress: bool,
        path: []const u8,
        log_level: LogLevel,
    };

    /// Output format for shard commands.
    pub const OutputFormat = enum {
        text,
        json,
    };

    /// Resharding mode.
    pub const ReshardMode = enum {
        offline,
        online,
    };

    /// v2.0 Shard management command.
    pub const Shard = union(enum) {
        list: struct {
            addresses: Addresses,
            cluster: u128,
            format: OutputFormat,
            log_level: LogLevel,
        },
        status: struct {
            addresses: Addresses,
            cluster: u128,
            shard_id: u32,
            format: OutputFormat,
            log_level: LogLevel,
        },
        reshard: struct {
            addresses: Addresses,
            cluster: u128,
            to: u32,
            mode: ReshardMode,
            dry_run: bool,
            log_level: LogLevel,
        },
    };

    /// v2.0 Verification command.
    pub const Verify = struct {
        encryption: bool,
        path: []const u8,
        log_level: LogLevel,
    };

    /// v2.1 TTL management command.
    pub const TTL = union(enum) {
        set: struct {
            addresses: Addresses,
            cluster: u128,
            entity_id: u128,
            ttl_seconds: u64,
            log_level: LogLevel,
        },
        extend: struct {
            addresses: Addresses,
            cluster: u128,
            entity_id: u128,
            extend_seconds: u64,
            log_level: LogLevel,
        },
        clear: struct {
            addresses: Addresses,
            cluster: u128,
            entity_id: u128,
            log_level: LogLevel,
        },
    };

    /// Fan-out policy for multi-shard queries.
    pub const FanOutPolicy = enum {
        /// Wait for all shards to respond.
        all,
        /// Wait for majority of shards.
        majority,
        /// Return first response received.
        first,
    };

    /// v2.0 Coordinator command (per add-coordinator-mode/spec.md).
    pub const Coordinator = union(enum) {
        start: struct {
            bind_host: []const u8,
            bind_port: u16,
            shards: ?Addresses,
            seed_nodes: ?Addresses,
            max_connections: u32,
            query_timeout_ms: u32,
            health_check_ms: u32,
            connections_per_shard: u32,
            read_from_replicas: bool,
            fan_out_policy: FanOutPolicy,
            log_level: LogLevel,
            metrics_port: ?u16,
        },
        status: struct {
            address: []const u8,
            port: u16,
            format: OutputFormat,
        },
        stop: struct {
            address: []const u8,
            port: u16,
            timeout: u32,
        },
    };

    /// v2.0 Cluster management command (per add-dynamic-membership/spec.md).
    pub const Cluster = union(enum) {
        @"add-node": struct {
            addresses: Addresses,
            cluster: u128,
            node_address: []const u8,
            wait: bool,
            timeout_seconds: u32,
            format: OutputFormat,
            log_level: LogLevel,
        },
        @"remove-node": struct {
            addresses: Addresses,
            cluster: u128,
            node_id: []const u8,
            force: bool,
            timeout_seconds: u32,
            format: OutputFormat,
            log_level: LogLevel,
        },
        status: struct {
            addresses: Addresses,
            cluster: u128,
            format: OutputFormat,
            log_level: LogLevel,
        },
    };

    /// v2.0 Index management command (per add-online-index-rehash/spec.md).
    pub const IndexResizeAction = enum {
        start, // Start resize with new-capacity
        check, // Dry run
        status, // Show progress
        abort, // Abort resize
    };

    pub const Index = union(enum) {
        resize: struct {
            addresses: Addresses,
            cluster: u128,
            new_capacity: ?u64,
            action: IndexResizeAction,
            format: OutputFormat,
            log_level: LogLevel,
        },
        stats: struct {
            addresses: Addresses,
            cluster: u128,
            format: OutputFormat,
            log_level: LogLevel,
        },
    };

    format: Format,
    recover: Recover,
    info: Info,
    start: Start,
    version: Version,
    status: Status,
    repl: Repl,
    benchmark: Benchmark,
    inspect: Inspect,
    multiversion: Multiversion,
    amqp: AMQP,
    @"export": Export,
    import: Import,
    shard: Shard,
    ttl: TTL,
    verify: Verify,
    coordinator: Coordinator,
    cluster: Cluster,
    index: Index,
};

/// Parse the command line arguments passed to the `archerdb` binary.
/// Exits the program with a non-zero exit code if an error is found.
pub fn parse_args(args_iterator: *std.process.ArgIterator) Command {
    const cli_args = stdx.flags(args_iterator, CLIArgs);

    return switch (cli_args) {
        .format => |format| .{ .format = parse_args_format(format) },
        .recover => |recover| .{ .recover = parse_args_recover(recover) },
        .info => |info| .{ .info = parse_args_info(info) },
        .start => |start| .{ .start = parse_args_start(start) },
        .version => |version| .{ .version = parse_args_version(version) },
        .status => |status| .{ .status = parse_args_status(status) },
        .repl => |repl| .{ .repl = parse_args_repl(repl) },
        .benchmark => |benchmark| .{ .benchmark = parse_args_benchmark(benchmark) },
        .inspect => |inspect| .{ .inspect = parse_args_inspect(inspect) },
        .multiversion => |multiversion| .{ .multiversion = parse_args_multiversion(multiversion) },
        .amqp => |amqp| .{ .amqp = parse_args_amqp(amqp) },
        .@"export" => |exp| .{ .@"export" = parse_args_export(exp) },
        .import => |imp| .{ .import = parse_args_import(imp) },
        .shard => |shard| .{ .shard = parse_args_shard(shard) },
        .ttl => |ttl| .{ .ttl = parse_args_ttl(ttl) },
        .verify => |verify| .{ .verify = parse_args_verify(verify) },
        .coordinator => |coordinator| .{ .coordinator = parse_args_coordinator(coordinator) },
        .cluster => |cluster| .{ .cluster = parse_args_cluster(cluster) },
        .index => |index| .{ .index = parse_args_index(index) },
    };
}

fn parse_args_format(format: CLIArgs.Format) Command.Format {
    if (format.replica_count == 0) {
        vsr.fatal(.cli, "--replica-count: value needs to be greater than zero", .{});
    }
    if (format.replica_count > constants.replicas_max) {
        vsr.fatal(.cli, "--replica-count: value is too large ({}), at most {} is allowed", .{
            format.replica_count,
            constants.replicas_max,
        });
    }

    if (format.replica == null and format.standby == null) {
        vsr.fatal(.cli, "--replica: argument is required", .{});
    }

    if (format.replica != null and format.standby != null) {
        vsr.fatal(.cli, "--standby: conflicts with '--replica'", .{});
    }

    if (format.replica) |replica| {
        if (replica >= format.replica_count) {
            vsr.fatal(.cli, "--replica: value is too large ({}), at most {} is allowed", .{
                replica,
                format.replica_count - 1,
            });
        }
    }

    if (format.standby) |standby| {
        if (standby < format.replica_count) {
            vsr.fatal(.cli, "--standby: value is too small ({}), at least {} is required", .{
                standby,
                format.replica_count,
            });
        }
        if (standby >= format.replica_count + constants.standbys_max) {
            vsr.fatal(.cli, "--standby: value is too large ({}), at most {} is allowed", .{
                standby,
                format.replica_count + constants.standbys_max - 1,
            });
        }
    }

    const replica = (format.replica orelse format.standby).?;
    assert(replica < constants.members_max);
    assert(replica < format.replica_count + constants.standbys_max);

    const cluster_random = std.crypto.random.int(u128);
    assert(cluster_random != 0);
    const cluster = format.cluster orelse cluster_random;
    if (format.cluster == null) {
        std.log.info("generated random cluster id: {}\n", .{cluster});
    } else if (format.cluster.? == 0) {
        std.log.warn("a cluster id of 0 is reserved for testing and benchmarking, " ++
            "do not use in production", .{});
        std.log.warn("omit --cluster=0 to randomly generate a suitable id\n", .{});
    }

    // Parse sharding strategy (per add-jump-consistent-hash/spec.md)
    const sharding_strategy = if (format.@"sharding-strategy") |strategy_str|
        sharding.ShardingStrategy.fromString(strategy_str) orelse {
            vsr.fatal(.cli, "--sharding-strategy: invalid '{}' (modulo/virtual_ring/jump_hash)", .{
                std.zig.fmtEscapes(strategy_str),
            });
        }
    else
        sharding.ShardingStrategy.default();

    return .{
        .cluster = cluster, // just an ID, any value is allowed
        .replica = replica,
        .replica_count = format.replica_count,
        .development = format.development,
        .path = format.path,
        .log_level = format.log_level,
        .sharding_strategy = sharding_strategy,
    };
}

fn parse_args_recover(recover: CLIArgs.Recover) Command.Recover {
    if (recover.replica_count == 0) {
        vsr.fatal(.cli, "--replica-count: value needs to be greater than zero", .{});
    }
    if (recover.replica_count > constants.replicas_max) {
        vsr.fatal(.cli, "--replica-count: value is too large ({}), at most {} is allowed", .{
            recover.replica_count,
            constants.replicas_max,
        });
    }

    if (recover.replica >= recover.replica_count) {
        vsr.fatal(.cli, "--replica: value is too large ({}), at most {} is allowed", .{
            recover.replica,
            recover.replica_count - 1,
        });
    }
    if (recover.replica_count <= 2) {
        vsr.fatal(.cli, "--replica-count: 1- or 2- replica clusters don't support 'recover'", .{});
    }

    // Parse sharding strategy (per add-jump-consistent-hash/spec.md)
    const sharding_strategy = if (recover.@"sharding-strategy") |strategy_str|
        sharding.ShardingStrategy.fromString(strategy_str) orelse {
            vsr.fatal(.cli, "--sharding-strategy: invalid '{}' (modulo/virtual_ring/jump_hash)", .{
                std.zig.fmtEscapes(strategy_str),
            });
        }
    else
        sharding.ShardingStrategy.default();

    const replica = recover.replica;
    assert(replica < constants.members_max);
    assert(replica < recover.replica_count);

    return .{
        .cluster = recover.cluster,
        .addresses = parse_addresses(recover.addresses, "--addresses", Command.Addresses),
        .replica = replica,
        .replica_count = recover.replica_count,
        .development = recover.development,
        .path = recover.path,
        .log_level = recover.log_level,
        .sharding_strategy = sharding_strategy,
    };
}

fn parse_args_start(start: CLIArgs.Start) Command.Start {
    // Allowlist of stable flags. --development will disable automatic multiversion
    // upgrades too, but the flag itself is stable.
    const stable_args = .{
        "addresses",               "cache_grid",
        "development",             "experimental",
        "log_level",               "log_format",
        "log_file",                "log_rotate_size",
        "log_rotate_count",        "metrics_port",
        "metrics_bind",            "metrics_auth_token",
        "backup_enabled",          "backup_provider",
        "backup_bucket",           "backup_region",
        "backup_credentials",      "backup_mode",
        "backup_encryption",       "backup_kms_key_id",
        "backup_compress",         "backup_queue_soft_limit",
        "backup_queue_hard_limit", "backup_retention_days",
        "backup_primary_only",
    };
    @setEvalBranchQuota(96_000);
    inline for (std.meta.fields(@TypeOf(start))) |field| {
        // Positional arguments can't be experimental.
        comptime if (std.mem.eql(u8, field.name, "--")) break;

        const stable_field = comptime for (stable_args) |stable_arg| {
            assert(std.meta.fieldIndex(@TypeOf(start), stable_arg) != null);
            if (std.mem.eql(u8, field.name, stable_arg)) {
                break true;
            }
        } else false;
        if (stable_field) continue;

        const flag_name = comptime blk: {
            var result: [2 + field.name.len]u8 = ("--" ++ field.name).*;
            std.mem.replaceScalar(u8, &result, '_', '-');
            break :blk result;
        };

        // If you've added a flag and get a comptime error here, it's likely because
        // we require experimental flags to default to null.
        const required_default = if (field.type == bool) false else null;
        assert(field.defaultValue().? == required_default);

        if (@field(start, field.name) != required_default and !start.experimental) {
            vsr.fatal(
                .cli,
                "{s} is marked experimental, add `--experimental` to continue.",
                .{flag_name},
            );
        }
    } else unreachable;

    // ArcherDB geospatial cache configuration (F1.3.1)
    const groove_config = StateMachine.Forest.groove_config;
    const GeoEventsValuesCache = groove_config.geo_events.ObjectsCache.Cache;

    const addresses = parse_addresses(start.addresses, "--addresses", Command.Addresses);
    const defaults =
        if (start.development) start_defaults_development else start_defaults_production;

    const start_limit_storage: ByteSize = start.limit_storage orelse
        .{ .value = constants.storage_size_limit_default };
    const start_memory_lsm_manifest: ByteSize = start.memory_lsm_manifest orelse
        .{ .value = constants.lsm_manifest_memory_size_default };

    const storage_size_limit = start_limit_storage.bytes();
    const storage_size_limit_min = data_file_size_min;
    const storage_size_limit_max = constants.storage_size_limit_max;
    if (storage_size_limit > storage_size_limit_max) {
        vsr.fatal(.cli, "--limit-storage: size {}{s} exceeds maximum: {}", .{
            start_limit_storage.value,
            start_limit_storage.suffix(),
            vsr.stdx.fmt_int_size_bin_exact(storage_size_limit_max),
        });
    }
    if (storage_size_limit < storage_size_limit_min) {
        vsr.fatal(.cli, "--limit-storage: size {}{s} is below minimum: {}", .{
            start_limit_storage.value,
            start_limit_storage.suffix(),
            vsr.stdx.fmt_int_size_bin_exact(storage_size_limit_min),
        });
    }
    if (storage_size_limit % constants.sector_size != 0) {
        vsr.fatal(
            .cli,
            "--limit-storage: size {}{s} must be a multiple of sector size ({})",
            .{
                start_limit_storage.value,
                start_limit_storage.suffix(),
                vsr.stdx.fmt_int_size_bin_exact(constants.sector_size),
            },
        );
    }

    const pipeline_limit =
        start.limit_pipeline_requests orelse defaults.limit_pipeline_requests;
    const pipeline_limit_min = 0;
    const pipeline_limit_max = constants.pipeline_request_queue_max;
    if (pipeline_limit > pipeline_limit_max) {
        vsr.fatal(.cli, "--limit-pipeline-requests: count {} exceeds maximum: {}", .{
            pipeline_limit,
            pipeline_limit_max,
        });
    }
    if (pipeline_limit < pipeline_limit_min) {
        vsr.fatal(.cli, "--limit-pipeline-requests: count {} is below minimum: {}", .{
            pipeline_limit,
            pipeline_limit_min,
        });
    }

    // The minimum is chosen rather arbitrarily as 4096 since it is the sector size.
    const request_size_limit = start.limit_request orelse defaults.limit_request;
    const request_size_limit_min = 4096;
    const request_size_limit_max = constants.message_size_max;
    if (request_size_limit.bytes() > request_size_limit_max) {
        vsr.fatal(.cli, "--limit-request: size {}{s} exceeds maximum: {}", .{
            request_size_limit.value,
            request_size_limit.suffix(),
            vsr.stdx.fmt_int_size_bin_exact(request_size_limit_max),
        });
    }
    if (request_size_limit.bytes() < request_size_limit_min) {
        vsr.fatal(.cli, "--limit-request: size {}{s} is below minimum: {}", .{
            request_size_limit.value,
            request_size_limit.suffix(),
            vsr.stdx.fmt_int_size_bin_exact(request_size_limit_min),
        });
    }

    const lsm_manifest_memory = start_memory_lsm_manifest.bytes();
    const lsm_manifest_memory_max = constants.lsm_manifest_memory_size_max;
    const lsm_manifest_memory_min = constants.lsm_manifest_memory_size_min;
    const lsm_manifest_memory_multiplier = constants.lsm_manifest_memory_size_multiplier;
    if (lsm_manifest_memory > lsm_manifest_memory_max) {
        vsr.fatal(.cli, "--memory-lsm-manifest: size {}{s} exceeds maximum: {}", .{
            start_memory_lsm_manifest.value,
            start_memory_lsm_manifest.suffix(),
            vsr.stdx.fmt_int_size_bin_exact(lsm_manifest_memory_max),
        });
    }
    if (lsm_manifest_memory < lsm_manifest_memory_min) {
        vsr.fatal(.cli, "--memory-lsm-manifest: size {}{s} is below minimum: {}", .{
            start_memory_lsm_manifest.value,
            start_memory_lsm_manifest.suffix(),
            vsr.stdx.fmt_int_size_bin_exact(lsm_manifest_memory_min),
        });
    }
    if (lsm_manifest_memory % lsm_manifest_memory_multiplier != 0) {
        vsr.fatal(
            .cli,
            "--memory-lsm-manifest: size {}{s} must be a multiple of {}",
            .{
                start_memory_lsm_manifest.value,
                start_memory_lsm_manifest.suffix(),
                vsr.stdx.fmt_int_size_bin_exact(lsm_manifest_memory_multiplier),
            },
        );
    }

    const lsm_compaction_block_memory =
        start.memory_lsm_compaction orelse defaults.memory_lsm_compaction;
    const lsm_compaction_block_memory_max = constants.compaction_block_memory_size_max;
    if (lsm_compaction_block_memory.bytes() > lsm_compaction_block_memory_max) {
        vsr.fatal(.cli, "--memory-lsm-compaction: size {}{s} exceeds maximum: {}", .{
            lsm_compaction_block_memory.value,
            lsm_compaction_block_memory.suffix(),
            vsr.stdx.fmt_int_size_bin_exact(lsm_compaction_block_memory_max),
        });
    }
    if (lsm_compaction_block_memory.bytes() < lsm_compaction_block_memory_min) {
        vsr.fatal(.cli, "--memory-lsm-compaction: size {}{s} is below minimum: {}", .{
            lsm_compaction_block_memory.value,
            lsm_compaction_block_memory.suffix(),
            vsr.stdx.fmt_int_size_bin_exact(lsm_compaction_block_memory_min),
        });
    }
    if (lsm_compaction_block_memory.bytes() % constants.block_size != 0) {
        vsr.fatal(
            .cli,
            "--memory-lsm-compaction: size {}{s} must be a multiple of {}",
            .{
                lsm_compaction_block_memory.value,
                lsm_compaction_block_memory.suffix(),
                vsr.stdx.fmt_int_size_bin_exact(constants.block_size),
            },
        );
    }

    const lsm_forest_compaction_block_count: u32 =
        @intCast(@divExact(lsm_compaction_block_memory.bytes(), constants.block_size));
    const lsm_forest_node_count: u32 =
        @intCast(@divExact(lsm_manifest_memory, constants.lsm_manifest_node_size));

    const aof_file: ?Command.Path = if (start.aof) blk: {
        if (start.aof_file != null) {
            vsr.fatal(.cli, "--aof is mutually exclusive with --aof-file", .{});
        }

        var aof_file: Command.Path = .{};
        if (aof_file.capacity() < start.path.len + 4) {
            vsr.fatal(.cli, "data file path is too long for --aof. use --aof-file", .{});
        }
        aof_file.push_slice(start.path);
        aof_file.push_slice(".aof");

        std.log.warn(
            "--aof is deprecated. consider switching to '--aof-file={s}'",
            .{aof_file.const_slice()},
        );

        break :blk aof_file;
    } else if (start.aof_file) |start_aof_file| blk: {
        if (!std.mem.endsWith(u8, start_aof_file, ".aof")) {
            vsr.fatal(.cli, "--aof-file must end with .aof: '{s}'", .{start_aof_file});
        }

        var aof_file: Command.Path = .{};
        if (aof_file.capacity() < start.path.len) {
            vsr.fatal(.cli, "--aof-file path is too long", .{});
        }
        aof_file.push_slice(start_aof_file);

        break :blk aof_file;
    } else null;

    if (start.log_trace and start.log_level != .debug) {
        vsr.fatal(.cli, "--log-level=debug must be provided when using --log-trace", .{});
    }

    return .{
        .addresses = addresses,
        .addresses_zero = std.mem.eql(u8, start.addresses, "0"),
        .storage_size_limit = storage_size_limit,
        .pipeline_requests_limit = pipeline_limit,
        .request_size_limit = @intCast(request_size_limit.bytes()),
        .cache_geo_events = parse_cache_size_to_count(
            archerdb.GeoEvent,
            GeoEventsValuesCache,
            start.cache_geo_events orelse defaults.cache_geo_events,
            "--cache-geo-events",
        ),
        .cache_grid_blocks = parse_cache_size_to_count(
            [constants.block_size]u8,
            Grid.Cache,
            start.cache_grid orelse defaults.cache_grid,
            "--cache-grid",
        ),
        .lsm_forest_compaction_block_count = lsm_forest_compaction_block_count,
        .lsm_forest_node_count = lsm_forest_node_count,
        .timeout_prepare_ticks = parse_timeout_to_ticks(
            start.timeout_prepare_ms,
            "--timeout-prepare-ms",
        ),
        .timeout_grid_repair_message_ticks = parse_timeout_to_ticks(
            start.timeout_grid_repair_message_ms,
            "--timeout-grid-repair-message-ms",
        ),
        .commit_stall_probability = start.commit_stall_probability,
        .development = start.development,
        .experimental = start.experimental,
        .trace = start.trace,
        .replicate_star = start.replicate_star,
        .aof_file = aof_file,
        .path = start.path,
        .log_level = start.log_level,
        .log_format = start.log_format,
        .log_file = start.log_file,
        // Default 100MB
        .log_rotate_size = if (start.log_rotate_size) |s| s.bytes() else 100 * 1024 * 1024,
        .log_rotate_count = start.log_rotate_count orelse 10, // Default 10 files
        .log_trace = start.log_trace,
        .metrics_port = start.metrics_port,
        .metrics_bind = start.metrics_bind orelse "127.0.0.1",
        .metrics_auth_token = start.metrics_auth_token,
        .statsd = if (start.statsd) |statsd_address|
            parse_address_and_port(statsd_address, "--statsd", 8125)
        else
            null,
        // Backup configuration (F5.5 - Backup & Restore)
        .backup_enabled = start.backup_enabled,
        .backup_provider = if (start.backup_provider) |p|
            backup_config.StorageProvider.fromString(p) orelse .s3
        else
            .s3,
        .backup_bucket = start.backup_bucket,
        .backup_region = start.backup_region,
        .backup_credentials = start.backup_credentials,
        .backup_mode = if (start.backup_mode) |m|
            backup_config.BackupMode.fromString(m) orelse .best_effort
        else
            .best_effort,
        .backup_encryption = if (start.backup_encryption) |e|
            backup_config.EncryptionMode.fromString(e) orelse .sse
        else
            .sse,
        .backup_kms_key_id = start.backup_kms_key_id,
        .backup_compress = if (start.backup_compress) |c|
            backup_config.CompressionMode.fromString(c) orelse .none
        else
            .none,
        .backup_queue_soft_limit = start.backup_queue_soft_limit,
        .backup_queue_hard_limit = start.backup_queue_hard_limit,
        .backup_retention_days = start.backup_retention_days,
        .backup_primary_only = start.backup_primary_only,
        // Per ttl-retention/spec.md: Global default TTL (0 = infinite, >0 = days)
        .default_ttl_days = start.default_ttl_days orelse 0,
        .memory_mapped_index_enabled = start.memory_mapped_index_enabled,
        // Per add-ttl-aware-compaction spec: TTL priority threshold (default 30%)
        .ttl_priority_threshold = blk: {
            const pct = start.ttl_priority_threshold orelse 30;
            if (pct > 100) {
                vsr.fatal(.cli, "--ttl-priority-threshold: {d} out of range 0-100", .{pct});
            }
            break :blk @as(f64, @floatFromInt(pct)) / 100.0;
        },
        // Per add-v2-distributed-features/specs/ttl-retention/spec.md: TTL Extension on Read
        .ttl_extension_enabled = start.ttl_extension_enabled,
        .ttl_extension_amount = start.ttl_extension_amount orelse 86400, // default 1 day
        .ttl_extension_max = start.ttl_extension_max orelse 2592000, // default 30 days
        .ttl_extension_cooldown = start.ttl_extension_cooldown orelse 3600, // default 1 hour
        // Per add-aesni-encryption spec: allow software fallback
        .allow_software_crypto = start.allow_software_crypto,
    };
}

fn parse_args_version(version: CLIArgs.Version) Command.Version {
    return .{
        .verbose = version.verbose,
    };
}

fn parse_args_status(status: CLIArgs.Status) Command.Status {
    return .{
        .address = status.address,
        .port = status.port,
    };
}

fn parse_args_info(info: CLIArgs.Info) Command.Info {
    return .{
        .path = info.path,
        .log_level = info.log_level,
    };
}

fn parse_args_repl(repl: CLIArgs.Repl) Command.Repl {
    const addresses = parse_addresses(repl.addresses, "--addresses", Command.Addresses);

    return .{
        .addresses = addresses,
        .cluster = repl.cluster,
        .verbose = repl.verbose,
        .statements = repl.command,
        .log_level = repl.log_level,
    };
}

const event_batch_size_max = @divExact(
    constants.message_size_max - @sizeOf(vsr.Header),
    @sizeOf(archerdb.GeoEvent),
);

fn parse_args_benchmark(benchmark: CLIArgs.Benchmark) Command.Benchmark {
    const addresses = if (benchmark.addresses) |addresses|
        parse_addresses(addresses, "--addresses", Command.Addresses)
    else
        null;

    if (benchmark.addresses != null and benchmark.file != null) {
        vsr.fatal(.cli, "--file: --addresses and --file are mutually exclusive", .{});
    }

    if (benchmark.event_batch_size == 0) {
        vsr.fatal(.cli, "--event-batch-size must be greater than 0", .{});
    }

    if (benchmark.event_batch_size > event_batch_size_max) {
        vsr.fatal(
            .cli,
            "--event-batch-size must be less than or equal to {}",
            .{event_batch_size_max},
        );
    }

    return .{
        .cache_geo_events = benchmark.cache_geo_events,
        .cache_grid = benchmark.cache_grid,
        .log_level = benchmark.log_level,
        .log_debug_replica = benchmark.log_debug_replica,
        .flag_imported = benchmark.flag_imported,
        .validate = benchmark.validate,
        .checksum_performance = benchmark.checksum_performance,
        .print_batch_timings = benchmark.print_batch_timings,
        .clients = benchmark.clients,
        .id_order = benchmark.id_order,
        .statsd = benchmark.statsd,
        .trace = benchmark.trace,
        .file = benchmark.file,
        .addresses = addresses,
        .seed = benchmark.seed,
        // GeoEvent benchmarking parameters
        .event_count = benchmark.event_count,
        .entity_count = benchmark.entity_count,
        .event_batch_size = benchmark.event_batch_size,
        .query_uuid_count = benchmark.query_uuid_count,
        .query_radius_count = benchmark.query_radius_count,
        .query_polygon_count = benchmark.query_polygon_count,
        .query_radius_meters = benchmark.query_radius_meters,
    };
}

fn parse_args_inspect_integrity(args: CLIArgs.Inspect) Command.Inspect.Integrity {
    const integrity = args.integrity;

    const scrub_memory_lsm_manifest: ByteSize = integrity.memory_lsm_manifest orelse
        .{ .value = constants.lsm_manifest_memory_size_default };

    const lsm_manifest_memory = scrub_memory_lsm_manifest.bytes();
    const lsm_manifest_memory_max = constants.lsm_manifest_memory_size_max;
    const lsm_manifest_memory_min = constants.lsm_manifest_memory_size_min;
    const lsm_manifest_memory_multiplier = constants.lsm_manifest_memory_size_multiplier;
    if (lsm_manifest_memory > lsm_manifest_memory_max) {
        vsr.fatal(.cli, "--memory-lsm-manifest: size {}{s} exceeds maximum: {}", .{
            scrub_memory_lsm_manifest.value,
            scrub_memory_lsm_manifest.suffix(),
            vsr.stdx.fmt_int_size_bin_exact(lsm_manifest_memory_max),
        });
    }
    if (lsm_manifest_memory < lsm_manifest_memory_min) {
        vsr.fatal(.cli, "--memory-lsm-manifest: size {}{s} is below minimum: {}", .{
            scrub_memory_lsm_manifest.value,
            scrub_memory_lsm_manifest.suffix(),
            vsr.stdx.fmt_int_size_bin_exact(lsm_manifest_memory_min),
        });
    }
    if (lsm_manifest_memory % lsm_manifest_memory_multiplier != 0) {
        vsr.fatal(
            .cli,
            "--memory-lsm-manifest: size {}{s} must be a multiple of {}",
            .{
                scrub_memory_lsm_manifest.value,
                scrub_memory_lsm_manifest.suffix(),
                vsr.stdx.fmt_int_size_bin_exact(lsm_manifest_memory_multiplier),
            },
        );
    }

    const lsm_forest_node_count: u32 =
        @intCast(@divExact(lsm_manifest_memory, constants.lsm_manifest_node_size));

    return .{
        .path = integrity.path,
        .log_level = integrity.log_level,
        .seed = integrity.seed,
        .skip_wal = integrity.skip_wal,
        .skip_client_replies = integrity.skip_client_replies,
        .skip_grid = integrity.skip_grid,
        .lsm_forest_node_count = lsm_forest_node_count,
    };
}

fn parse_args_inspect(inspect: CLIArgs.Inspect) Command.Inspect {
    const path = switch (inspect) {
        .constants => return .constants,
        .metrics => return .metrics,
        .op => |args| return .{ .op = args.op },
        .integrity => return .{ .integrity = parse_args_inspect_integrity(inspect) },
        inline else => |args| args.path,
    };

    return .{ .data_file = .{
        .path = path,
        .query = switch (inspect) {
            .constants,
            .metrics,
            .op,
            .integrity,
            => unreachable,
            .superblock => .superblock,
            .wal => |args| .{ .wal = .{ .slot = args.slot } },
            .replies => |args| .{ .replies = .{
                .slot = args.slot,
                .superblock_copy = args.superblock_copy,
            } },
            .grid => |args| .{ .grid = .{
                .block = args.block,
                .superblock_copy = args.superblock_copy,
            } },
            .manifest => |args| .{ .manifest = .{
                .superblock_copy = args.superblock_copy,
            } },
            .tables => |args| .{ .tables = .{
                .superblock_copy = args.superblock_copy,
                .tree = args.tree,
                .level = args.level,
            } },
        },
    } };
}

fn parse_args_multiversion(multiversion: CLIArgs.Multiversion) Command.Multiversion {
    return .{
        .path = multiversion.path,
        .log_level = multiversion.log_level,
    };
}

fn parse_args_amqp(amqp: CLIArgs.AMQP) Command.AMQP {
    const addresses = parse_addresses(amqp.addresses, "--addresses", Command.Addresses);
    const host = parse_address_and_port(
        amqp.host,
        "--host",
        vsr.cdc.amqp.tcp_port_default,
    );

    if (amqp.publish_exchange == null and amqp.publish_routing_key == null) {
        vsr.fatal(
            .cli,
            "--publish-exchange and --publish-routing-key cannot both be empty.",
            .{},
        );
    }

    if (amqp.requests_per_second_limit) |requests_per_second_limit| {
        if (requests_per_second_limit == 0) {
            vsr.fatal(
                .cli,
                "--requests-per-second-limit must not be zero.",
                .{},
            );
        }
    }

    return .{
        .addresses = addresses,
        .cluster = amqp.cluster,
        .host = host,
        .user = amqp.user,
        .password = amqp.password,
        .vhost = amqp.vhost,
        .publish_exchange = amqp.publish_exchange,
        .publish_routing_key = amqp.publish_routing_key,
        .event_count_max = amqp.event_count_max,
        .idle_interval_ms = amqp.idle_interval_ms,
        .requests_per_second_limit = amqp.requests_per_second_limit,
        .timestamp_last = amqp.timestamp_last,
        .log_level = amqp.log_level,
    };
}

fn parse_args_export(exp: CLIArgs.Export) Command.Export {
    // Parse format string to enum
    const format = parse_export_format(exp.format);

    // Validate time range if both specified
    if (exp.start_time != null and exp.end_time != null) {
        if (exp.start_time.? > exp.end_time.?) {
            vsr.fatal(.cli, "--start-time must be less than or equal to --end-time", .{});
        }
    }

    return .{
        .format = format,
        .output = exp.output,
        .entity_id = exp.entity_id,
        .start_time = exp.start_time,
        .end_time = exp.end_time,
        .include_metadata = !exp.no_metadata, // Inverted: --no-metadata flag
        .pretty = exp.pretty,
        .limit = exp.limit,
        .path = exp.path,
        .log_level = exp.log_level,
    };
}

fn parse_export_format(format_str: []const u8) Command.ExportFormat {
    if (std.mem.eql(u8, format_str, "json")) return .json;
    if (std.mem.eql(u8, format_str, "geojson")) return .geojson;
    if (std.mem.eql(u8, format_str, "ndjson")) return .ndjson;
    if (std.mem.eql(u8, format_str, "csv")) return .csv;
    vsr.fatal(
        .cli,
        "--format: invalid format '{s}', expected json, geojson, ndjson, or csv",
        .{format_str},
    );
}

fn parse_args_import(imp: CLIArgs.Import) Command.Import {
    const addresses = parse_addresses(imp.addresses, "--addresses", Command.Addresses);

    // Auto-detect format from file extension if not specified
    const format = if (imp.format) |fmt_str|
        parse_import_format(fmt_str)
    else
        detect_import_format(imp.path);

    // Validate batch size
    if (imp.batch_size == 0) {
        vsr.fatal(.cli, "--batch-size must be greater than 0", .{});
    }

    return .{
        .addresses = addresses,
        .cluster = imp.cluster,
        .format = format,
        .dry_run = imp.dry_run,
        .skip_errors = imp.skip_errors,
        .batch_size = imp.batch_size,
        .progress = !imp.no_progress, // Inverted: --no-progress flag
        .path = imp.path,
        .log_level = imp.log_level,
    };
}

fn parse_import_format(format_str: []const u8) Command.ImportFormat {
    if (std.mem.eql(u8, format_str, "json")) return .json;
    if (std.mem.eql(u8, format_str, "geojson")) return .geojson;
    if (std.mem.eql(u8, format_str, "csv")) return .csv;
    vsr.fatal(
        .cli,
        "--format: invalid format '{s}', expected json, geojson, or csv",
        .{format_str},
    );
}

fn detect_import_format(path: []const u8) Command.ImportFormat {
    if (std.mem.endsWith(u8, path, ".json")) return .json;
    if (std.mem.endsWith(u8, path, ".geojson")) return .geojson;
    if (std.mem.endsWith(u8, path, ".csv")) return .csv;
    if (std.mem.endsWith(u8, path, ".ndjson")) return .json; // NDJSON is a subset of JSON
    // Default to JSON if extension not recognized
    return .json;
}

fn parse_args_shard(shard: CLIArgs.Shard) Command.Shard {
    return switch (shard) {
        .list => |list| .{
            .list = .{
                .addresses = parse_addresses(list.addresses, "--addresses", Command.Addresses),
                .cluster = list.cluster,
                .format = parse_output_format(list.format),
                .log_level = list.@"log-level",
            },
        },
        .status => |status| .{
            .status = .{
                .addresses = parse_addresses(status.addresses, "--addresses", Command.Addresses),
                .cluster = status.cluster,
                .shard_id = status.shard,
                .format = parse_output_format(status.format),
                .log_level = status.@"log-level",
            },
        },
        .reshard => |reshard| blk: {
            // Validate that target shard count is a power of 2
            if (reshard.to == 0 or (reshard.to & (reshard.to - 1)) != 0) {
                vsr.fatal(
                    .cli,
                    "--to: shard count must be a power of 2, got {d}",
                    .{reshard.to},
                );
            }
            break :blk .{
                .reshard = .{
                    .addresses = parse_addresses(
                        reshard.addresses,
                        "--addresses",
                        Command.Addresses,
                    ),
                    .cluster = reshard.cluster,
                    .to = reshard.to,
                    .mode = parse_reshard_mode(reshard.mode),
                    .dry_run = reshard.@"dry-run",
                    .log_level = reshard.@"log-level",
                },
            };
        },
    };
}

fn parse_args_ttl(ttl: CLIArgs.TTL) Command.TTL {
    return switch (ttl) {
        .set => |set| .{
            .set = .{
                .addresses = parse_addresses(set.addresses, "--addresses", Command.Addresses),
                .cluster = set.cluster,
                .entity_id = parse_uuid(set.entity, "--entity"),
                .ttl_seconds = set.ttl,
                .log_level = set.@"log-level",
            },
        },
        .extend => |extend| .{
            .extend = .{
                .addresses = parse_addresses(extend.addresses, "--addresses", Command.Addresses),
                .cluster = extend.cluster,
                .entity_id = parse_uuid(extend.entity, "--entity"),
                .extend_seconds = extend.by,
                .log_level = extend.@"log-level",
            },
        },
        .clear => |clear| .{
            .clear = .{
                .addresses = parse_addresses(clear.addresses, "--addresses", Command.Addresses),
                .cluster = clear.cluster,
                .entity_id = parse_uuid(clear.entity, "--entity"),
                .log_level = clear.@"log-level",
            },
        },
    };
}

fn parse_uuid(uuid_str: []const u8, flag_name: []const u8) u128 {
    // Parse UUID format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    // Remove dashes and parse as hex
    var hex_bytes: [32]u8 = undefined;
    var hex_idx: usize = 0;
    for (uuid_str) |c| {
        if (c == '-') continue;
        if (hex_idx >= 32) {
            vsr.fatal(.cli, "{s}: invalid UUID format, too long", .{flag_name});
        }
        hex_bytes[hex_idx] = c;
        hex_idx += 1;
    }
    if (hex_idx != 32) {
        vsr.fatal(.cli, "{s}: invalid UUID (expected 32 hex digits)", .{flag_name});
    }
    return std.fmt.parseInt(u128, &hex_bytes, 16) catch {
        vsr.fatal(.cli, "{s}: invalid UUID hex value", .{flag_name});
    };
}

fn parse_output_format(format_str: ?[]const u8) Command.OutputFormat {
    const format_value = format_str orelse return .text;
    if (std.mem.eql(u8, format_value, "text")) return .text;
    if (std.mem.eql(u8, format_value, "json")) return .json;
    vsr.fatal(.cli, "--format: invalid format '{s}', expected text or json", .{format_value});
}

fn parse_reshard_mode(mode_str: ?[]const u8) Command.ReshardMode {
    const mode = mode_str orelse return .offline;
    if (std.mem.eql(u8, mode, "offline")) return .offline;
    if (std.mem.eql(u8, mode, "online")) return .online;
    vsr.fatal(.cli, "--mode: invalid mode '{s}', expected offline or online", .{mode});
}

fn parse_args_verify(verify: CLIArgs.Verify) Command.Verify {
    return .{
        .encryption = verify.encryption,
        .path = verify.path,
        .log_level = verify.@"log-level",
    };
}

fn parse_args_coordinator(coordinator: CLIArgs.Coordinator) Command.Coordinator {
    return switch (coordinator) {
        .start => |start| blk: {
            // Validate mutual exclusivity of --shards and --seed-nodes
            if (start.shards != null and start.@"seed-nodes" != null) {
                vsr.fatal(.cli, "--shards and --seed-nodes are mutually exclusive", .{});
            }
            if (start.shards == null and start.@"seed-nodes" == null) {
                vsr.fatal(.cli, "either --shards or --seed-nodes is required", .{});
            }

            // Parse bind address (host:port format)
            var bind_host: []const u8 = "0.0.0.0";
            var bind_port: u16 = 5000;
            if (std.mem.indexOfScalar(u8, start.bind, ':')) |colon_pos| {
                bind_host = start.bind[0..colon_pos];
                const port_str = start.bind[colon_pos + 1 ..];
                bind_port = std.fmt.parseInt(u16, port_str, 10) catch {
                    vsr.fatal(.cli, "--bind: invalid port '{s}'", .{port_str});
                };
            } else {
                // If no colon, assume it's just a host and use default port
                bind_host = start.bind;
            }

            break :blk .{
                .start = .{
                    .bind_host = bind_host,
                    .bind_port = bind_port,
                    .shards = if (start.shards) |shards|
                        parse_addresses(shards, "--shards", Command.Addresses)
                    else
                        null,
                    .seed_nodes = if (start.@"seed-nodes") |seeds|
                        parse_addresses(seeds, "--seed-nodes", Command.Addresses)
                    else
                        null,
                    .max_connections = start.@"max-connections",
                    .query_timeout_ms = start.@"query-timeout-ms",
                    .health_check_ms = start.@"health-check-ms",
                    .connections_per_shard = start.@"connections-per-shard",
                    .read_from_replicas = !start.@"no-read-from-replicas",
                    .fan_out_policy = parse_fan_out_policy(start.@"fan-out-policy"),
                    .log_level = start.@"log-level",
                    .metrics_port = start.@"metrics-port",
                },
            };
        },
        .status => |status| blk: {
            // Parse address (host:port format)
            var host: []const u8 = "127.0.0.1";
            var port: u16 = 5000;
            if (std.mem.indexOfScalar(u8, status.address, ':')) |colon_pos| {
                host = status.address[0..colon_pos];
                const port_str = status.address[colon_pos + 1 ..];
                port = std.fmt.parseInt(u16, port_str, 10) catch {
                    vsr.fatal(.cli, "--address: invalid port '{s}'", .{port_str});
                };
            } else {
                host = status.address;
            }

            break :blk .{
                .status = .{
                    .address = host,
                    .port = port,
                    .format = parse_output_format(status.format),
                },
            };
        },
        .stop => |stop| blk: {
            // Parse address (host:port format)
            var host: []const u8 = "127.0.0.1";
            var port: u16 = 5000;
            if (std.mem.indexOfScalar(u8, stop.address, ':')) |colon_pos| {
                host = stop.address[0..colon_pos];
                const port_str = stop.address[colon_pos + 1 ..];
                port = std.fmt.parseInt(u16, port_str, 10) catch {
                    vsr.fatal(.cli, "--address: invalid port '{s}'", .{port_str});
                };
            } else {
                host = stop.address;
            }

            break :blk .{
                .stop = .{
                    .address = host,
                    .port = port,
                    .timeout = stop.timeout,
                },
            };
        },
    };
}

fn parse_fan_out_policy(policy: ?[]const u8) Command.FanOutPolicy {
    const value = policy orelse return .all; // Default to 'all'
    if (std.mem.eql(u8, value, "all")) return .all;
    if (std.mem.eql(u8, value, "majority")) return .majority;
    if (std.mem.eql(u8, value, "first")) return .first;
    vsr.fatal(.cli, "--fan-out-policy: invalid '{s}' (all/majority/first)", .{value});
}

fn parse_args_cluster(cluster: CLIArgs.Cluster) Command.Cluster {
    return switch (cluster) {
        .@"add-node" => |add_node| .{
            .@"add-node" = .{
                .addresses = parse_addresses(add_node.addresses, "--addresses", Command.Addresses),
                .cluster = add_node.cluster,
                .node_address = add_node.node,
                .wait = !add_node.@"no-wait",
                .timeout_seconds = add_node.timeout,
                .format = parse_output_format(add_node.format),
                .log_level = add_node.@"log-level",
            },
        },
        .@"remove-node" => |remove_node| .{
            .@"remove-node" = .{
                .addresses = parse_addresses(
                    remove_node.addresses,
                    "--addresses",
                    Command.Addresses,
                ),
                .cluster = remove_node.cluster,
                .node_id = remove_node.node,
                .force = remove_node.force,
                .timeout_seconds = remove_node.timeout,
                .format = parse_output_format(remove_node.format),
                .log_level = remove_node.@"log-level",
            },
        },
        .status => |status| .{
            .status = .{
                .addresses = parse_addresses(status.addresses, "--addresses", Command.Addresses),
                .cluster = status.cluster,
                .format = parse_output_format(status.format),
                .log_level = status.@"log-level",
            },
        },
    };
}

fn parse_args_index(index: CLIArgs.Index) Command.Index {
    return switch (index) {
        .resize => |resize| blk: {
            // Parse action from positional argument
            const action: Command.IndexResizeAction = if (resize.action) |action_str| act: {
                if (std.mem.eql(u8, action_str, "check")) {
                    if (resize.@"new-capacity" == null) {
                        vsr.fatal(.cli, "index resize check: --new-capacity is required", .{});
                    }
                    break :act .check;
                } else if (std.mem.eql(u8, action_str, "status")) {
                    break :act .status;
                } else if (std.mem.eql(u8, action_str, "abort")) {
                    break :act .abort;
                } else {
                    const msg = "index resize: invalid action '{s}' (check/status/abort)";
                    vsr.fatal(.cli, msg, .{action_str});
                }
            } else act: {
                // No action specified - default to start
                if (resize.@"new-capacity" == null) {
                    const cap_msg = "index resize: --new-capacity required or " ++
                        "specify action (check/status/abort)";
                    vsr.fatal(.cli, cap_msg, .{});
                }
                break :act .start;
            };

            break :blk .{
                .resize = .{
                    .addresses = parse_addresses(
                        resize.addresses,
                        "--addresses",
                        Command.Addresses,
                    ),
                    .cluster = resize.cluster,
                    .new_capacity = resize.@"new-capacity",
                    .action = action,
                    .format = parse_output_format(resize.format),
                    .log_level = resize.@"log-level",
                },
            };
        },
        .stats => |stats| .{
            .stats = .{
                .addresses = parse_addresses(stats.addresses, "--addresses", Command.Addresses),
                .cluster = stats.cluster,
                .format = parse_output_format(stats.format),
                .log_level = stats.@"log-level",
            },
        },
    };
}

/// Parse and allocate the addresses returning a slice into that array.
fn parse_addresses(
    raw_addresses: []const u8,
    comptime flag: []const u8,
    comptime BoundedArray: type,
) BoundedArray {
    comptime assert(std.mem.startsWith(u8, flag, "--"));
    var result: BoundedArray = .{};

    const addresses_parsed = vsr.parse_addresses(
        raw_addresses,
        result.unused_capacity_slice(),
    ) catch |err| switch (err) {
        error.AddressHasTrailingComma => {
            vsr.fatal(.cli, flag ++ ": invalid trailing comma", .{});
        },
        error.AddressLimitExceeded => {
            vsr.fatal(.cli, flag ++ ": too many addresses, at most {d} are allowed", .{
                result.capacity(),
            });
        },
        error.AddressHasMoreThanOneColon => {
            vsr.fatal(.cli, flag ++ ": invalid address with more than one colon", .{});
        },
        error.PortOverflow => vsr.fatal(.cli, flag ++ ": port exceeds 65535", .{}),
        error.PortInvalid => vsr.fatal(.cli, flag ++ ": invalid port", .{}),
        error.AddressInvalid => vsr.fatal(.cli, flag ++ ": invalid IPv4 or IPv6 address", .{}),
    };
    assert(addresses_parsed.len > 0);
    assert(addresses_parsed.len <= result.capacity());
    result.resize(addresses_parsed.len) catch unreachable;
    return result;
}

fn parse_address_and_port(
    raw_address: []const u8,
    comptime flag: []const u8,
    port_default: u16,
) std.net.Address {
    comptime assert(std.mem.startsWith(u8, flag, "--"));

    const address = vsr.parse_address_and_port(.{
        .string = raw_address,
        .port_default = port_default,
    }) catch |err| switch (err) {
        error.AddressHasMoreThanOneColon => {
            vsr.fatal(.cli, flag ++ ": invalid address with more than one colon", .{});
        },
        error.PortOverflow => vsr.fatal(.cli, flag ++ ": port exceeds 65535", .{}),
        error.PortInvalid => vsr.fatal(.cli, flag ++ ": invalid port", .{}),
        error.AddressInvalid => vsr.fatal(.cli, flag ++ ": invalid IPv4 or IPv6 address", .{}),
    };
    return address;
}

/// Given a limit like `10GiB`, a SetAssociativeCache and T return the largest `value_count_max`
/// that can fit in the limit.
fn parse_cache_size_to_count(
    comptime T: type,
    comptime SetAssociativeCache: type,
    size: ByteSize,
    cli_flag: []const u8,
) u32 {
    const value_count_max_multiple = SetAssociativeCache.value_count_max_multiple;

    const count_limit = @divFloor(size.bytes(), @sizeOf(T));
    const count_rounded = @divFloor(
        count_limit,
        value_count_max_multiple,
    ) * value_count_max_multiple;

    if (count_rounded > std.math.maxInt(u32)) {
        vsr.fatal(.cli, "{s}: exceeds the limit", .{cli_flag});
    }

    const result: u32 = @intCast(count_rounded);
    assert(@as(u64, result) * @sizeOf(T) <= size.bytes());

    return result;
}

fn parse_timeout_to_ticks(timeout_ms: ?u64, cli_flag: []const u8) ?u64 {
    if (timeout_ms) |ms| {
        if (ms == 0) {
            vsr.fatal(.cli, "{s}: timeout {}ms be nonzero", .{ cli_flag, ms });
        }

        if (ms % constants.tick_ms != 0) {
            vsr.fatal(
                .cli,
                "{s}: timeout {}ms must be a multiple of {}ms",
                .{ cli_flag, ms, constants.tick_ms },
            );
        }

        return @divExact(ms, constants.tick_ms);
    } else {
        return null;
    }
}

// ============================================================================
// Unit Tests (F-Data-Portability CLI)
// ============================================================================

test "parse_export_format: valid formats" {
    try std.testing.expectEqual(Command.ExportFormat.json, parse_export_format("json"));
    try std.testing.expectEqual(Command.ExportFormat.geojson, parse_export_format("geojson"));
    try std.testing.expectEqual(Command.ExportFormat.ndjson, parse_export_format("ndjson"));
    try std.testing.expectEqual(Command.ExportFormat.csv, parse_export_format("csv"));
}

test "parse_import_format: valid formats" {
    try std.testing.expectEqual(
        Command.ImportFormat.json,
        parse_import_format("json"),
    );
    try std.testing.expectEqual(
        Command.ImportFormat.geojson,
        parse_import_format("geojson"),
    );
    try std.testing.expectEqual(Command.ImportFormat.csv, parse_import_format("csv"));
}

test "detect_import_format: file extension detection" {
    try std.testing.expectEqual(
        Command.ImportFormat.json,
        detect_import_format("data.json"),
    );
    try std.testing.expectEqual(
        Command.ImportFormat.geojson,
        detect_import_format("locations.geojson"),
    );
    try std.testing.expectEqual(
        Command.ImportFormat.csv,
        detect_import_format("events.csv"),
    );
    try std.testing.expectEqual(
        Command.ImportFormat.json,
        detect_import_format("stream.ndjson"),
    );
    // Unknown extension defaults to JSON
    try std.testing.expectEqual(Command.ImportFormat.json, detect_import_format("data.txt"));
    try std.testing.expectEqual(Command.ImportFormat.json, detect_import_format("noextension"));
}

test "parse_args_export: basic parsing" {
    const cli_export = CLIArgs.Export{
        .format = "geojson",
        .output = "/tmp/output.geojson",
        .entity_id = "abc123",
        .start_time = 1000,
        .end_time = 2000,
        .no_metadata = false,
        .pretty = true,
        .limit = 100,
        .log_level = .info,
        .@"--" = {},
        .path = "/data/0_0.archerdb",
    };

    const cmd = parse_args_export(cli_export);

    try std.testing.expectEqual(Command.ExportFormat.geojson, cmd.format);
    try std.testing.expectEqualStrings("/tmp/output.geojson", cmd.output.?);
    try std.testing.expectEqualStrings("abc123", cmd.entity_id.?);
    try std.testing.expectEqual(@as(u64, 1000), cmd.start_time.?);
    try std.testing.expectEqual(@as(u64, 2000), cmd.end_time.?);
    try std.testing.expect(cmd.include_metadata); // no_metadata=false -> include_metadata=true
    try std.testing.expect(cmd.pretty);
    try std.testing.expectEqual(@as(u64, 100), cmd.limit);
}

test "parse_args_export: no_metadata flag inversion" {
    const cli_export = CLIArgs.Export{
        .format = "json",
        .output = null,
        .entity_id = null,
        .start_time = null,
        .end_time = null,
        .no_metadata = true, // User wants no metadata
        .pretty = false,
        .limit = 0,
        .log_level = .info,
        .@"--" = {},
        .path = "test.archerdb",
    };

    const cmd = parse_args_export(cli_export);

    try std.testing.expect(!cmd.include_metadata); // no_metadata=true -> include_metadata=false
}

test "parse_args_format: sharding strategy parsing" {
    const cli_format = CLIArgs.Format{
        .cluster = null,
        .replica = 0,
        .standby = null,
        .replica_count = 3,
        .development = false,
        .log_level = .info,
        .@"sharding-strategy" = "virtual_ring",
        .@"--" = {},
        .path = "/data/0_0.archerdb",
    };

    const cmd = parse_args_format(cli_format);

    try std.testing.expectEqual(sharding.ShardingStrategy.virtual_ring, cmd.sharding_strategy);
}

test "parse_args_format: sharding strategy default" {
    const cli_format = CLIArgs.Format{
        .cluster = null,
        .replica = 1,
        .standby = null,
        .replica_count = 3,
        .development = false,
        .log_level = .info,
        .@"sharding-strategy" = null,
        .@"--" = {},
        .path = "/data/1_0.archerdb",
    };

    const cmd = parse_args_format(cli_format);

    try std.testing.expectEqual(sharding.ShardingStrategy.default(), cmd.sharding_strategy);
}

test "parse_args_recover: sharding strategy parsing" {
    const cli_recover = CLIArgs.Recover{
        .cluster = 1,
        .addresses = "127.0.0.1:3000",
        .replica = 0,
        .replica_count = 3,
        .development = false,
        .log_level = .info,
        .@"sharding-strategy" = "jump_hash",
        .@"--" = {},
        .path = "/data/0_0.archerdb",
    };

    const cmd = parse_args_recover(cli_recover);

    try std.testing.expectEqual(sharding.ShardingStrategy.jump_hash, cmd.sharding_strategy);
}

test "parse_args_info: basic parsing" {
    const cli_info = CLIArgs.Info{
        .log_level = .debug,
        .@"--" = {},
        .path = "/data/0_0.archerdb",
    };

    const cmd = parse_args_info(cli_info);

    try std.testing.expectEqualStrings("/data/0_0.archerdb", cmd.path);
    try std.testing.expectEqual(LogLevel.debug, cmd.log_level);
}

// ============================================================================
// Unit Tests (v2.0 Shard CLI)
// ============================================================================

test "parse_output_format: valid formats" {
    try std.testing.expectEqual(Command.OutputFormat.text, parse_output_format(null));
    try std.testing.expectEqual(Command.OutputFormat.text, parse_output_format("text"));
    try std.testing.expectEqual(Command.OutputFormat.json, parse_output_format("json"));
}

test "parse_reshard_mode: valid modes" {
    try std.testing.expectEqual(Command.ReshardMode.offline, parse_reshard_mode(null));
    try std.testing.expectEqual(Command.ReshardMode.offline, parse_reshard_mode("offline"));
    try std.testing.expectEqual(Command.ReshardMode.online, parse_reshard_mode("online"));
}

test "parse_args_shard: list command" {
    const cli_shard = CLIArgs.Shard{
        .list = .{
            .addresses = "127.0.0.1:3000",
            .cluster = 12345,
            .format = "json",
            .@"log-level" = .info,
        },
    };

    const cmd = parse_args_shard(cli_shard);

    switch (cmd) {
        .list => |list| {
            try std.testing.expectEqual(@as(u128, 12345), list.cluster);
            try std.testing.expectEqual(Command.OutputFormat.json, list.format);
            try std.testing.expectEqual(LogLevel.info, list.log_level);
            try std.testing.expectEqual(@as(usize, 1), list.addresses.len());
        },
        else => unreachable,
    }
}

test "parse_args_shard: status command" {
    const cli_shard = CLIArgs.Shard{
        .status = .{
            .addresses = "127.0.0.1:3000,127.0.0.1:3001",
            .cluster = 67890,
            .shard = 5,
            .format = "text",
            .@"log-level" = .debug,
        },
    };

    const cmd = parse_args_shard(cli_shard);

    switch (cmd) {
        .status => |status| {
            try std.testing.expectEqual(@as(u128, 67890), status.cluster);
            try std.testing.expectEqual(@as(u32, 5), status.shard_id);
            try std.testing.expectEqual(Command.OutputFormat.text, status.format);
            try std.testing.expectEqual(LogLevel.debug, status.log_level);
            try std.testing.expectEqual(@as(usize, 2), status.addresses.len());
        },
        else => unreachable,
    }
}

test "parse_args_shard: reshard command with valid power of 2" {
    const cli_shard = CLIArgs.Shard{
        .reshard = .{
            .addresses = "127.0.0.1:3000",
            .cluster = 11111,
            .to = 8, // Valid power of 2
            .mode = "online",
            .@"dry-run" = true,
            .@"log-level" = .warn,
        },
    };

    const cmd = parse_args_shard(cli_shard);

    switch (cmd) {
        .reshard => |reshard| {
            try std.testing.expectEqual(@as(u128, 11111), reshard.cluster);
            try std.testing.expectEqual(@as(u32, 8), reshard.to);
            try std.testing.expectEqual(Command.ReshardMode.online, reshard.mode);
            try std.testing.expect(reshard.dry_run);
            try std.testing.expectEqual(LogLevel.warn, reshard.log_level);
        },
        else => unreachable,
    }
}

test "parse_args_shard: reshard command defaults" {
    const cli_shard = CLIArgs.Shard{
        .reshard = .{
            .addresses = "127.0.0.1:3000",
            .cluster = 22222,
            .to = 4,
            .mode = null, // Default to offline
            .@"dry-run" = false,
            .@"log-level" = .info,
        },
    };

    const cmd = parse_args_shard(cli_shard);

    switch (cmd) {
        .reshard => |reshard| {
            try std.testing.expectEqual(@as(u32, 4), reshard.to);
            try std.testing.expectEqual(Command.ReshardMode.offline, reshard.mode);
            try std.testing.expect(!reshard.dry_run);
        },
        else => unreachable,
    }
}

test "parse_args_verify: encryption flag" {
    const cli_verify = CLIArgs.Verify{
        .encryption = true,
        .@"log-level" = .info,
        .@"--" = {},
        .path = "/data/archerdb/0_0.archerdb",
    };

    const cmd = parse_args_verify(cli_verify);

    try std.testing.expect(cmd.encryption);
    try std.testing.expectEqualStrings("/data/archerdb/0_0.archerdb", cmd.path);
    try std.testing.expectEqual(LogLevel.info, cmd.log_level);
}

test "parse_args_verify: no encryption flag" {
    const cli_verify = CLIArgs.Verify{
        .encryption = false,
        .@"log-level" = .debug,
        .@"--" = {},
        .path = "test.archerdb",
    };

    const cmd = parse_args_verify(cli_verify);

    try std.testing.expect(!cmd.encryption);
    try std.testing.expectEqualStrings("test.archerdb", cmd.path);
}
