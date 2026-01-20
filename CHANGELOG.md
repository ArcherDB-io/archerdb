# Changelog

Subscribe to the [tracking issue #2231](https://github.com/archerdb/archerdb/issues/2231)
to receive notifications about breaking changes!

## ArcherDB (unreleased)

Released: TBD

### Safety And Performance

- Improved polygon validation with repair suggestions across all SDKs

### Features

- SDK error code alignment and spec compliance tests
- V2 distributed features including geo routing and SDK updates
- Complete TTL operations across all client SDKs (Python, Go, Node, Java, C)
- Online resharding support (v2.1)
- Phase 1 distributed features (multi-region, encryption, CDC)
- Circuit breaker, retry, and observability patterns across SDKs

### Internals

- Removed Rust and .NET client SDKs (focusing on core language support)
- Updated specifications with Implementation Status tables
- Standardized error codes across all SDKs to match Zig core definitions

### TigerTracks 🎧

- [ArcherDB Development Soundtrack](https://example.com)

## ArcherDB 0.0.1

Released: 2024-12-01

### Safety And Performance

- Sub-millisecond writes with 10,000+ location updates per second per replica
- Deterministic execution for consistency guarantees

### Features

- GeoEvent state machine for real-time location tracking
- S2 geometry indexing for efficient spatial queries
- RAM index for O(1) latest position lookups
- VSR consensus protocol for distributed operation
- LSM-tree storage engine with forest compaction
- Client SDKs for Python, Go, Node.js, Java, and C
- VOPR simulation testing framework
- Comprehensive error code system

### Internals

- Based on TigerBeetle's distributed systems foundation
- Extended with specialized geospatial capabilities

### TigerTracks 🎧

- [Initial Release Celebration](https://example.com)

## 2024-08-05 (prehistory)

Initial fork from TigerBeetle and early development.
