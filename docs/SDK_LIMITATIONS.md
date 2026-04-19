# SDK Limitations

This document captures practical SDK constraints that matter when shipping ArcherDB applications.

## Shared Limits

- The SDKs expose the database operation surface; they do not add built-in authn/authz, TLS, or backup orchestration. Those controls are part of ArcherDB's infrastructure-managed deployment model.
- Checked-in parity evidence is a snapshot, not a perpetual guarantee. Re-run parity before release or when changing protocol behavior.
- The SDKs are only as capable as the underlying server surface. Features that are still experimental or operator-only should not be marketed as fully productized SDK workflows.

## Language-Specific Constraints

### Python

- Best suited for application logic, scripting, and operational tooling, not raw highest-throughput client hot paths.
- Build and test flows assume a working Python toolchain and the repo's native extension build path.

### Node.js

- Uses `BigInt` for 64-bit and 128-bit values. Callers must preserve `BigInt` semantics end-to-end.
- Build and test flows depend on native bindings and a working Node.js toolchain.

### Go

- Uses ArcherDB-specific types such as `Uint128` and geospatial helper builders instead of native 128-bit language primitives.
- Build and test flows depend on generated/native client artifacts plus a working Go toolchain.

### Java

- Uses JNI/native bindings and requires a working JVM plus native artifact generation in build/test flows.
- JVM ergonomics differ from the other SDKs; release validation must include the JNI path, not only pure-Java compilation.
- The Java multi-region client has latency-aware `NEAREST` routing: a background `LatencyProber` periodically TCP-connects to each configured region, maintains rolling RTT averages per region, and selection picks the healthy region with the lowest average. `FOLLOWER` routing remains deterministic (first follower). Before the first probe completes NEAREST falls back to config-order, so the very first request never stalls on a probe.

### Java And Node Unit Tests

- Checked-in Java and Node unit tests include API-shape and wire-format coverage that runs without a live cluster. Those tests are useful, but they are not a substitute for cluster-backed SDK integration evidence.

### C

- The C SDK is the lowest-level API and intentionally exposes callback-based completion, manual buffer handling, and explicit lifecycle management.
- The C client API is not the ergonomic default for multi-threaded applications; callers are responsible for respecting the thread-safety and pinned-memory constraints documented in `arch_client.h`.

## Operational Caveat

Deep validation tiers and long-running benchmark publication are currently manual-dispatch workflows rather than scheduled GitHub Actions runs. SDK release confidence should therefore come from the checked workflow results and local/manual release-candidate runs, not from an assumption of continuous nightly coverage.
