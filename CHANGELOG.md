# Changelog

All notable changes to this project will be documented in this file.

## TigerBeetle (unreleased)

Released: TBD

### Added
- **Fork from TigerBeetle**: Initial fork from TigerBeetle 0.16.x
  (https://github.com/tigerbeetle/tigerbeetle)
- **Zig Ecosystem Validation**: Comprehensive validation tests in
  `src/archerdb/ecosystem_validation.zig` covering:
  - Numeric/math operations (atan2, sqrt, trigonometry)
  - Concurrency primitives (atomics, mutexes)
  - Memory management (allocators, alignment)
  - Standard library stability
  - C FFI integration
- **GeoEvent Struct**: 128-byte cache-aligned extern struct for geospatial
  events with S2 cell ID, entity ID, coordinates, timestamps, and TTL
- **Cross-Platform CI**: GitHub Actions workflow for Linux x64/ARM64, macOS
  x64/ARM64, and Windows x64 with:
  - Smoke tests (shellcheck, tidy checks, quick build)
  - Unit tests across all platforms
  - Reproducible build verification
  - Core status check aggregation
- **Zig Release Monitoring**: Automated weekly checks of TigerBeetle's Zig
  version with auto-issue creation on updates
- **S2 Golden Vector Generator**: Tool for generating deterministic test
  vectors using Go's S2 implementation as reference
- **Project Documentation**: LICENSE.tigerbeetle for attribution, project
  structure documentation

### Changed
- **Binary Rename**: `tigerbeetle` binary renamed to `archerdb`
- **Source Rename**: `src/tigerbeetle/` renamed to `src/archerdb/`
- **Import Updates**: All internal imports updated for new paths
- **Version String**: Changed from "TigerBeetle version" to "ArcherDB version"
- **Tidy Configuration**: Updated tidy.zig for ArcherDB-specific exceptions:
  - Added `.tsv` and `.sh` to allowed extensions
  - Added exceptions for CLAUDE.md markdown format
  - Added exceptions for historical binary blobs
  - Removed TigerBeetle-specific CI file references
- **Test Infrastructure**: Renamed tmp_tigerbeetle.zig to tmp_archerdb.zig

### Verified
- 359/359 unit tests pass
- VOPR simulator passes (49882 ticks)
- Reproducible builds verified (same source = same binary hash)

## 2024-08-05

Initial fork from TigerBeetle.
