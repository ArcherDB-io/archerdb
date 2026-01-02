# Configuration Management Specification

**Reference Implementation:** TigerBeetle's CLI flag-based configuration

This specification adopts TigerBeetle's philosophy of CLI-first configuration with no config files, keeping deployment simple and avoiding configuration drift.

---

## ADDED Requirements

### Requirement: CLI-Only Configuration

The system SHALL use command-line arguments exclusively for configuration, following TigerBeetle's simplicity principle.

#### Scenario: No configuration files

- **WHEN** configuring ArcherDB
- **THEN** all configuration SHALL be via CLI flags
- **AND** no configuration files SHALL be supported
- **AND** no environment variables SHALL be used for core configuration
- **AND** documentation SHALL emphasize this design choice for operational simplicity

#### Scenario: Flag naming conventions

- **WHEN** defining CLI flags
- **THEN** flags SHALL follow patterns:
  - `--cluster=id` - Cluster identifier
  - `--replica=index` - Replica index (0-based)
  - `--replica-count=N` - Total replicas in cluster
  - `--addresses=addr1,addr2,addr3` - Replica addresses
  - `--data-file=path` - Data file path
- **AND** flags SHALL use kebab-case naming

### Requirement: Single-Tenant Architecture

The system SHALL operate as a single-tenant database where each cluster serves one project/application.

#### Scenario: Tenancy model

- **WHEN** deploying ArcherDB
- **THEN** the architecture SHALL be single-tenant:
  ```
  ┌─────────────────────────────────────────────────────────────────┐
  │                SINGLE-TENANT ARCHITECTURE MODEL                  │
  ├─────────────────────────────────────────────────────────────────┤
  │                                                                  │
  │   ┌─────────────────┐    ┌─────────────────┐                    │
  │   │   Project A     │    │   Project B     │                    │
  │   │   Application   │    │   Application   │                    │
  │   └────────┬────────┘    └────────┬────────┘                    │
  │            │                      │                              │
  │            ▼                      ▼                              │
  │   ┌─────────────────┐    ┌─────────────────┐                    │
  │   │  ArcherDB       │    │  ArcherDB       │                    │
  │   │  Cluster A      │    │  Cluster B      │                    │
  │   │  (1-6 replicas) │    │  (1-6 replicas) │                    │
  │   └─────────────────┘    └─────────────────┘                    │
  │                                                                  │
  │   Each project gets its own dedicated ArcherDB cluster.          │
  │   Data is fully isolated at the infrastructure level.            │
  └─────────────────────────────────────────────────────────────────┘
  ```
- **AND** multi-tenancy within a single cluster is NOT supported
- **AND** data isolation is enforced at the cluster level

#### Scenario: Single-tenant rationale

- **WHEN** understanding the single-tenant design decision
- **THEN** the rationale SHALL be:
  ```
  WHY SINGLE-TENANT?
  ═══════════════════

  1. PERFORMANCE ISOLATION
     - No noisy neighbor effects
     - Predictable latency SLAs
     - Full resource dedication

  2. SECURITY ISOLATION
     - No cross-tenant data leakage possible
     - Simpler security model
     - Clear blast radius for incidents

  3. OPERATIONAL SIMPLICITY
     - No tenant ID in every query
     - No complex quota management
     - Easier capacity planning

  4. COMPLIANCE
     - Clear data residency per cluster
     - Simpler audit trails
     - Easier GDPR data isolation

  5. TIGHERBEETLE HERITAGE
     - Follows TigerBeetle's proven model
     - One database = one ledger
     - Deterministic resource allocation
  ```

#### Scenario: Multi-project deployment pattern

- **WHEN** running multiple projects on shared infrastructure
- **THEN** the deployment pattern SHALL be:
  ```
  MULTI-PROJECT DEPLOYMENT
  ════════════════════════

  Option A: Kubernetes/Container Orchestration
  ────────────────────────────────────────────
  - Deploy each ArcherDB cluster as a StatefulSet
  - Use namespaces for project isolation
  - Resource limits per StatefulSet

  Option B: Dedicated VMs
  ────────────────────────
  - 3-5 VMs per project
  - Complete network isolation
  - Simpler but more expensive

  Sizing guidance:
  - Small project (< 10M entities): 3-node cluster, 32GB RAM each
  - Medium project (10M-100M): 3-node cluster, 64GB RAM each
  - Large project (100M-1B): 5-node cluster, 128GB RAM each
  ```

#### Scenario: Cross-project queries

- **WHEN** a user needs to query across multiple projects
- **THEN** the system SHALL:
  - NOT support cross-cluster queries natively
  - Recommend application-level aggregation
  - Suggest data export/import for analytics use cases
- **AND** this is intentional for isolation guarantees

### Requirement: Cluster Configuration

The system SHALL require explicit cluster configuration at startup time.

#### Scenario: Cluster identity

- **WHEN** formatting a cluster
- **THEN** cluster SHALL be identified by:
  - `--cluster=id` - 128-bit cluster identifier (hex or decimal)
  - `--replica-count=N` - Number of replicas (1, 3, 5, or 6)
  - Cluster ID 0 SHALL be reserved for testing
- **AND** cluster configuration SHALL be immutable after format

#### Scenario: Replica configuration

- **WHEN** starting a replica
- **THEN** replica SHALL be configured with:
  - `--replica=index` - This replica's index (0 to replica-count-1)
  - `--data-file=path` - Path to this replica's data file
  - `--addresses=addr1:port1,addr2:port2,...` - All replica addresses
- **AND** address order SHALL correspond to replica index order

### Requirement: Network Configuration

The system SHALL support flexible network configuration for different deployment scenarios.

#### Scenario: Address specification

- **WHEN** configuring network addresses
- **THEN** addresses SHALL support:
  - IPv4 addresses: `192.168.1.1:3000`
  - IPv6 addresses: `[::1]:3000`
  - Hostnames: `replica-1.example.com:3000`
  - Port ranges SHALL be configurable (default: 3000-3005)
- **AND** all replicas SHALL use identical address list

#### Scenario: TLS configuration

- **WHEN** enabling TLS
- **THEN** TLS SHALL be configured with:
  - `--tls-certificate=path` - Server certificate file
  - `--tls-key=path` - Private key file
  - `--tls-ca=path` - Certificate authority file
  - `--tls-required=true/false` - Enforce TLS (default: true in production)
- **AND** certificate hot-reload SHALL be supported via SIGHUP

### Requirement: Storage Configuration

The system SHALL provide storage-related configuration options.

#### Scenario: Data file configuration

- **WHEN** configuring storage
- **THEN** system SHALL support:
  - `--data-file=path` - Data file path (default: cluster_replica.tigerbeetle)
  - `--cache-grid=size` - Grid cache size in MB (default: 1GB)
  - `--cache-grid-size-min=size` - Minimum cache size
  - `--cache-grid-size-max=size` - Maximum cache size
- **AND** cache sizes SHALL be validated against available RAM

#### Scenario: Performance tuning

- **WHEN** tuning performance
- **THEN** system SHALL support:
  - `--pipeline-max=N` - Maximum operations in pipeline
  - `--request-queue-max=N` - Request queue depth
  - `--batch-max=N` - Maximum batch size
  - `--io-depth=N` - Maximum concurrent I/O operations
- **AND** defaults SHALL be conservative for stability

### Requirement: Development vs Production Modes

The system SHALL distinguish development and production configurations through separate config files (`archerdb.dev.conf` vs `archerdb.prod.conf`) and startup mode flags.

#### Scenario: Development mode

- **WHEN** running in development
- **THEN** system SHALL support:
  - Single-replica clusters (`--replica-count=1`)
  - In-memory storage options (for testing)
  - Relaxed TLS requirements (`--tls-required=false`)
  - Verbose logging (`--log-level=debug`)
  - Development defaults SHALL prioritize ease of use
- **AND** development mode SHALL be indicated in startup logs with "WARNING: Development mode enabled - NOT for production" banner

### Requirement: Standalone Mode

The system SHALL support a standalone mode for development and testing that differs from replicated mode.

#### Scenario: Standalone vs replicated mode

- **WHEN** running with `--replica-count=1`
- **THEN** the system operates in standalone mode:
  - Single replica handles all operations
  - VSR protocol runs with 1-of-1 quorum (effectively no consensus needed)
  - All operations commit immediately (no network latency)
  - Same data file format as replicated mode
  - Performance is slightly better (no network round-trips)
- **AND** this is NOT a separate code path, just VSR with replica_count=1

#### Scenario: Standalone mode performance characteristics

- **WHEN** comparing standalone vs replicated mode
- **THEN** differences SHALL be:
  - Write latency: ~1ms standalone vs ~2-5ms replicated (no quorum wait)
  - Write throughput: ~30% higher in standalone (no replication overhead)
  - Durability: Same (fsync before commit in both modes)
  - Fault tolerance: None in standalone (single point of failure)
- **AND** standalone mode is suitable for development, testing, and non-critical workloads

#### Scenario: Migration from standalone to replicated

- **WHEN** migrating from standalone to replicated cluster
- **THEN** the operator SHALL:
  1. Stop the standalone replica
  2. Copy the data file to new replica machines
  3. Format additional replicas with same cluster ID
  4. Update addresses configuration
  5. Start all replicas (they will sync from copied state)
- **AND** data files are compatible (same format)
- **AND** migration requires downtime (no live migration)

#### Scenario: Standalone mode restrictions

- **WHEN** running in standalone mode
- **THEN** the system SHALL:
  - Log warning at startup: "Running in standalone mode - no fault tolerance"
  - Refuse to accept `--addresses` with multiple replicas
  - Skip replica heartbeat checks (no other replicas)
  - Accept same configuration flags as replicated mode
- **AND** standalone data files can be used to bootstrap replicated clusters

#### Scenario: Production mode

- **WHEN** running in production
- **THEN** system SHALL enforce:
  - Multi-replica clusters (minimum 3 replicas)
  - TLS required by default
  - Structured logging (`--log-format=json`)
  - Conservative resource limits
  - Production mode SHALL require explicit safety flags
- **AND** production validation SHALL prevent unsafe configurations

### Requirement: Logging Configuration

The system SHALL provide comprehensive logging configuration options.

#### Scenario: Log output control

- **WHEN** configuring logging
- **THEN** system SHALL support:
  - `--log-level=debug|info|warn|error` - Minimum log level
  - `--log-format=text|json` - Output format
  - `--log-file=path` - Optional file output (default: stderr)
  - `--log-rotate=size` - Log rotation size in MB
- **AND** JSON format SHALL be default for production

#### Scenario: Structured logging fields

- **WHEN** emitting logs
- **THEN** logs SHALL include:
  - `timestamp` - ISO 8601 timestamp
  - `level` - Log level
  - `component` - System component
  - `cluster` - Cluster ID
  - `replica` - Replica index
  - `operation` - Current operation (if applicable)
  - `request` - Client request number (for correlation/idempotency)
- **AND** fields SHALL be consistent across all log entries

### Requirement: Metrics Configuration

The system SHALL configure metrics export through command-line options.

#### Scenario: Prometheus metrics endpoint configuration

- **WHEN** enabling metrics
- **THEN** system SHALL support:
  - `--metrics-enabled=true|false` (default: true)
  - `--metrics-port=9091` (default: 9091)
  - `--metrics-bind=127.0.0.1|0.0.0.0` (default: 127.0.0.1)
  - `--metrics-token=<secret>` (optional bearer token)
  - `--metrics-tls-cert=<path>` and `--metrics-tls-key=<path>` (optional TLS)
- **AND** this MUST be consistent with `observability/spec.md` (Prometheus text format)
- **AND** the secure default is enabled + localhost bind

#### Scenario: Metrics filtering

- **WHEN** configuring metrics export
- **THEN** the system SHALL:
  - Expose a Prometheus scrape endpoint (pull model)
  - Avoid per-scrape expensive recomputation (cache metrics for short window)
  - Keep scrape latency bounded (<100ms p99) as specified in `observability/spec.md`

### Requirement: Security Configuration

The system SHALL provide security-related configuration options.

#### Scenario: Authentication configuration

- **WHEN** configuring authentication
- **THEN** system SHALL support:
  - `--tls-required=true/false` - Require TLS
  - `--client-certificate-cn=cn` - Expected client certificate CN
  - `--max-connections=N` - Maximum concurrent connections
  - `--connection-timeout=seconds` - Connection timeout
- **AND** authentication SHALL be enforced by default in production

#### Scenario: Authorization configuration

- **WHEN** configuring authorization
- **THEN** system SHALL support:
  - `--group-access=group1,group2` - Allowed groups (future extension)
  - `--admin-access=true/false` - Administrative access control
  - `--audit-log=path` - Audit log file path
  - `--audit-level=read|write|all` - Audit logging level
- **AND** all-or-nothing authorization SHALL be default (TigerBeetle pattern)

### Requirement: Operational Configuration

The system SHALL support operational tuning parameters.

#### Scenario: Performance limits

- **WHEN** configuring operational limits
- **THEN** system SHALL support:
  - `--max-request-size=bytes` - Maximum request size
  - `--max-result-size=bytes` - Maximum result set size
  - `--query-timeout=seconds` - Query execution timeout
  - `--checkpoint-interval=operations` - Checkpoint frequency
- **AND** limits SHALL prevent abuse and ensure stability

#### Scenario: Maintenance configuration

- **WHEN** configuring maintenance
- **THEN** system SHALL support:
  - `--maintenance-window=start-end` - Scheduled maintenance windows
  - `--backup-schedule=cron` - Automated backup schedule
  - `--cleanup-interval=seconds` - Background cleanup frequency
  - `--health-check-interval=seconds` - Health check frequency
- **AND** maintenance SHALL not impact normal operations

### Requirement: Configuration Validation

The system SHALL validate configuration at startup and provide helpful error messages.

#### Scenario: Startup validation

- **WHEN** starting with configuration
- **THEN** system SHALL validate:
  - Cluster configuration consistency
  - Network address reachability
  - File system permissions
  - Hardware requirements (AES-NI, RAM, disk space)
  - TLS certificate validity
- **AND** validation SHALL fail fast with specific error messages

#### Scenario: Configuration help

- **WHEN** requesting help
- **THEN** system SHALL provide:
  - `--help` - Complete flag reference
  - `--help-topic=topic` - Detailed help for specific areas
  - `--validate-config` - Configuration validation without starting
  - `--show-config` - Display parsed configuration
- **AND** help SHALL be comprehensive and up-to-date

### Requirement: Configuration Migration

The system SHALL handle configuration changes gracefully during upgrades.

#### Scenario: Backward compatibility

- **WHEN** upgrading versions
- **THEN** system SHALL:
  - Accept deprecated flags with warnings
  - Migrate old configuration patterns automatically
  - Provide upgrade guides for breaking changes
  - Support phased rollout of configuration changes
- **AND** configuration changes SHALL be documented in release notes

#### Scenario: Configuration templates

- **WHEN** providing deployment guidance
- **THEN** system SHALL include:
  - Configuration templates for common scenarios
  - Environment-specific configuration examples
  - Configuration validation scripts
  - Best practice recommendations
- **AND** templates SHALL be kept up-to-date with releases

### Requirement: Runtime Configuration

The system SHALL support limited runtime configuration changes.

#### Scenario: Dynamic reconfiguration

- **WHEN** changing configuration at runtime
- **THEN** system SHALL support:
  - Log level changes via signals (SIGHUP)
  - TLS certificate reload via signals
  - Metrics configuration changes
  - Connection limit adjustments
- **AND** runtime changes SHALL be atomic and safe

#### Scenario: Configuration persistence

- **WHEN** persisting configuration
- **THEN** the system SHALL:
  - Persist immutable format-time configuration in the superblock (cluster id, replica_count, format version, capacity limits)
  - Validate at startup that runtime CLI flags are compatible with the on-disk superblock configuration
  - Provide `--show-config` / `--dump-config` output for debugging (no export/import commands)
- **AND** ArcherDB remains CLI-only (no config files) per this specification

### Requirement: Environment-Specific Configuration

The system SHALL provide configuration patterns for different environments.

#### Scenario: Development configuration

- **WHEN** configuring for development
- **THEN** system SHALL provide:
  - Single-node cluster templates
  - Relaxed security defaults
  - Verbose logging and debugging features
  - Local filesystem storage paths
  - Quick startup configurations
- **AND** development configuration SHALL be marked with `[DEV]` prefix in configuration file and startup logs

#### Scenario: Production configuration

- **WHEN** configuring for production
- **THEN** system SHALL provide:
  - Multi-node cluster requirements
  - Security hardening defaults
  - Structured logging configuration
  - High availability settings
  - Performance optimization parameters
- **AND** production configuration SHALL require explicit safety confirmations

### Requirement: Configuration Debugging

The system SHALL provide tools for configuration troubleshooting.

#### Scenario: Configuration inspection

- **WHEN** debugging configuration issues
- **THEN** system SHALL provide:
  - `--dump-config` - Show parsed configuration
  - `--validate-config` - Check configuration validity
  - `--test-connectivity` - Test network connectivity
  - `--benchmark-config` - Performance test with current config
- **AND** debugging commands SHALL be safe to run on production systems

#### Scenario: Configuration documentation

- **WHEN** documenting configuration
- **THEN** system SHALL provide:
  - Comprehensive flag reference in documentation
  - Configuration examples for common scenarios
  - Troubleshooting guides for configuration issues
  - Performance tuning recommendations
- **AND** documentation SHALL be automatically generated from code

### Requirement: Graceful Shutdown Procedure

The system SHALL support graceful shutdown with proper resource cleanup and data safety guarantees.

#### Scenario: Shutdown signal handling

- **WHEN** the process receives SIGTERM or SIGINT
- **THEN** the system SHALL initiate graceful shutdown:
  1. Stop accepting new client connections
  2. Stop accepting new operations from existing connections
  3. Wait for in-flight operations to complete (up to `--shutdown-timeout`, default: 30 seconds)
  4. Complete any pending checkpoint
  5. Flush index checkpoint to disk
  6. Close all client connections
  7. Exit with code 0

#### Scenario: Shutdown component order

- **WHEN** graceful shutdown executes
- **THEN** components SHALL be stopped in this order:
  1. **Client listener** - Stop accepting new connections
  2. **Client sessions** - Drain in-flight requests
  3. **VSR protocol** - Stop sending/receiving replication messages
  4. **Backup thread** - Complete current upload, skip remaining queue
  5. **TTL cleanup thread** - Stop scan, record position
  6. **LSM compaction** - Complete current compaction or abort cleanly
  7. **Index checkpoint** - Write final checkpoint
  8. **Grid cache** - Flush dirty blocks
  9. **File handles** - Close data file with fsync

#### Scenario: Forced shutdown fallback

- **WHEN** graceful shutdown timeout expires (30 seconds default)
- **AND** operations are still in flight
- **THEN** the system SHALL:
  1. Log warning: "Graceful shutdown timeout - forcing exit"
  2. Abort in-flight operations (clients receive timeout error)
  3. Skip remaining cleanup steps
  4. Write emergency checkpoint if possible
  5. Exit with code 1

#### Scenario: Shutdown during view change

- **WHEN** shutdown is requested during view change
- **THEN** the system SHALL:
  - Wait for view change to complete (up to `view_change_timeout_ms`)
  - If view change completes: proceed with graceful shutdown
  - If view change times out: proceed with shutdown (cluster will elect new primary)
  - Log: "Shutting down during view change - other replicas will handle failover"

#### Scenario: Health endpoint during shutdown

- **WHEN** shutdown begins
- **THEN** health endpoints SHALL respond:
  - `/health/live` returns 200 (process still running)
  - `/health/ready` returns 503 (not accepting new requests)
- **AND** this allows load balancers to drain traffic gracefully

### Requirement: Rolling Upgrade Procedure

The system SHALL support zero-downtime rolling upgrades for version updates.

#### Scenario: Version compatibility requirements

- **WHEN** performing rolling upgrades
- **THEN** the following compatibility rules SHALL apply:
  - Replicas MAY differ by at most 1 minor version during upgrade
  - Wire protocol version MUST be backward compatible within major version
  - Data file format MUST be forward-compatible within major version
  - New features requiring new message types are disabled until all replicas upgraded
- **AND** version compatibility is checked on replica connection

#### Scenario: Rolling upgrade procedure

- **WHEN** upgrading a running cluster
- **THEN** the operator SHALL follow this procedure:
  1. **Pre-flight checks**:
     - Verify all replicas are healthy (`/health/ready` returns 200)
     - Verify cluster has quorum
     - Verify new version is compatible with current version
     - Create backup checkpoint (optional but recommended)
  2. **Upgrade backups first** (one at a time):
     - Select a backup replica (not the primary)
     - Send SIGTERM for graceful shutdown
     - Wait for replica to exit cleanly
     - Replace binary with new version
     - Start replica with same configuration
     - Wait for replica to sync and become healthy
     - Verify `/health/ready` returns 200
     - Repeat for remaining backup replicas
  3. **Upgrade primary last**:
     - Send SIGTERM to primary
     - Cluster automatically elects new primary (view change)
     - Wait for old primary to exit
     - Replace binary with new version
     - Start replica (joins as backup)
     - Wait for sync to complete
  4. **Post-upgrade verification**:
     - Verify all replicas on new version (`archerdb version`)
     - Verify cluster health metrics
     - Run smoke test queries

#### Scenario: Upgrade timing constraints

- **WHEN** planning upgrade timing
- **THEN** operators SHALL account for:
  - Per-replica upgrade time: ~30 seconds (shutdown + start + sync)
  - View change time: ~3 seconds (when upgrading primary)
  - Total 5-replica upgrade: ~3 minutes
  - Brief write unavailability during primary upgrade (~3 seconds)
- **AND** reads remain available throughout (from non-upgrading replicas)

#### Scenario: Upgrade rollback

- **WHEN** upgrade fails or causes issues
- **THEN** the operator SHALL:
  1. Stop the problematic replica
  2. Replace binary with previous version
  3. Start replica (it will sync from other replicas)
  4. If multiple replicas affected: rollback in reverse order
  5. If data format changed: restore from pre-upgrade backup
- **AND** rollback within minor version SHALL be safe
- **AND** rollback across major versions MAY require backup restore

#### Scenario: Canary upgrade pattern

- **WHEN** risk-averse upgrade is required
- **THEN** operators MAY use canary pattern:
  1. Upgrade single backup replica
  2. Monitor for 1-24 hours under production load
  3. Check error rates, latency, resource usage
  4. If healthy: proceed with remaining replicas
  5. If issues: rollback canary, investigate
- **AND** this extends upgrade window but reduces risk

#### Scenario: Version reporting

- **WHEN** checking cluster version status
- **THEN** `archerdb status` SHALL report:
  ```
  Cluster: abc123...
  Replicas:
    replica-0: v1.2.0 (primary, healthy)
    replica-1: v1.2.0 (backup, healthy)
    replica-2: v1.1.9 (backup, healthy, UPGRADE_PENDING)
  ```
- **AND** mixed-version state is highlighted
- **AND** upgrade completion is trackable

### Requirement: Emergency Runbooks

The system SHALL provide documented procedures for common emergency scenarios.

#### Scenario: Runbook - Quorum Loss

- **WHEN** the cluster cannot satisfy the configured quorums (e.g., fewer than `quorum_replication` active replicas available to commit, or fewer than `quorum_view_change` active replicas available to complete a view change)
- **THEN** the operator SHALL follow this runbook:
  1. **Assess situation**:
     - Check which replicas are down (`archerdb status` or metrics)
     - Determine cause (network partition, hardware failure, DC outage)
     - Check if partition is symmetric or asymmetric
  2. **If network partition**:
     - Identify which partition has more replicas
     - Restore network connectivity if possible
     - Cluster will automatically recover when partition heals
     - NO manual intervention needed if connectivity restored
  3. **If hardware failure (multiple replicas)**:
     - Determine `replica_count`, `quorum_replication`, and `quorum_view_change` for this cluster
     - With default 3-node majority-style quorums (2/3): if 2 of 3 replicas are down, the cluster is unavailable
     - With default 5-node majority-style quorums (3/5): if 2 of 5 replicas are down, the cluster can still commit (3/5); if 3 of 5 are down, it cannot
  4. **Emergency recovery (last resort)**:
     - If quorum cannot be restored AND data loss is acceptable:
     - Stop all replicas
     - Identify replica with highest `commit_max` (most recent data)
     - Reform cluster with surviving replicas
     - Accept potential data loss for uncommitted operations
  5. **Post-incident**:
     - Analyze root cause
     - Consider increasing replica count for better fault tolerance
     - Document incident timeline
- **CRITICAL**: Never force quorum with incomplete data unless data loss is acceptable

#### Scenario: Runbook - Primary Keeps Failing

- **WHEN** the primary replica repeatedly crashes or becomes unavailable
- **THEN** the operator SHALL follow this runbook:
  1. **Immediate assessment**:
     - Check primary logs for crash reason
     - Monitor view change frequency (`archerdb_vsr_view_changes_total`)
     - Identify if specific operations trigger crash
  2. **If resource exhaustion**:
     - Check memory usage (OOM killer?)
     - Check disk space
     - Check file descriptor limits
     - Scale resources or reduce load
  3. **If software bug**:
     - Collect crash dump and logs
     - Rollback to previous version if recently upgraded
     - Open bug report with reproduction steps
  4. **If hardware issue**:
     - Move primary to different hardware (let view change occur)
     - Replace faulty hardware
     - Rebuild replica from state sync
  5. **If specific workload**:
     - Identify problematic queries/operations
     - Temporarily block problematic clients
     - Fix application-level issue
  6. **Stabilization**:
     - Monitor for 15+ minutes after fix
     - Verify view changes stopped
     - Re-enable blocked clients gradually

#### Scenario: Runbook - Data Corruption Detected

- **WHEN** checksum mismatch or data corruption is detected
- **THEN** the operator SHALL follow this runbook:
  1. **Immediate actions**:
     - Note which replica detected corruption (from logs)
     - Note the block/offset with corruption
     - Do NOT restart the affected replica yet
  2. **Assess scope**:
     - Single replica affected → likely hardware/disk issue
     - Multiple replicas affected → likely software bug or attack
     - Check `archerdb_errors_total{error="checksum_mismatch"}` across replicas
  3. **If single replica corruption**:
     - Stop the corrupted replica
     - Delete its data file
     - Restart (will state sync from healthy replicas)
     - Replace hardware if disk failure suspected
  4. **If multiple replica corruption**:
     - STOP - this is a critical incident
     - Do not restart any replicas
     - Preserve all data files for forensic analysis
     - Restore from S3 backup to known good state
     - Contact support/file bug report
  5. **If corruption during writes**:
     - May indicate memory corruption (bad RAM)
     - Run hardware diagnostics (memtest86)
     - Replace affected hardware

#### Scenario: Runbook - Disk Full

- **WHEN** a replica runs out of disk space
- **THEN** the operator SHALL follow this runbook:
  1. **Immediate symptoms**:
     - Write operations fail with I/O errors
     - Replica may crash or become read-only
     - Check `archerdb_data_file_size_bytes` vs available space
  2. **Emergency space recovery**:
     - Delete old log files if present
     - Delete old checkpoint files (keep latest)
     - Clear temporary files
     - If backup enabled: clear old backup queue (data already in S3)
  3. **Force compaction** (if running):
     - Compaction reclaims space from deleted/expired events
     - Trigger explicit compaction: `archerdb admin compact --force`
     - Wait for compaction to complete
  4. **If still insufficient**:
     - Expand disk (if cloud/VM)
     - Move to larger disk (requires state sync)
     - Reduce TTL to expire more data faster
  5. **Prevention**:
     - Set up disk space alerting at 80%, 90%, 95%
     - Ensure disk has 20%+ headroom
     - Monitor `archerdb_data_file_size_bytes` growth rate

#### Scenario: Runbook - Backup Falling Behind

- **WHEN** backup lag exceeds acceptable threshold
- **THEN** the operator SHALL follow this runbook:
  1. **Assess backup lag**:
     - Check `archerdb_backup_lag_blocks` metric
     - Check `archerdb_backup_failures_total`
     - Check S3/network connectivity
  2. **If network issue**:
     - Test connectivity to S3 endpoint
     - Check for DNS resolution issues
     - Check for firewall/security group changes
     - Restore connectivity
  3. **If S3 throttling**:
     - Check S3 request rate limits
     - Consider S3 bucket in different region
     - Enable S3 transfer acceleration
  4. **If backup too slow**:
     - Enable compression (`--backup-compress=zstd`)
     - Increase network bandwidth
     - Consider backup only from primary (reduces redundancy)
  5. **If queue overflow imminent**:
     - Monitor `backup_queue_hard_limit` (200 blocks)
     - If exceeded: system may release blocks without backup
     - Accept temporary backup gap, fix underlying issue
  6. **Recovery after incident**:
     - Backup will automatically catch up when issue resolved
     - Verify no gaps in backup sequence
     - Consider manual full backup if gaps detected

#### Scenario: Runbook - Certificate Expiration

- **WHEN** TLS certificates are expiring or have expired
- **THEN** the operator SHALL follow this runbook:
  1. **If certificates not yet expired**:
     - Generate new certificates with extended validity
     - Follow Zero-Downtime Certificate Rotation procedure
     - Rotate all replicas before expiration
  2. **If certificates already expired**:
     - New connections will fail (TLS handshake failure)
     - Existing connections may continue working
     - Priority: rotate certificates immediately
  3. **Emergency rotation**:
     - Generate new certificates
     - Stop replica, replace certs, start replica
     - Accept brief downtime for affected replica
     - Repeat for all replicas (parallel if needed)
  4. **If cluster completely down**:
     - Replace certificates on all replicas
     - Start replicas (they will reform cluster)
     - Brief cluster-wide unavailability
  5. **Prevention**:
     - Set up certificate expiration alerting (30 days, 7 days, 1 day)
     - Automate certificate renewal (cert-manager, ACME)
     - Use certificates with reasonable validity (90-365 days)

#### Scenario: Runbook - Memory Exhaustion

- **WHEN** a replica is running out of memory
- **THEN** the operator SHALL follow this runbook:
  1. **Symptoms**:
     - OOM killer terminates process
     - Replica becomes unresponsive
     - `archerdb_memory_used_bytes` approaching limit
  2. **Immediate mitigation**:
     - Reduce `--max-concurrent-queries` to limit query memory
     - Reduce connection limits
     - Kill long-running queries if possible
  3. **Diagnose cause**:
     - Large query results consuming memory?
     - Index growth exceeding allocation?
     - Memory leak (check version, report bug)?
  4. **If index too large**:
     - Index size = entity_count × 64 bytes
     - 1B entities = ~91.5GB index (128GB RAM recommended)
     - Consider TTL to reduce active entities
     - Consider sharding (multiple clusters)
  5. **Long-term fix**:
     - Increase server RAM
     - Right-size based on expected entity count
     - Set up memory alerting at 80%, 90% usage

### Related Specifications

- See `specs/constants/spec.md` for all default configuration values and compile-time constants
- See `specs/replication/spec.md` for cluster configuration (replica_count, quorums)
- See `specs/security/spec.md` for TLS configuration flags and certificate paths
- See `specs/observability/spec.md` for metrics endpoint and logging configuration
- See `specs/error-codes/spec.md` for configuration validation error codes
