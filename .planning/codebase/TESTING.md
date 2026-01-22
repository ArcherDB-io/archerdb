# Testing Patterns

**Analysis Date:** 2026-01-22

## Test Framework

**Runner:**
- Zig 0.14.1 built-in test runner
- Config: `build.zig` (lines 88-96)

**Assertion Library:**
- `std.testing` from Zig stdlib
- Primary assertions: `try std.testing.expectEqual()`, `try std.testing.expect()`

**Run Commands:**
```bash
./zig/zig build test:unit              # Run all unit tests
./zig/zig build test:integration       # Run integration tests
./zig/zig build test:unit -- --test-filter "pattern"  # Filter tests
./zig/zig build test:fmt               # Check code formatting
./zig/zig build test:jni               # Run Java JNI tests
```

## Test File Organization

**Location:**
- Co-located with source (not in separate directory)
- Tests embedded in same `.zig` files as implementation
- Example: `src/encryption.zig` contains both code and tests (lines 1824-2300+)

**Naming:**
- Test blocks: `test "descriptive name" { ... }`
- No `.test.zig` suffix (tests live in regular source files)
- Special files:
  - `src/unit_tests.zig`: Auto-generated test aggregator
  - `src/integration_tests.zig`: Integration test suite
  - `src/c_client_tests.zig`: C client FFI tests

**Structure:**
```
src/
├── encryption.zig           # Contains both implementation and tests
├── unit_tests.zig           # Auto-aggregates all unit tests (quine pattern)
├── integration_tests.zig    # Integration test suite
└── vsr/
    └── replica_test.zig     # Dedicated test files for complex modules
```

## Test Structure

**Suite Organization:**
```zig
test "EncryptedFileHeader size and serialization" {
    const header = EncryptedFileHeader{};
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(EncryptedFileHeader));
    // More assertions...
}

test "encrypt and decrypt roundtrip" {
    const allocator = std.testing.allocator;
    // Setup
    var dek: [DEK_SIZE]u8 = undefined;
    try generateDek(&dek);
    // Execute
    const plaintext = "test data";
    const ciphertext = try encrypt(allocator, &dek, plaintext);
    defer allocator.free(ciphertext);
    // Verify
    const decrypted = try decrypt(allocator, &dek, ciphertext);
    defer allocator.free(decrypted);
    try std.testing.expectEqualStrings(plaintext, decrypted);
}
```

**Patterns:**
- Setup phase: Initialize test data
- Defer cleanup: `defer allocator.free(data);` immediately after allocation
- Assertions: `try std.testing.expectEqual()`, `try std.testing.expectEqualStrings()`
- Error testing: Verify functions return expected errors

## Mocking

**Framework:** Manual mocking (no framework)

**Patterns:**
- Echo client: `init_echo()` in `src/clients/node/src/index.ts` (line 99)
- Test doubles: Implement alternative versions for testing
- Dependency injection: Pass allocators and contexts as parameters

**What to Mock:**
- External services: Network calls, filesystem operations
- C FFI bindings: Echo client for client SDK tests
- Hardware dependencies: Software crypto fallback for AES-NI tests

**What NOT to Mock:**
- Core algorithms: Test actual implementations
- Data structures: Test real behavior
- Pure functions: No side effects to mock

## Fixtures and Factories

**Test Data:**
```zig
// From src/encryption.zig test suite
test "generateDek produces unique keys" {
    var dek1: [DEK_SIZE]u8 = undefined;
    var dek2: [DEK_SIZE]u8 = undefined;
    try generateDek(&dek1);
    try generateDek(&dek2);
    try std.testing.expect(!std.mem.eql(u8, &dek1, &dek2));
}

// From src/sharding.zig test suite
test "computeShardKey deterministic" {
    const entity_id = [16]u8{ 0x12, 0x34, 0x56, 0x78, ... };
    const key1 = computeShardKey(&entity_id);
    const key2 = computeShardKey(&entity_id);
    try std.testing.expectEqual(key1, key2);
}
```

**Location:**
- Inline in test blocks (no separate fixture files)
- Test data for wire format: `src/clients/test-data/wire-format-test-cases.json`
- Helper functions defined in test modules when needed

## Coverage

**Requirements:** Not enforced (no coverage target set)

**View Coverage:**
- Not configured (Zig test runner doesn't generate coverage reports by default)
- Manual verification via test execution

## Test Types

**Unit Tests:**
- Scope: Single function or module behavior
- Location: Co-located with source code
- Run: `./zig/zig build test:unit`
- Example: `src/encryption.zig` lines 1824-2300+ (20+ unit tests)
- Pattern: Pure function testing, algorithm validation, error path testing

**Integration Tests:**
- Scope: Multi-module interactions, subprocess execution
- Location: `src/integration_tests.zig`
- Run: `./zig/zig build test:integration`
- Approach: Spawn `./archerdb` binary as subprocess, test via C client
- Example from `src/integration_tests.zig` lines 50-72:
  ```zig
  fn fetchMetrics(allocator: std.mem.Allocator, port: u16) ![]u8 {
      var stream = try std.net.tcpConnectToHost(allocator, "127.0.0.1", port);
      defer stream.close();
      try stream.writer().writeAll("GET /metrics HTTP/1.1\r\n...");
      return try stream.reader().readAllAlloc(allocator, 1024 * 1024);
  }
  ```

**Fuzz Tests:**
- Location: Files ending in `_fuzz.zig` (`src/ewah_fuzz.zig`, `src/message_bus_fuzz.zig`, `src/state_machine_fuzz.zig`)
- Run: `./zig/zig build fuzz`
- Purpose: Randomized testing, crash detection

**VOPR (Verification of Parallel Replicas):**
- Location: `src/vopr.zig`
- Run: `./zig/zig build vopr`
- Purpose: Distributed system testing, fault injection, state machine verification

**Vortex:**
- Location: `src/vortex.zig`, `src/testing/vortex/`
- Run: `./zig/zig build vortex`
- Purpose: Full system tests with pluggable client drivers

## Common Patterns

**Async Testing:**
- No async/await in Zig (blocking I/O model)
- Integration tests use synchronous TCP connections
- Timeouts via retry loops:
  ```zig
  var attempts: u8 = 0;
  while (attempts < 10) : (attempts += 1) {
      var stream = std.net.tcpConnectToHost(...) catch |err| {
          if (attempts + 1 >= 10) return err;
          std.time.sleep(50 * std.time.ns_per_ms);
          continue;
      };
      // ...
  }
  ```

**Error Testing:**
```zig
test "decrypt with wrong key fails" {
    const allocator = std.testing.allocator;

    var correct_dek: [DEK_SIZE]u8 = undefined;
    var wrong_dek: [DEK_SIZE]u8 = undefined;
    try generateDek(&correct_dek);
    try generateDek(&wrong_dek);

    const plaintext = "secret message";
    const ciphertext = try encrypt(allocator, &correct_dek, plaintext);
    defer allocator.free(ciphertext);

    const result = decrypt(allocator, &wrong_dek, ciphertext);
    try std.testing.expectError(error.AuthenticationFailed, result);
}
```

**Allocation Testing:**
- Use `std.testing.allocator` (detects leaks)
- Pattern:
  ```zig
  test "no memory leaks" {
      const allocator = std.testing.allocator;
      const data = try allocator.alloc(u8, 1024);
      defer allocator.free(data);
      // Test code...
  }
  // std.testing.allocator automatically fails if leaks detected
  ```

**Comptime Testing:**
- Compile-time assertions:
  ```zig
  comptime {
      assert(@sizeOf(EncryptedFileHeader) == 96);
  }
  ```

**Snapshot Testing:**
- Framework: `stdx.Snap` from `src/stdx/testing/snaptest.zig`
- Usage: `src/tidy.zig` line 17: `const snap = Snap.snap_fn(module_path);`
- Update snapshots: `SNAP_UPDATE=1 ./zig/zig build test:unit`

## Pre-Commit Testing

**Hook:** `.claude/hooks/pre-commit-check.sh`

**Quick Checks (runs before commit):**
1. Build check: `./zig/zig build`
2. License headers: `./scripts/add-license-headers.sh --check`
3. Quick unit tests: `./zig/zig build test:unit -- --test-filter "EncryptedFileHeader"`

**Timeout:** 120 seconds for pre-commit tests

**Full Suite:**
- Runs in GitHub CI (not locally by default)
- Local full suite: `./zig/zig build test:unit` (no filter)

## Test Discovery

**Mechanism:**
- Auto-discovery via `src/unit_tests.zig` (quine pattern)
- Walks `src/` directory, finds files with `test "` declarations
- Comptime import of all test-containing modules
- Regeneration: `SNAP_UPDATE=1 ./zig/zig build test:unit`

**Exclusions (from `src/unit_tests.zig` lines 358-374):**
- `src/stdx/` (separate module)
- `src/clients/` (except `clients/c`)
- Entry points: `main.zig`, `cli.zig`, `metrics_server.zig`
- Benchmark drivers
- Integration test file itself

## Client SDK Testing

**Node.js:**
- TypeScript compilation: `npm run test` (compiles with `tsc`)
- Test runner: `node dist/test.js`
- Type checking: `npm run test:types`

**Python:**
- Framework: Not detected (no pytest/unittest config in `pyproject.toml`)
- Linting: Ruff (configured in `pyproject.toml` line 37-38)
- Type checking: mypy strict mode (`pyproject.toml` line 40-45)

**Java:**
- JNI tests: `./zig/zig build test:jni`
- Location: `src/clients/java/`

**C:**
- Tests: `src/clients/c/test.zig`, `src/c_client_tests.zig`
- Sample builds: `./zig/zig build clients:c:sample`

## Test Filtering

**By Name:**
```bash
./zig/zig build test:unit -- --test-filter "encryption"
./zig/zig build test:unit -- --test-filter "parse_args"
./zig/zig build test:unit -- --test-filter "error_codes"
./zig/zig build test:unit -- --test-filter "sharding"
```

**Usage:**
- Pre-commit: Run targeted tests for modified areas
- Development: Fast feedback loop on specific modules
- CI: Full suite without filter

---

*Testing analysis: 2026-01-22*
