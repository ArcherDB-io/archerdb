#!/bin/bash
# Script to create spec implementation issues from tasks.md sections 1.x-36.x
# These are detailed reference tasks that map to ArcherDB adaptation

REPO="ArcherDB-io/archerdb"

# Create a milestone for spec implementation
gh api repos/$REPO/milestones -f title="Spec Implementation Reference" -f description="Detailed implementation tasks from original build-from-scratch spec (now ArcherDB adaptation)" -f state="open" 2>&1 | jq -r '.number'

# Create labels for spec categories
gh label create "spec:core" --repo $REPO --color "0366d6" --description "Core types and constants" 2>/dev/null || true
gh label create "spec:memory" --repo $REPO --color "1d76db" --description "Memory management" 2>/dev/null || true
gh label create "spec:storage" --repo $REPO --color "5319e7" --description "Storage engine" 2>/dev/null || true
gh label create "spec:vsr" --repo $REPO --color "d93f0b" --description "VSR replication" 2>/dev/null || true
gh label create "spec:query" --repo $REPO --color "0e8a16" --description "Query engine" 2>/dev/null || true
gh label create "spec:client" --repo $REPO --color "fbca04" --description "Client protocol/SDKs" 2>/dev/null || true
gh label create "spec:ops" --repo $REPO --color "006b75" --description "Operations/Observability" 2>/dev/null || true

echo "Creating spec implementation issues..."

# 1.x + 4.x: Core Types & Constants + Checksums
gh issue create --repo $REPO \
  --title "Spec 1.x/4.x: Core Types, Constants & Checksums" \
  --label "spec:core" \
  --milestone "Spec Implementation Reference" \
  --body "## Reference Implementation Tasks

These tasks define WHAT needs to be implemented. For ArcherDB, adapt from ArcherDB rather than build from scratch.

### 1.x Core Types & Constants
- [ ] 1.1 Update \`src/constants.zig\` with compile-time configuration
- [ ] 1.2 Create \`src/geo_event.zig\` with 128-byte GeoEvent extern struct
- [ ] 1.3 Add comptime assertions: @sizeOf == 128, @alignOf == 16
- [ ] 1.4 Create GeoEventFlags as packed struct(u16)
- [ ] 1.5 Create 256-byte BlockHeader extern struct
- [ ] 1.6 Implement pack_id(s2_cell, timestamp) helper
- [ ] 1.7 Implement coordinate conversion (nanodegrees <-> float)
- [ ] 1.8 Write comptime tests for struct layout
- [ ] 1.9 Implement ScratchBufferPool for S2 operations
- [ ] 1.10 Add partial_result handling to MultiBatchExecutor

### 4.x Checksums & Integrity
- [ ] 4.1 Create \`src/checksum.zig\` with Aegis-128L MAC
- [ ] 4.2 Add comptime check for AES-NI support
- [ ] 4.3 Implement header checksum computation
- [ ] 4.4 Implement body checksum computation
- [ ] 4.5 Implement sticky checksum caching
- [ ] 4.6 Write tests including known-answer tests

## ArcherDB Adaptation Notes
- Most checksum code can be reused from ArcherDB
- GeoEvent struct is NEW (replaces Account)
- Constants need updating for geospatial workload

## Reference
See \`tasks.md\` sections 1.x and 4.x."

# 2.x + 3.x: Memory Management + Hybrid Index
gh issue create --repo $REPO \
  --title "Spec 2.x/3.x: Memory Management & Hybrid Memory Index" \
  --label "spec:memory" \
  --milestone "Spec Implementation Reference" \
  --body "## Reference Implementation Tasks

### 2.x Memory Management
- [ ] 2.1 Create static_allocator.zig with init/static/deinit states
- [ ] 2.2 Implement state transition functions
- [ ] 2.3 Create message_pool.zig with reference counting
- [ ] 2.4 Implement intrusive QueueType(T) and StackType(T)
- [ ] 2.5 Implement RingBufferType
- [ ] 2.6 Create NodePool with bitset tracking
- [ ] 2.7 Implement BoundedArrayType(T, capacity)
- [ ] 2.8 Create CountingAllocator wrapper
- [ ] 2.9 Write tests for all memory structures

### 3.x Hybrid Memory (Index-on-RAM)
- [ ] 3.1 Create primary_index.zig with hash map structure
- [ ] 3.2 Define IndexEntry struct (64 bytes)
- [ ] 3.3 Implement open addressing with linear probing
- [ ] 3.4 Pre-allocate index capacity at startup
- [ ] 3.5 Implement lookup(entity_id) -> ?IndexEntry O(1)
- [ ] 3.6 Implement upsert with LWW semantics
- [ ] 3.7 Handle out-of-order timestamps
- [ ] 3.8-3.12 Implement checkpoint mechanism
- [ ] 3.13-3.15 Implement rebuild strategies
- [ ] 3.16 Add index statistics
- [ ] 3.17 Write tests for LWW and checkpoint/rebuild

## ArcherDB Adaptation Notes
- Memory management code largely reusable
- Hybrid index is NEW (not in ArcherDB)

## Reference
See \`tasks.md\` sections 2.x and 3.x, \`specs/hybrid-memory/spec.md\`."

# 5.x + 6.x + 7.x: I/O & Storage Engine
gh issue create --repo $REPO \
  --title "Spec 5.x/6.x/7.x: I/O Subsystem & Storage Engine" \
  --label "spec:storage" \
  --milestone "Spec Implementation Reference" \
  --body "## Reference Implementation Tasks

### 5.x I/O Subsystem
- [ ] 5.1 Create ring.zig with io_uring wrapper
- [ ] 5.2 Implement SQE batching and CQE processing
- [ ] 5.3 Implement completion callbacks
- [ ] 5.4 Add timeout support
- [ ] 5.5 Create message_bus.zig
- [ ] 5.6-5.8 Implement optimizations
- [ ] 5.9 Create macOS (kqueue) fallback
- [ ] 5.10 Write I/O integration tests

### 6.x Storage Engine - Data File
- [ ] 6.1 Create data_file.zig with zone layout
- [ ] 6.2-6.4 Implement superblock (4/6/8 copies)
- [ ] 6.5-6.6 Create dual-ring WAL (8192 slots)
- [ ] 6.7 Implement client replies zone
- [ ] 6.8-6.9 Add Direct I/O
- [ ] 6.10 Write data file tests

### 7.x Storage Engine - Grid & LSM
- [ ] 7.1-7.4 Create grid.zig with block cache
- [ ] 7.5-7.7 Create free_set.zig
- [ ] 7.8-7.9 Create table.zig
- [ ] 7.10-7.11 Create manifest.zig and compaction
- [ ] 7.12 Write LSM integration tests

## ArcherDB Adaptation Notes
- I/O and storage code is KEEP (minimal changes)
- LSM needs adaptation for GeoEvent

## Reference
See \`tasks.md\` sections 5.x, 6.x, 7.x, \`specs/storage-engine/spec.md\`."

# 8.x + 9.x + 10.x + 11.x: VSR Protocol
gh issue create --repo $REPO \
  --title "Spec 8.x-11.x: VSR Replication Protocol" \
  --label "spec:vsr" --label "critical" \
  --milestone "Spec Implementation Reference" \
  --body "## Reference Implementation Tasks

### 8.x VSR Protocol - Core
- [ ] 8.1 Create message.zig with 256-byte header
- [ ] 8.2 Define all protocol commands
- [ ] 8.3 Create replica.zig state machine
- [ ] 8.4 Implement Flexible Paxos quorums
- [ ] 8.5-8.7 Implement prepare/commit flow
- [ ] 8.8 Add ping/pong

### 9.x VSR Protocol - View Changes
- [ ] 9.1 Implement StartViewChange
- [ ] 9.2 Implement DoViewChange
- [ ] 9.3 Implement CTRL protocol
- [ ] 9.4 Implement StartView broadcast
- [ ] 9.5 Implement primary abdication
- [ ] 9.6 Write view change tests

### 10.x VSR Protocol - State & Recovery
- [ ] 10.1-10.3 Create client_sessions.zig
- [ ] 10.4-10.6 Implement repair mechanisms
- [ ] 10.7 Create clock.zig (Marzullo)
- [ ] 10.8 Implement VSRState persistence
- [ ] 10.9 Write recovery tests

### 11.x VSR Protocol - Commit Pipeline
- [ ] 11.1-11.7 Implement all pipeline stages
- [ ] 11.8 Write pipeline tests

## ArcherDB Adaptation Notes
- VSR code is KEEP - DO NOT MODIFY core consensus
- Only adapt state machine interface

## Reference
See \`tasks.md\` sections 8.x-11.x, \`specs/replication/spec.md\`."

# 12.x + 13.x: S2 Integration & Query Engine
gh issue create --repo $REPO \
  --title "Spec 12.x/13.x: S2 Integration & Query Engine" \
  --label "spec:query" \
  --milestone "Spec Implementation Reference" \
  --body "## Reference Implementation Tasks

### 12.x S2 Integration
- [ ] 12.1 Evaluate S2 options and memory requirements
- [ ] 12.2 Implement golden vector generator tool
- [ ] 12.3 Implement pure Zig lat_lon_to_cell_id
- [ ] 12.4 Implement cell_id_to_lat_lon
- [ ] 12.5 Implement RegionCoverer for polygons
- [ ] 12.6 Implement Cap covering for radius
- [ ] 12.7 Create scratch buffer pool
- [ ] 12.8 Write S2 tests

### 13.x Query Engine
- [ ] 13.1 Create state_machine.zig (three-phase)
- [ ] 13.2-13.5 Implement validation/prepare/prefetch/commit
- [ ] 13.6 Create multi-batch encoding
- [ ] 13.7 Implement UUID lookup query
- [ ] 13.8 Implement radius query
- [ ] 13.9 Implement polygon query
- [ ] 13.10-13.11 Implement skip-scan and post-filter
- [ ] 13.12 Write query tests

## ArcherDB Adaptation Notes
- S2 is entirely NEW (geospatial-specific)
- Query engine adapts ArcherDB state machine pattern

## Reference
See \`tasks.md\` sections 12.x and 13.x, \`specs/query-engine/spec.md\`."

# 14.x: Testing & Simulation
gh issue create --repo $REPO \
  --title "Spec 14.x: Testing & Simulation (VOPR)" \
  --label "spec:core" --label "validation" \
  --milestone "Spec Implementation Reference" \
  --body "## Reference Implementation Tasks

### 14.x Testing & Simulation
- [ ] 14.1 Create simulator.zig with deterministic PRNG
- [ ] 14.2 Implement simulated time
- [ ] 14.3 Implement simulated I/O
- [ ] 14.4-14.7 Create fault injection (storage, network, timing, crashes)
- [ ] 14.8 Implement two-phase testing (safety then liveness)
- [ ] 14.9 Implement state verification
- [ ] 14.10 Create workload generators
- [ ] 14.11 Implement seed regression suite
- [ ] 14.12 Write simulator tests

## ArcherDB Adaptation Notes
- VOPR simulator is KEEP
- Adapt workloads for GeoEvent operations

## Reference
See \`tasks.md\` section 14.x."

# 15.x + 16.x: Client Protocol & Security
gh issue create --repo $REPO \
  --title "Spec 15.x/16.x: Client Protocol & Security (mTLS)" \
  --label "spec:client" \
  --milestone "Spec Implementation Reference" \
  --body "## Reference Implementation Tasks

### 15.x Client Protocol & SDKs
- [ ] 15.1 Define binary message framing (256-byte header)
- [ ] 15.2 Implement operation codes enum
- [ ] 15.3 Implement request/response pattern
- [ ] 15.4 Create Zig SDK (reference)
- [ ] 15.5 Implement connection pooling
- [ ] 15.6 Add batch encoding helpers
- [ ] 15.7-15.10 Create SDK skeletons (Java, Go, Python, Node.js)
- [ ] 15.11 Write cross-language tests

### 16.x Security (mTLS)
- [ ] 16.1 Integrate TLS library
- [ ] 16.2 Implement certificate loading
- [ ] 16.3-16.4 Add mTLS handshake
- [ ] 16.5 Implement certificate validation
- [ ] 16.6 Add --tls-required flag
- [ ] 16.7 Implement cluster ID verification
- [ ] 16.8-16.9 Add audit logging and cert reload
- [ ] 16.10 Write security tests

## ArcherDB Adaptation Notes
- Wire format changes for GeoEvent operations
- Security code largely reusable

## Reference
See \`tasks.md\` sections 15.x and 16.x, \`specs/client-protocol/spec.md\`, \`specs/security/spec.md\`."

# 17.x-20.x: Operations
gh issue create --repo $REPO \
  --title "Spec 17.x-20.x: Observability, Backup, Deployment, Benchmarks" \
  --label "spec:ops" \
  --milestone "Spec Implementation Reference" \
  --body "## Reference Implementation Tasks

### 17.x Observability
- [ ] 17.1-17.2 Create Prometheus metrics endpoint
- [ ] 17.3-17.8 Add all metric categories
- [ ] 17.9-17.11 Implement structured logging
- [ ] 17.12 Write observability tests

### 18.x Backup & Restore
- [ ] 18.1-18.3 Implement S3-compatible backup
- [ ] 18.4-18.5 Implement restore operations
- [ ] 18.6-18.7 Add backup scheduling
- [ ] 18.8-18.9 Implement checksum verification
- [ ] 18.10 Write backup/restore tests

### 19.x Deployment
- [ ] 19.1 Create server binary with CLI
- [ ] 19.2 Implement cluster formation
- [ ] 19.3-19.4 Add health checks
- [ ] 19.5-19.6 Create container/systemd config
- [ ] 19.7 Document deployment options

### 20.x Benchmarks
- [ ] 20.1-20.4 Create benchmark framework
- [ ] 20.5-20.8 Implement specific benchmarks
- [ ] 20.9 Create reporting dashboard

## Reference
See \`tasks.md\` sections 17.x-20.x."

# 21.x-36.x: Remaining spec sections (summary issue)
gh issue create --repo $REPO \
  --title "Spec 21.x-36.x: Remaining Specification Implementation" \
  --label "spec:core" \
  --milestone "Spec Implementation Reference" \
  --body "## Remaining Specification Sections

These sections cover additional specification requirements. Create detailed issues as needed during implementation.

### 21.x Compliance Framework
- GDPR compliance (data deletion)
- Audit logging
- Data sovereignty

### 22.x Code of Conduct & Community
- Community guidelines
- Contribution process

### 23.x Architecture & Rationale
- Decision documentation
- Architecture diagrams

### 24.x Error Codes
- Complete error code implementation
- Error documentation

### 25.x Consistency Model
- Linearizability guarantees
- Consistency documentation

### 26.x Licensing & Legal
- Apache 2.0 compliance
- ArcherDB attribution

### 27.x TTL & Retention
- TTL implementation details
- Retention policies

### 28.x Performance Validation
- Performance test framework
- Benchmark methodology

### 29.x Success Metrics
- KPI tracking
- Success criteria

### 30.x Risk Management
- Risk mitigation
- Contingency planning

### 31.x Community & Ecosystem
- Community building
- Integration partnerships

### 32.x Performance Profiling
- Profiling tools
- Performance analysis

### 33.x Solo Developer Workflow
- AI-assisted development
- Knowledge management

### 34.x Risk Management Implementation
- Risk tracking
- Mitigation procedures

### 35.x Performance Validation Methodology
- Test methodology
- Validation procedures

### 36.x Success Metrics & KPIs
- Metric tracking
- Dashboard implementation

## Reference
See \`tasks.md\` sections 21.x-36.x and respective spec files."

echo "Adding all spec issues to project..."

# Add all issues to project
for i in $(gh issue list --repo $REPO --state open --json number --jq '.[].number'); do
  gh project item-add 1 --owner ArcherDB-io --url "https://github.com/$REPO/issues/$i" 2>/dev/null || true
done

echo "Done! Created all spec implementation issues."
