# Testing Patterns

**Analysis Date:** 2026-01-29

## Test Framework

**Runner:**
- Zig built-in test runner
- Invoked via `zig build test:unit` and `zig build test:integration`
- Test discovery: automatic from `test "name" { }` blocks in any `.zig` file

**Assertion Library:**
- `std.testing` module from Zig standard library
- Functions: `std.testing.expect()`, `std.testing.expectEqual()`, `std.testing.expectEqualSlices()`, `std.testing.expectError()`, `std.testing.expectErrorString()`
- Allocator: `std.testing.allocator` for test memory management

**Run Commands:**
```bash
./zig/zig build test:unit              # Run all unit tests
./zig/zig build test:integration       # Run integration tests
./zig/zig build test:fmt               # Check code formatting
./zig/zig build test                   # Run all tests (unit + integration + fmt)
./zig/zig build test:unit -- "filter"  # Run filtered unit tests

# Constrained resources (for 24GB RAM server):
./scripts/test-constrained.sh unit                   # -j4, lite config
./scripts/test-constrained.sh --minimal unit         # -j2, lite config
./scripts/test-constrained.sh --full unit            # All resources
./scripts/test-constrained.sh unit --test-filter foo # Filtered tests
```

## Test File Organization

**Location:**
- Embedded tests: Tests live in same `.zig` file as implementation (not separate files)
- Test entry: `test "description" { /* test body */ }`
- Aggregation: Master test files import modules via `comptime _ = @import("module.zig");`
  - `src/unit_tests.zig`: Imports all modules with tests (runs all unit tests)
  - `src/stdx/stdx.zig`: Imports stdx modules (runs stdx tests)
  - `src/integration_tests.zig`: Imports integration-specific modules
  - `src/state_machine_tests.zig`: State machine tests
  - `src/fuzz_tests.zig`: Fuzz testing modules

**Naming:**
- Test description is arbitrary string: `test "Queue: push/pop/peek"`, `test "encrypt and decrypt roundtrip"`
- Test descriptions are descriptive English phrases
- Related tests grouped with common prefix: `test "EncryptedFileHeader size..."`, `test "EncryptedFileHeader validation..."`

**Structure:**
```
src/
├── encryption.zig                     # Main implementation + embedded tests
├── geo_event.zig                      # Implementation + embedded tests
├── queue.zig                          # Implementation + embedded tests
├── unit_tests.zig                     # Aggregates all unit test modules
├── integration_tests.zig              # Aggregates integration test modules
└── state_machine_tests.zig            # State machine specific tests
```

## Test Structure

**Suite Organization:**
```zig
test "Queue: push/pop/peek/remove/empty" {
    const testing = @import("std").testing;

    // Setup
    const Item = struct { link: QueueType(@This()).Link = .{} };
    var one: Item = .{};
    var fifo = QueueType(Item).init(.{
        .name = null,
        .verify_push = true,
    });

    // Test assertions
    try testing.expect(fifo.empty());
    fifo.push(&one);
    try testing.expect(!fifo.empty());
    try testing.expectEqual(@as(?*Item, &one), fifo.peek());
}
```

**Patterns:**
- Setup phase: Create test fixtures and data structures
- Exercise phase: Call functions being tested
- Assert phase: Verify results with `try testing.expect*()`
- Teardown: Use `defer` for cleanup (deallocate memory)

**Allocator Usage:**
```zig
test "encrypt and decrypt roundtrip" {
    const allocator = std.testing.allocator;

    // Allocate buffers
    const encrypted = try encryptData(allocator, plaintext, &dek, &iv, &.{});
    defer allocator.free(encrypted);

    const decrypted = try decryptData(allocator, encrypted, &dek, &iv, &.{});
    defer allocator.free(decrypted);

    // Verify
    try std.testing.expectEqualSlices(u8, plaintext, decrypted);
}
```

## Mocking

**Framework:** Manual mocking via Zig's polymorphism patterns

**Patterns:**
- Vtable structs for polymorphic behavior (seen in encryption module)
- Example: `KeyProvider` vtable allows testing different key sources
  ```zig
  pub const KeyProvider = struct {
      ptr: *anyopaque,
      vtable: *const VTable,

      pub const VTable = struct {
          wrap_dek: *const fn (*anyopaque, *const [DEK_SIZE]u8) EncryptionError![WRAPPED_DEK_SIZE]u8,
          unwrap_dek: *const fn (*anyopaque, *const [WRAPPED_DEK_SIZE]u8) EncryptionError![DEK_SIZE]u8,
      };
  };
  ```
- Test implementations of VTable: `FileKeyProvider`, `AwsKmsKeyProvider`, `VaultKeyProvider`

**What to Mock:**
- External services: KMS, Vault, S3 (via provider patterns)
- File I/O: Use test allocators instead of real files
- Time: Pass current_time_ns explicitly instead of reading system time
- Random: Use seeded PRNG (`stdx.PRNG.from_seed_testing()`)

**What NOT to Mock:**
- Core data structures: Test with real structs
- Algorithms: Test actual implementation path
- Memory management: Use real allocators (test allocator tracks leaks)

## Fixtures and Factories

**Test Data:**
```zig
test "integration: encrypted file roundtrip" {
    const allocator = std.testing.allocator;

    // Factory: Create minimal valid event
    var event = GeoEvent.zero();
    event.lat_nano = GeoEvent.lat_from_float(37.7749); // San Francisco
    event.lon_nano = GeoEvent.lon_from_float(-122.4194);
    event.timestamp = 1000 * ttl.ns_per_second;
    event.group_id = 42;
    event.ttl_seconds = 60;

    // Use factory-created data
    try testGeoEvent(allocator, &event);
}
```

**Location:**
- Fixtures defined inline in test blocks
- Factory functions (like `GeoEvent.zero()`, `GeoEvent.create_tombstone()`) defined in main module
- Shared test utilities: `testing/` subdirectory contains helpers
  - `testing/allocator_tracking.zig`
  - `testing/adaptive_test.zig`
  - `testing/snaptest.zig`
  - `testing/geo_workload.zig`
  - `testing/exhaustigen.zig`

**Snapshot Testing:**
- Module: `src/stdx/testing/snaptest.zig`
- Purpose: Update-able test expectations for complex outputs
- Usage:
  ```zig
  const Snap = @import("snaptest.zig").Snap;
  const snap = Snap.snap_fn("src");

  test "some output" {
      try snap(@src(),
          \\expected output
      ).diff_fmt("{}", .{actual_output});
  }
  ```
- Update snapshots: `SNAP_UPDATE=1 zig build test:unit` or `.update()` method
- Allows rapid test updates after refactoring

## Coverage

**Requirements:** Not explicitly enforced

**View Coverage:**
- No built-in coverage tool shown in codebase
- Test completeness achieved via comprehensive embedded tests
- Each module has `test "name" { }` blocks covering:
  - Happy paths
  - Error conditions
  - Boundary cases
  - Roundtrip operations (serialize/deserialize)

**Test Metrics (from unit_tests.zig):**
- 150+ test modules imported into unit test aggregator
- Covers: LSM trees, encryption, sharding, replication, CDC, compression, validation

## Test Types

**Unit Tests:**
- Scope: Individual module or function
- Location: Embedded in implementation file via `test "name" { }`
- Examples: `encryption.zig` has 20+ unit tests covering key generation, encryption/decryption, header validation
- Run via: `./zig/zig build test:unit`
- Characteristics: Fast (milliseconds), no external dependencies

**Integration Tests:**
- Scope: Multi-module interactions, system-level behavior
- Location: `src/integration_tests.zig` aggregates integration test modules
- Examples: `src/replication/integration_test.zig`, Docker-based replication tests
- Run via: `./zig/zig build test:integration`
- Characteristics: Slower (seconds), may spawn servers/containers

**E2E Tests:**
- Framework: Vortex (system test framework)
- Location: `src/testing/vortex/`
- Purpose: Full system testing with pluggable client drivers
- Run via: `./zig/zig build vortex` or `./zig/zig build vortex:build`

**Fuzz Tests:**
- Location: `src/fuzz_tests.zig` aggregates fuzzer modules
- Examples: `src/state_machine_fuzz.zig`, `src/c_client_tests.zig`
- Framework: Custom PRNG-based property testing and differential fuzzing
- Run via: `./zig/zig build fuzz`

**Benchmark Tests:**
- Location: Embedded as `test "benchmark: name" { }`
- Examples: `ewah_benchmark.zig`, `lsm/binary_search_benchmark.zig`
- Test runner option: `SNAP_UPDATE=1` mode treats benchmarks differently
- Runs via: `./zig/zig build test -- "benchmark"`

## Common Patterns

**Async Testing:**
- Zig is synchronous; no async testing framework needed
- Concurrency tests use thread spawning if needed
- Example: Replication tests spawn multiple server instances

**Error Testing:**
```zig
test "decrypt with wrong key fails" {
    const allocator = std.testing.allocator;

    var encrypted: [32]u8 = undefined;
    crypto.random.bytes(&encrypted);

    var wrong_dek: [DEK_SIZE]u8 = undefined;
    crypto.random.bytes(&wrong_dek);

    const result = decryptData(allocator, &encrypted, &wrong_dek, &some_iv, &.{});
    try std.testing.expectError(error.AuthenticationFailure, result);
}
```

**Property Testing (fuzz pattern):**
```zig
test "Queue: fuzz" {
    const gpa = std.testing.allocator;
    var prng = stdx.PRNG.from_seed_testing();

    for (0..100) |_| {
        // Generate random inputs
        const N = prng.range(u32, 1, 1000);
        var queue = Queue.init(.{ /* ... */ });

        // Apply random operations
        for (0..N) |i| {
            const op = prng.range(u32, 0, 3);
            switch (op) {
                0 => queue.push(&items[i]),
                1 => _ = queue.pop(),
                else => _ = queue.peek(),
            }
        }

        // Verify invariants
        try testing.expectEqual(expected_count, queue.count());
    }
}
```

**Roundtrip Testing (serialize/deserialize):**
```zig
test "EncryptedFileHeader size and serialization" {
    const header = EncryptedFileHeader{};
    const bytes = header.toBytes();
    const restored = EncryptedFileHeader.fromBytes(&bytes);

    try std.testing.expectEqualSlices(u8, &header.magic, &restored.magic);
    try std.testing.expectEqual(header.version, restored.version);
}
```

## Pre-Commit Hooks

**Location:** `.claude/hooks/pre-commit-check.sh`

**Checks run automatically before commit:**
1. Build check: `./zig/zig build -j4 -Dconfig=lite` (catches compilation errors)
2. License headers: `./scripts/add-license-headers.sh --check` (ensures headers present)
3. Quick unit tests: Runs representative test subset (resource-constrained)

**Blocked commits:**
- Build failures: Fix compilation errors
- Missing license headers: Run `./scripts/add-license-headers.sh`
- Test failures: Debug and fix failing tests

## Resource Constraints

**Server limitations:** 24GB RAM, 8 cores, no swap

**Test profiles:**
- Minimal: `-j2 -Dconfig=lite` (~2GB RAM, 2 cores)
- Constrained: `-j4 -Dconfig=lite` (~4GB RAM, 4 cores) - RECOMMENDED for this server
- Full: default Zig settings (~8GB+ RAM, all cores)

**Configuration options:**
- `-Dconfig=lite`: ~130 MiB RAM footprint
- `-Dconfig=production`: 7+ GiB RAM footprint

---

*Testing analysis: 2026-01-29*
