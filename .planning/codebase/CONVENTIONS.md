# Coding Conventions

**Analysis Date:** 2026-01-29

## Naming Patterns

**Files:**
- All `.zig` files use lowercase with underscores: `geo_event.zig`, `state_machine.zig`, `error_codes.zig`
- Test files named descriptively: `state_machine_tests.zig`, `integration_tests.zig`, `fuzz_tests.zig`
- Module structure files: suffixes like `_test.zig` for embedded tests, `_benchmark.zig` for benchmarks
- Subdirectories follow lowercase pattern: `archerdb/`, `vsr/`, `lsm/`, `cdc/`, `clients/c/`

**Functions:**
- Public functions use snake_case: `pack_id()`, `unpack_id()`, `lat_from_float()`, `validate_coordinates()`, `should_copy_forward()`
- Private functions also snake_case: same convention throughout
- Test functions use snake_case within `test "Description"` blocks
- Constructor-like functions: `zero()`, `create_tombstone()`, `create_minimal_tombstone()`
- Getter methods: `is_expired()`, `is_tombstone()`, `contains()`, `empty()`
- Validation methods: `validate()`, `validate_coordinates()`
- Conversion methods: `lat_to_float()`, `lon_to_float()`, `lat_from_float()`, `lon_from_float()`

**Variables:**
- All lowercase with underscores: `current_time_ns`, `is_final_level`, `lat_nano_val`, `lon_nano_val`
- Struct fields use snake_case: `lat_nano`, `lon_nano`, `group_id`, `timestamp`, `ttl_seconds`, `altitude_mm`, `velocity_mms`, `accuracy_mm`, `heading_cdeg`, `entity_id`, `timestamp_ns`
- Loop counters: `i`, `j` for simple iteration; named variables for clarity
- Constants: SCREAMING_SNAKE_CASE: `ENCRYPTED_FILE_MAGIC`, `DEK_SIZE`, `WRAPPED_DEK_SIZE`, `IV_SIZE`, `AUTH_TAG_SIZE`, `AEGIS_NONCE_SIZE`, `AEGIS_TAG_SIZE`
- Configuration options use snake_case: `name`, `verify_push`, `allow_software_crypto`

**Types:**
- Public structs/enums PascalCase: `GeoEvent`, `GeoEventFlags`, `QueueType`, `EncryptedFileHeader`, `ProtocolError`, `ValidationError`, `StateError`
- Generic type names: `comptime T: type`, `anytype` for generic parameters
- Error types: PascalCase enum names: `ProtocolError`, `ValidationError`, `StateError`, `ResourceError`, `SecurityError`, `EncryptionError`

## Code Style

**Formatting:**
- Indent: 4 spaces (defined in `.editorconfig`)
- Line endings: LF (Unix style)
- Charset: UTF-8
- Trailing whitespace: trimmed
- Final newline: always inserted
- SPDX license headers: `// SPDX-License-Identifier: Apache-2.0` followed by copyright

**Linting:**
- Formatting enforced via `zig fmt` (Zig's built-in formatter)
- Test target `test:fmt` runs formatting checks in CI (`--check` mode)
- All code committed must pass `./zig/zig build test:fmt`
- Pre-commit hook validates formatting via `.claude/hooks/pre-commit-check.sh`

**License Headers:**
- Required on all source files: `// SPDX-License-Identifier: Apache-2.0`
- Followed by: `// Copyright (c) 2024-2025 ArcherDB Contributors`
- Verified by: `./scripts/add-license-headers.sh --check`
- Added automatically via: `./scripts/add-license-headers.sh`

## Import Organization

**Order (observed pattern in `vsr.zig`):**
1. Standard library imports: `const std = @import("std");`
2. Builtin imports: `const builtin = @import("builtin");`
3. Local imports from stdx: `const stdx = @import("stdx");`
4. Scoped logging: `const log = std.log.scoped(.module_name);`
5. Named imports from std: `const math = std.math;`, `const assert = std.debug.assert;`
6. Other local module imports via relative paths

**Barrel Files:**
- Root modules like `vsr.zig` explicitly re-export public APIs
- Pattern: `pub const module_name = @import("path/to/module.zig");`
- Example from `vsr.zig`:
  ```zig
  pub const cdc = @import("cdc/runner.zig");
  pub const state_machine = @import("geo_state_machine.zig");
  pub const storage = @import("storage.zig");
  ```
- Allows external consumers to access nested modules via parent: `vsr.state_machine`

**Module Visibility:**
- Private modules imported locally within file: `const queuelink = @import("./queue.zig");`
- Public APIs exported in parent module's barrel file
- Test files pull in via `@import("std").testing`

## Error Handling

**Pattern:**
- Errors are explicit Zig error unions: `!void`, `!T`, `?T`
- Error enums defined as named enums with `pub fn description()` methods
- Example from `error_codes.zig`:
  ```zig
  pub const ProtocolError = enum(u32) {
      invalid_message = 1,
      checksum_mismatch_header = 2,
      // ...
      pub fn description(self: ProtocolError) []const u8 {
          return switch (self) { /* ... */ };
      }
      pub fn isRetriable(self: ProtocolError) bool {
          return switch (self) { /* ... */ };
      }
  };
  ```

**Error Classification:**
- Protocol errors (1-10): Format/checksum issues
- Validation errors (100-120): Invalid input data
- State errors (200-243): System state problems
- Resource errors (300-310): Memory/file/connection limits
- Security errors (400-404): Authorization/authentication
- Encryption errors (410-414): Encryption-specific
- Internal errors (500-504): Unexpected system state

**Error Usage:**
- Functions return error unions: `fn parse_coordinates(lat: f64, lon: f64) !void`
- Try expressions: `try function_that_fails()`
- Catch branches: `catch |err| { handle_error(err); }`
- Defer for cleanup: `defer allocator.free(buffer);`

## Logging

**Framework:** `std.log.scoped()`

**Pattern:**
- Module-level logger: `const log = std.log.scoped(.module_name);`
- Used in `encryption.zig`, `geo_event.zig`, `vsr.zig`
- Log levels: `.debug`, `.info`, `.warn`, `.err`
- Usage: `log.warn("message", .{})` or `log.err("error: {}", .{error_value})`

## Comments

**When to Comment:**
- Module documentation at file top: `//! Module description` (triple-slash doc comments)
- Complex algorithms: Explain "why" not "what"
- Constants with context: Why this specific value?
- Security considerations: Threat model, mitigations
- Specification references: Link to design docs
- Example from `geo_event.zig`:
  ```zig
  //! GeoEvent - The core data structure for ArcherDB geospatial events.
  //!
  //! A 128-byte extern struct with explicit memory layout guarantees matching
  //! ArcherDB's data-oriented design principles.
  ```

**Documentation Comments:**
- Triple-slash `///` for public APIs
- Single-slash `//` for internal comments
- Doc comments precede the item:
  ```zig
  /// Validate coordinate bounds.
  pub fn validate_coordinates(lat_nano_val: i64, lon_nano_val: i64) bool { /* ... */ }
  ```

**Specification References:**
- Reference design docs in comments: "Per ttl-retention/spec.md"
- Reference inline specs from code: "Per add-aesni-encryption/spec.md"
- Example from `encryption.zig`:
  ```zig
  /// Check if the CPU supports AES-NI hardware acceleration.
  ///
  /// Returns true if:
  /// - x86_64 architecture with AES feature
  /// - aarch64 architecture with AES feature (crypto extensions)
  ```

## Function Design

**Size:** Generally focused (50-200 lines typical)
- Complex functions may be longer if they represent atomic operations
- Helper functions extracted for clarity
- Example from `geo_event.zig`: `pack_id()` is 2 lines, `should_copy_forward()` is 20 lines

**Parameters:**
- Self references: `self: *const GeoEvent` for methods
- Mutable access: `self: *GeoEvent`
- Struct options for configuration:
  ```zig
  pub fn init(options: struct {
      name: ?[]const u8,
      verify_push: bool = true,
  }) Queue
  ```

**Return Values:**
- Explicit types always: `void`, `T`, `bool`, `u64`, `?T`, `!T`
- Optional values: `?T` for nullable
- Error unions: `!T` for fallible operations
- Struct returns for multiple values: `.{ .s2_cell_id = u64, .timestamp_ns = u64 }`

## Module Design

**Exports:**
- Public APIs marked with `pub`: `pub fn`, `pub const`, `pub const Link`
- Private items use default visibility
- Logical grouping of related exports

**Const vs Var:**
- Prefer `const` for immutable bindings
- `var` for mutable state or loop variables
- Struct fields with default values: `field: Type = default_value`

## Type Definitions

**Struct Layout:**
- Extern structs for fixed memory layout: `extern struct { /* ... */ }`
- Regular structs for logical grouping
- Explicit field sizing: `lat_nano: i64`, `heading_cdeg: u16`
- Default values in struct initialization: `.{ .name = null, .verify_push = true }`

**Error Enums:**
- Tagged with numeric type: `enum(u32)` for error codes
- Numeric codes follow specification ranges
- Associated methods for metadata: `.description()`, `.isRetriable()`

---

*Convention analysis: 2026-01-29*
