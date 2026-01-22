# Phase 1: Platform Foundation - Research

**Researched:** 2026-01-22
**Domain:** Platform support (Linux/Darwin), I/O abstraction, message bus error handling
**Confidence:** HIGH

## Summary

Phase 1 focuses on three areas: (1) removing all Windows support code, (2) fixing Darwin/macOS platform issues (fsync durability and test assertions), and (3) completing message bus error handling with proper fatal/recoverable classification.

The codebase uses a platform abstraction pattern with `src/io.zig` as the hub, importing platform-specific implementations from `src/io/linux.zig`, `src/io/darwin.zig`, and `src/io/windows.zig`. Windows removal requires systematic cleanup across ~60 files containing Windows conditionals. Darwin fsync currently has an unsafe fallback that must be replaced with startup failure. The message bus has explicit TODO comments marking areas needing error classification review.

**Primary recommendation:** Windows removal should be done atomically in related groups (io layer, build system, documentation, tests) rather than one massive commit. Darwin fsync fix is straightforward but requires adding startup validation. Message bus error handling requires auditing each error site and applying the classification rules from CONTEXT.md.

## Standard Stack

The established libraries/tools for this domain:

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Zig std.posix | 0.15+ | POSIX system calls | Zig's thin wrappers with error unions |
| io_uring | Linux 5.5+ | Async I/O on Linux | Required, no epoll fallback per CONTEXT.md |
| kqueue | macOS 10.14+ | Async I/O on Darwin | Native macOS event notification |
| fcntl F_FULLFSYNC | macOS | Disk durability | Only way to get true durability on Darwin |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| std.log.scoped | Zig stdlib | Categorized logging | All platform detection/error messages |
| vsr.fatal | Internal | Fatal error exit | Environmental errors where stopping is intended |
| std.process.exit | Zig stdlib | Process termination | Clean shutdown with specific exit codes |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| io_uring | epoll | Simpler but less performant, rejected per CONTEXT.md |
| F_FULLFSYNC | F_BARRIERFSYNC | Faster but weaker guarantees, rejected per CONTEXT.md |
| fsync fallback | startup failure | Previous approach unsafe for durability |

**Installation:**
No external dependencies - all functionality is in Zig stdlib or the existing codebase.

## Architecture Patterns

### Recommended Project Structure
```
src/
├── io.zig              # Platform selector (hub)
├── io/
│   ├── linux.zig       # io_uring implementation
│   ├── darwin.zig      # kqueue implementation
│   ├── common.zig      # Shared TCP/socket utilities
│   └── test.zig        # Platform-agnostic tests
├── message_bus.zig     # Networking abstraction
└── vsr.zig             # Contains fatal() for error handling
```

### Pattern 1: Platform Conditional Selection
**What:** Single import point selects platform implementation at comptime
**When to use:** All platform-specific code access
**Example:**
```zig
// Source: src/io.zig (current pattern)
pub const IO = switch (builtin.target.os.tag) {
    .linux => IO_Linux,
    .macos, .tvos, .watchos, .ios => IO_Darwin,
    else => @compileError("IO is not supported for platform"),
};
```

### Pattern 2: Fatal vs Recoverable Error Handling
**What:** Use `vsr.fatal()` for environmental errors, propagate for transient errors
**When to use:** Error classification in message bus and platform detection
**Example:**
```zig
// Source: src/vsr.zig lines 722-737
// Use fatal for environmental errors where stopping is intended
pub fn fatal(reason: FatalReason, comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt, args);
    const status = reason.exit_status();
    assert(status != 0);
    std.process.exit(status);
}
```

### Pattern 3: Startup Capability Detection
**What:** Detect platform capabilities once at startup, fail early
**When to use:** F_FULLFSYNC availability, io_uring presence
**Example:**
```zig
// Source: src/io/linux.zig lines 66-84 (io_uring detection)
const version = try parse_dirty_semver(&uts.release);
if (version.order(std.SemanticVersion{ .major = 5, .minor = 5, .patch = 0 }) == .lt) {
    @panic("Linux kernel 5.5 or greater is required for io_uring OP_ACCEPT");
}
```

### Anti-Patterns to Avoid
- **Silent fallback to weaker guarantees:** Darwin fsync currently falls back silently (line 1074). Must fail startup instead.
- **Terminating on every error:** Message bus has TODO comments about not closing on every error. Classify first.
- **Windows conditionals scattered throughout:** These must be removed completely, not hidden behind dead code.

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Fatal process exit | Custom exit() wrapper | `vsr.fatal()` | Standardized exit codes, consistent logging |
| Platform detection | Manual `uname` parsing | `builtin.target.os.tag` | Comptime evaluation, exhaustive switches |
| Socket shutdown | Custom close logic | `posix.shutdown()` then `io.close()` | Proper TCP state machine handling |
| Kernel version check | Regex parsing | `parse_dirty_semver()` in linux.zig | Already handles messy kernel strings |

**Key insight:** The codebase has established patterns for platform abstraction. Follow them rather than inventing new approaches.

## Common Pitfalls

### Pitfall 1: Darwin fsync Does Not Provide Durability
**What goes wrong:** Data loss on power failure or kernel panic because regular `fsync()` doesn't flush disk caches
**Why it happens:** macOS fsync only guarantees data to OS buffers, not physical disk
**How to avoid:** Must use `fcntl(fd, F_FULLFSYNC, 1)` and fail startup if unavailable
**Warning signs:** Current code (darwin.zig:1074) falls back to fsync, which is unsafe

### Pitfall 2: shutdown() Behavior Differs Between Linux and Darwin
**What goes wrong:** Pending I/O may or may not complete after shutdown() depending on platform
**Why it happens:** POSIX doesn't fully specify shutdown() interaction with async I/O
**How to avoid:** The message_bus.zig has a TODO (line 951) noting this needs investigation
**Warning signs:** Connection termination behaves differently across platforms

### Pitfall 3: Windows Removal Leaves Dead References
**What goes wrong:** Build failures, dangling imports, confusing error messages
**Why it happens:** Windows conditionals are in ~60 files, easy to miss some
**How to avoid:** Systematic search for patterns: `builtin.os.tag == .windows`, `@import("windows")`, `windows.zig`
**Warning signs:** Files with Windows-only branches become unreachable

### Pitfall 4: Error Classification Without Audit
**What goes wrong:** Closing connections on recoverable errors, or ignoring fatal errors
**Why it happens:** Message bus has "TODO: maybe don't need to close on *every* error" comments
**How to avoid:** Per CONTEXT.md: timeouts=configurable, protocol violations=fatal, resource exhaustion=reject new work
**Warning signs:** Every recv/send error terminates connection regardless of type

### Pitfall 5: macOS x86_64 Test Assertion
**What goes wrong:** build.zig:811 assertion triggers on macOS x86_64 even though tests pass
**Why it happens:** The assertion expects aarch64 but x86_64 Macs still exist (and are in CI)
**How to avoid:** Remove or condition the assertion, investigate why it was added
**Warning signs:** Comment says "TODO: this assert triggers, but the macOS tests on x86_64 work...?"

## Code Examples

Verified patterns from the codebase:

### Fatal Error for Platform Requirements
```zig
// Source: src/io/linux.zig lines 69-81
if (version.order(std.SemanticVersion{ .major = 5, .minor = 5, .patch = 0 }) == .lt) {
    @panic("Linux kernel 5.5 or greater is required for io_uring OP_ACCEPT");
}

errdefer |err| switch (err) {
    error.SystemOutdated => {
        log.err("io_uring is not available", .{});
        log.err("likely cause: the syscall is disabled by seccomp", .{});
    },
    error.PermissionDenied => {
        log.err("io_uring is not available", .{});
        log.err("likely cause: the syscall is disabled by sysctl, " ++
            "try 'sysctl -w kernel.io_uring_disabled=0'", .{});
    },
    else => {},
};
```

### Darwin F_FULLFSYNC (Current Unsafe Implementation)
```zig
// Source: src/io/darwin.zig lines 1067-1075
/// Darwin's fsync() syscall does not flush past the disk cache. We must use F_FULLFSYNC
fn fs_sync(fd: fd_t) !void {
    // TODO: This is of dubious safety - it's _not_ safe to fall back on posix.fsync unless it's
    // known at startup that the disk (eg, an external disk on a Mac) doesn't support F_FULLFSYNC.
    _ = posix.fcntl(fd, posix.F.FULLFSYNC, 1) catch return posix.fsync(fd);
}
```

### Message Bus Connection Termination
```zig
// Source: src/message_bus.zig lines 940-980
fn terminate(
    bus: *MessageBus,
    connection: *Connection,
    how: enum { shutdown, no_shutdown },
) void {
    switch (how) {
        .shutdown => {
            // The shutdown syscall will cause currently in progress send/recv
            // operations to be gracefully closed while keeping the fd open.
            //
            // TODO: Investigate differences between shutdown() on Linux vs Darwin.
            bus.io.shutdown(connection.fd.?, .both) catch |err| switch (err) {
                error.SocketNotConnected => {
                    // This is fine, continue with termination
                },
                // Ignore all the remaining errors for now
                // ... (needs classification per CONTEXT.md)
            };
        },
        .no_shutdown => {},
    }
    connection.state = .terminating;
    bus.terminate_join(connection);
}
```

### Platform Selection Hub Pattern
```zig
// Source: src/io.zig (after Windows removal)
const IO_Linux = @import("io/linux.zig").IO;
const IO_Darwin = @import("io/darwin.zig").IO;

pub const IO = switch (builtin.target.os.tag) {
    .linux => IO_Linux,
    .macos, .tvos, .watchos, .ios => IO_Darwin,
    else => @compileError("IO is not supported for platform"),
};
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| epoll for Linux I/O | io_uring | Kernel 5.1+ (2019) | Higher throughput, unified API |
| Windows IOCP support | Linux/Darwin only | This phase | Simpler codebase, reduced maintenance |
| fsync() on Darwin | F_FULLFSYNC required | This phase | True durability guarantees |
| Ad-hoc error handling | Classified fatal/recoverable | This phase | Predictable connection behavior |

**Deprecated/outdated:**
- Windows IOCP: Being removed, no longer supported
- Darwin fsync fallback: Unsafe, must be replaced with startup failure
- Scatter/gather Windows conditionals: Must be consolidated and removed

## Open Questions

Things that couldn't be fully resolved:

1. **shutdown() Linux vs Darwin differences**
   - What we know: TODO comment at message_bus.zig:951 notes differences
   - What's unclear: Exact behavioral differences with pending I/O
   - Recommendation: Test both platforms, document findings, may need platform-specific handling

2. **macOS x86_64 assertion purpose**
   - What we know: build.zig:811 has assertion that triggers but tests pass
   - What's unclear: Why the assertion was added, what it was meant to catch
   - Recommendation: Investigate git history, either fix the condition or remove with justification

3. **F_FULLFSYNC unavailability scenarios**
   - What we know: Some external disks may not support F_FULLFSYNC
   - What's unclear: How to detect this reliably at startup
   - Recommendation: Try fcntl at startup, fail with actionable error if it fails

## Platform Requirements Summary

### Linux
- **Kernel:** 5.5+ (for io_uring OP_ACCEPT)
- **Syscalls:** io_uring must be enabled (`kernel.io_uring_disabled=0`)
- **Memory:** RLIMIT_MEMLOCK may need adjustment for large ring sizes

### macOS/Darwin
- **Version:** 10.14+ (for kqueue improvements)
- **Durability:** F_FULLFSYNC must be supported by filesystem/disk
- **Architectures:** Both x86_64 and aarch64 supported

### Exit Codes (vsr.fatal)
The codebase uses `FatalReason` enum with `exit_status()` method for standardized exit codes:
- `.cli` errors: User input/configuration issues
- Environmental errors: Resource exhaustion, platform requirements

## Sources

### Primary (HIGH confidence)
- `src/io.zig` - Platform abstraction hub
- `src/io/linux.zig` - io_uring implementation with version detection
- `src/io/darwin.zig` - kqueue implementation with F_FULLFSYNC
- `src/message_bus.zig` - Connection management and error handling
- `src/vsr.zig` - fatal() function and error patterns
- `build.zig` - Build system with platform targets

### Secondary (MEDIUM confidence)
- [io_uring Wikipedia](https://en.wikipedia.org/wiki/Io_uring) - Kernel version history
- [Apple fcntl documentation](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fsync.2.html) - F_FULLFSYNC requirements
- [SQLite on macOS ACID issues](https://bonsaidb.io/blog/acid-on-apple/) - F_FULLFSYNC vs fsync analysis

### Tertiary (LOW confidence)
- General Zig POSIX patterns from ziglang.org documentation

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Based on direct codebase analysis
- Architecture: HIGH - Patterns extracted from existing code
- Pitfalls: HIGH - All identified from actual TODOs and code comments
- Darwin fsync: HIGH - Well-documented platform behavior
- shutdown() differences: MEDIUM - TODO noted but not fully investigated

**Research date:** 2026-01-22
**Valid until:** 60 days (platform I/O patterns are stable)
