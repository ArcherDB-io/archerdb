# Coding Conventions

**Analysis Date:** 2026-01-22

## Naming Patterns

**Files:**
- Snake_case for modules: `geo_state_machine.zig`, `error_codes.zig`, `ram_index.zig`
- Test files co-located with source (no separate `.test.zig` extension)
- Entry points: `main.zig` in subdirectories (`src/archerdb/main.zig`)
- Special prefixes: `test_` for test-only modules, no suffix for production code

**Functions:**
- camelCase for all functions: `computeShardKey()`, `verifyHardwareSupport()`, `hashKeyId()`
- Public functions: `pub fn functionName()`
- Private functions: `fn functionName()` (no pub keyword)
- Test functions: `test "descriptive name in quotes" {`

**Variables:**
- Snake_case for locals: `unit_tests_contents`, `src_walker`, `file_buffer`
- Constants: SCREAMING_SNAKE_CASE: `ENCRYPTED_FILE_MAGIC`, `DEK_SIZE`, `AUTH_TAG_SIZE`
- Struct fields: snake_case: `wrapped_dek`, `key_id_hash`, `cwd_stack_count`

**Types:**
- PascalCase for types: `EncryptedFileHeader`, `KeyProvider`, `ShardingStrategy`
- Enum variants: snake_case: `.invalid_message`, `.checksum_mismatch_header`, `.aes_ni_not_available`
- Generic type parameters: Single uppercase letter or PascalCase: `T`, `Context`

## Code Style

**Formatting:**
- Tool: `.editorconfig` only (no prettier/eslint)
- Indent: 4 spaces for Zig (`.editorconfig` line 12)
- Line endings: LF (Unix-style)
- Charset: UTF-8
- Trailing whitespace: Trimmed
- Final newline: Required
- Max line length: Not enforced (some lines exceed 100 chars)

**Linting:**
- Tool: `src/tidy.zig` (custom Zig-based linting)
- Enforcement: Via `./zig/zig build test:fmt` (line 89 of `build.zig`)
- Checks performed:
  - Control character detection
  - Banned identifier detection
  - Dead file detection (unreferenced modules)
  - Identifier counting

## Import Organization

**Order:**
1. Standard library: `const std = @import("std");`
2. Builtin: `const builtin = @import("builtin");`
3. Internal stdx: `const stdx = @import("stdx");`
4. Project modules: `const vsr = @import("vsr.zig");`
5. Specific imports from modules: `const assert = std.debug.assert;`

**Pattern (from `src/encryption.zig` lines 20-29):**
```zig
const std = @import("std");
const stdx = @import("stdx");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const crypto = std.crypto;
const Aes256Gcm = crypto.aead.aes_gcm.Aes256Gcm;

const log = std.log.scoped(.encryption);
```

**Path Aliases:**
- None detected (Zig uses explicit `@import()` with relative paths)
- Build system modules: `@import("vsr")`, `@import("stdx")` configured in `build.zig`

## Error Handling

**Patterns:**
- Error unions: Functions return `!Type` for fallible operations
- Error sets: Custom error enums defined per module (`EncryptionError`, `ValidationError`, `ProtocolError`)
- Try operator: `try` for propagating errors: `try shell.exec()`
- Errdefer: Resource cleanup on error paths: `errdefer arena.deinit();`
- Catch: Explicit handling: `catch |err| switch (err) { ... }`

**Example from `src/shell.zig` lines 68-84:**
```zig
pub fn create(gpa: std.mem.Allocator) !*Shell {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    var project_root = try discover_project_root();
    errdefer project_root.close();

    var cwd = try project_root.openDir(".", .{});
    errdefer cwd.close();
    // ...
    return result;
}
```

## Logging

**Framework:** `std.log.scoped()` from Zig stdlib

**Patterns:**
- Scoped loggers: `const log = std.log.scoped(.encryption);` (`src/encryption.zig` line 29)
- Log levels: `.info`, `.warn`, `.err`, `.debug`
- Format strings: `log.info("Hardware AES-NI acceleration: AVAILABLE", .{});`

**When to Log:**
- Hardware detection: `src/encryption.zig` lines 101-112
- Configuration warnings: Software crypto fallback warnings
- Errors: Before returning errors to provide context

## Comments

**When to Comment:**
- File-level documentation: `//!` doc comments at top of file
- Public API: Doc comments on public functions, types
- Complex algorithms: Inline explanations for non-obvious code
- TODOs: `// TODO` for future work (50+ instances across codebase)

**JSDoc/TSDoc:**
- TypeScript files use JSDoc: `/** ... */` in `src/clients/node/src/index.ts`
- Zig uses `///` for doc comments on declarations
- Module-level docs: `//!` at file top (e.g., `src/encryption.zig` lines 4-18)

**License Headers:**
- Required on all source files (enforced by `scripts/add-license-headers.sh --check`)
- Format:
  ```zig
  // SPDX-License-Identifier: Apache-2.0
  // Copyright (c) 2024-2025 ArcherDB Contributors
  ```

## Function Design

**Size:**
- No hard limit enforced
- Largest files: `src/vsr/replica.zig` (12,447 lines), `src/geo_state_machine.zig` (5,487 lines)
- Functions vary from single-line to hundreds of lines

**Parameters:**
- Named struct parameters for >3 args
- Options struct pattern: `exec_options()` accepts `ExecOptions` struct
- Allocator as first parameter when needed: `fn create(gpa: std.mem.Allocator)`

**Return Values:**
- Error unions: `!Type` for fallible operations
- Void: No explicit return for side-effect functions
- Optionals: `?Type` for nullable returns
- Multiple returns via struct: `!struct { stdout: []u8, stderr: []u8 }`

## Module Design

**Exports:**
- Public declarations: `pub const`, `pub fn`, `pub var`
- Private by default (no keyword needed)
- Conditional compilation: `comptime { _ = @import("module.zig"); }` in `src/unit_tests.zig`

**Barrel Files:**
- `src/unit_tests.zig`: Auto-generated comptime import list (quine pattern)
- `src/stdx/stdx.zig`: Re-exports submodules
- Pattern: `pub const Type = @import("file.zig").Type;`

## Constants

**Placement:**
- Module-level constants before functions
- Sizes: `DEK_SIZE: usize = 32;` (`src/encryption.zig` line 44)
- Magic values: `ENCRYPTED_FILE_MAGIC: [4]u8 = .{ 'A', 'R', 'C', 'E' };`
- Byte multipliers: `const MiB = stdx.MiB;` (imported from `stdx`)

## Assertions

**Usage:**
- Development checks: `assert(condition);` from `std.debug.assert`
- Comptime validation: `comptime { assert(...); }` in struct definitions
- Size validation: `comptime { assert(@sizeOf(EncryptedFileHeader) == 96); }` (`src/encryption.zig` line 145)

## Memory Management

**Allocators:**
- Explicit allocator parameter: `gpa: std.mem.Allocator`
- Arena pattern: `std.heap.ArenaAllocator` for grouped allocations
- Defer/errdefer: Guaranteed cleanup
- Example from `src/shell.zig`:
  ```zig
  var arena = std.heap.ArenaAllocator.init(gpa);
  defer arena.deinit();
  ```

## Build System

**Tool:** Zig build system (`build.zig`)

**Key Commands:**
- Build: `./zig/zig build`
- Run tests: `./zig/zig build test:unit`
- Check formatting: `./zig/zig build test:fmt`
- Integration tests: `./zig/zig build test:integration`

**Custom Steps:**
- Client builds: `./zig/zig build clients:node`, `clients:python`, `clients:java`
- VOPR fuzzer: `./zig/zig build vopr`
- Vortex tests: `./zig/zig build vortex`

---

*Convention analysis: 2026-01-22*
