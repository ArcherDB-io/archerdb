# Phase 8: Operations Tooling - Research

**Researched:** 2026-01-31
**Domain:** Production deployment, upgrades, backup, disaster recovery (Kubernetes, Helm, CDC)
**Confidence:** HIGH

## Summary

This phase focuses on operationalizing ArcherDB for production environments. The research covers Kubernetes deployment patterns (both raw manifests and Helm charts), rolling upgrade procedures with automatic rollback, continuous backup using CDC patterns, and disaster recovery procedures. ArcherDB follows the TigerBeetle deployment philosophy: a single static binary that runs anywhere without dependencies.

The codebase already has substantial infrastructure in place:
- Docker and Docker Compose for development clusters (`deploy/Dockerfile`, `deploy/docker-compose.dev.yml`)
- Basic Kubernetes manifests with StatefulSet, Services, and ServiceMonitor (`deploy/k8s/`)
- Health endpoints (`/health/live`, `/health/ready`, `/health/detailed`)
- Prometheus metrics with 252 metric definitions
- Backup infrastructure with S3/GCS/Azure/local support (`backup_config.zig`, `backup_coordinator.zig`)
- Comprehensive disaster recovery and operations runbook documentation

**Primary recommendation:** Build on existing infrastructure - extend k8s manifests for production, add Helm chart with proper values organization, implement upgrade CLI tooling with health-based rollback, and enhance CDC backup to meet zero-traffic-impact requirements.

## Standard Stack

### Core Deployment Tools

| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| Kubernetes | 1.24+ | Container orchestration | Industry standard, StatefulSet for databases |
| Helm | 3.x | Package management | Values templating, dependency management, rollback |
| Prometheus Operator | Latest | Monitoring | ServiceMonitor CRDs, alerting rules |
| KEDA | 2.18+ | Autoscaling | Custom metrics, database scalers, scale-to-zero |

### Supporting Tools

| Tool | Version | Purpose | When to Use |
|------|---------|---------|-------------|
| Docker | 24+ | Container runtime | Local development, CI builds |
| kubectl | 1.24+ | K8s CLI | Manual operations, debugging |
| helm-diff | 3.x | Diff before apply | Production change review |
| promtool | 2.x | Rule validation | CI validation of alerting rules |

### Already Implemented in Codebase

| Component | Location | Status |
|-----------|----------|--------|
| Dockerfile | `deploy/Dockerfile` | Multi-stage build, non-root user |
| Docker Compose | `deploy/docker-compose.dev.yml` | 3-node cluster for dev |
| K8s StatefulSet | `deploy/k8s/statefulset.yaml` | Basic 3-replica setup |
| K8s ConfigMap | `deploy/k8s/configmap.yaml` | Cluster configuration |
| ServiceMonitor | `deploy/k8s/servicemonitor.yaml` | Prometheus integration |
| Health endpoints | `src/archerdb/metrics_server.zig` | /health/live, /health/ready |
| Backup config | `src/archerdb/backup_config.zig` | S3/GCS/Azure/local providers |
| Backup coordinator | `src/archerdb/backup_coordinator.zig` | Primary-only or all-replica modes |
| Operations runbook | `docs/operations-runbook.md` | Comprehensive ops guide |
| Disaster recovery | `docs/disaster-recovery.md` | Recovery procedures |
| Capacity planning | `docs/capacity-planning.md` | Sizing guidelines |

## Architecture Patterns

### Recommended Helm Chart Structure

```
deploy/helm/archerdb/
├── Chart.yaml              # Chart metadata, version, dependencies
├── values.yaml             # Default values (documented)
├── values-production.yaml  # Production overrides
├── templates/
│   ├── _helpers.tpl        # Template helpers
│   ├── statefulset.yaml    # StatefulSet with PodDisruptionBudget
│   ├── service.yaml        # Headless + client services
│   ├── configmap.yaml      # Configuration
│   ├── secrets.yaml        # Sensitive config (optional)
│   ├── servicemonitor.yaml # Prometheus ServiceMonitor
│   ├── prometheusrule.yaml # Alerting rules
│   ├── hpa.yaml            # HorizontalPodAutoscaler (optional)
│   ├── keda.yaml           # KEDA ScaledObject (optional)
│   └── NOTES.txt           # Post-install notes
└── README.md               # Usage documentation
```

### Pattern 1: StatefulSet with OrderedReady

**What:** StatefulSet with `podManagementPolicy: OrderedReady` for ordered startup/shutdown
**When to use:** Always for ArcherDB (required for VSR consensus)
**Source:** [Kubernetes StatefulSet docs](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/)

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{ include "archerdb.fullname" . }}
spec:
  serviceName: {{ include "archerdb.fullname" . }}-headless
  replicas: {{ .Values.replicaCount }}
  podManagementPolicy: OrderedReady  # Required for consensus
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      partition: 0  # Can be used for canary
  selector:
    matchLabels:
      {{- include "archerdb.selectorLabels" . | nindent 6 }}
  template:
    spec:
      terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds | default 60 }}
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    {{- include "archerdb.selectorLabels" . | nindent 20 }}
                topologyKey: kubernetes.io/hostname
```

### Pattern 2: Rolling Update with Partitioned Rollout

**What:** Use partition-based updates for canary deployments
**When to use:** Production upgrades requiring validation between nodes
**Source:** [Kubernetes StatefulSet updates](https://kubernetes.io/docs/tutorials/stateful-application/basic-stateful-set/)

```bash
# Partition at 2 means only pod-2 gets updated first
kubectl patch statefulset archerdb -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":2}}}}'

# After validation, partition at 1 to update pod-1
kubectl patch statefulset archerdb -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":1}}}}'

# Finally, partition at 0 to update all (including pod-0/primary)
kubectl patch statefulset archerdb -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":0}}}}'
```

### Pattern 3: Health-Based Rollback Triggers

**What:** Monitor health probes and metrics, auto-rollback on degradation
**When to use:** Automated upgrade procedures
**Context decision:** Rollback on health probe failures OR P99 doubles OR error rate > threshold

```yaml
# KEDA-based upgrade controller (conceptual)
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: archerdb-upgrade-monitor
spec:
  scaleTargetRef:
    name: archerdb
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://prometheus:9090
        metricName: archerdb_upgrade_health
        query: |
          (1 - (sum(up{job="archerdb"}) / 3)) > 0.33
          or histogram_quantile(0.99, rate(archerdb_request_duration_seconds_bucket[5m])) > 0.2
        threshold: "1"
```

### Pattern 4: CDC-Based Continuous Backup

**What:** Stream WAL changes to object storage in near-real-time
**When to use:** Zero-RPO backup requirement
**Context decision:** Read from follower replica, never primary (zero traffic impact)
**Source:** [CDC best practices](https://www.redpanda.com/guides/fundamentals-of-data-engineering-cdc-change-data-capture)

Existing backup infrastructure supports:
- `backup_mode: best_effort` - Async, prioritize availability
- `backup_mode: mandatory` - Require backup before block release
- `backup_primary_only: true` - Only primary uploads (reduce storage costs)
- `backup_primary_only: false` - All replicas backup (maximum redundancy)

### Anti-Patterns to Avoid

- **Termination grace period of 0:** Unsafe for databases, always use >= 30s
- **RollingUpdate without health checks:** Must validate each pod before continuing
- **Single replica for production:** Minimum 3 replicas for fault tolerance
- **Shared PVC across replicas:** Each replica needs its own PersistentVolume
- **Scaling primary directly:** Only scale read replicas, not write replicas

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Kubernetes deployment | Raw kubectl scripts | Helm chart | Version tracking, rollback, templating |
| Pod autoscaling on custom metrics | Custom controller | KEDA with Prometheus trigger | Maintains HPA, scales to zero |
| Service mesh / mTLS | Custom TLS termination | Existing `/health/*` endpoints | Already implemented |
| Metrics exposition | Custom metrics format | Existing Prometheus metrics | 252 metrics already defined |
| Health probes | Custom health check scripts | Existing `/health/live`, `/health/ready` | Already Kubernetes-compliant |
| Alerting rules | Custom alerting system | Existing PrometheusRule CRDs | 29 rules already defined |
| Backup to S3 | Custom S3 client | Existing backup_config.zig | Multi-provider support exists |
| CDC streaming | Custom WAL reader | Existing backup infrastructure | Backup coordinator handles this |

**Key insight:** The codebase already has ~80% of the operations infrastructure. This phase is about packaging (Helm), automation (upgrade CLI), and documentation (runbooks).

## Common Pitfalls

### Pitfall 1: Upgrading Primary Before Followers

**What goes wrong:** Primary is upgraded first, triggering unnecessary view changes and potential unavailability
**Why it happens:** Default StatefulSet rolling update goes high-to-low ordinal (2, 1, 0), but primary may not be pod-0
**How to avoid:** Always identify current primary first, upgrade followers first, primary last
**Warning signs:** Multiple view changes during upgrade, `archerdb_view_changes_total` metric spikes

```bash
# Identify primary before upgrade
kubectl exec archerdb-0 -- curl -s localhost:9100/metrics | grep archerdb_replica_role
```

### Pitfall 2: PVC Deletion on StatefulSet Delete

**What goes wrong:** `kubectl delete statefulset archerdb` deletes PVCs, causing data loss
**Why it happens:** Default Kubernetes behavior without `helm.sh/resource-policy: keep`
**How to avoid:** Add resource policy annotation to PVC template
**Warning signs:** PVCs disappear after helm uninstall

```yaml
volumeClaimTemplates:
  - metadata:
      name: data
      annotations:
        helm.sh/resource-policy: keep  # Prevent deletion on uninstall
```

### Pitfall 3: Backup Queue Exhaustion in Mandatory Mode

**What goes wrong:** Writes halt because backup queue is full
**Why it happens:** S3 outage or slow network + mandatory mode + high write volume
**How to avoid:**
- Use disk spillover (already supported)
- Monitor `archerdb_backup_queue_size` metric
- Set appropriate `backup_queue_soft_limit` and `backup_queue_hard_limit`
**Warning signs:** `archerdb_backup_queue_size` approaching hard limit

### Pitfall 4: Insufficient Termination Grace Period

**What goes wrong:** In-flight requests are dropped during rolling updates
**Why it happens:** `terminationGracePeriodSeconds` too short for VSR commit
**How to avoid:** Set to at least 60 seconds (already in existing manifests)
**Warning signs:** Request errors during rolling restarts

### Pitfall 5: Upgrade Without Backup Verification

**What goes wrong:** Upgrade fails, rollback attempted, but backup is stale or corrupt
**Why it happens:** Backup not verified before upgrade
**How to avoid:** Pre-upgrade checklist must include backup verification
**Warning signs:** Unable to restore after failed upgrade

## Code Examples

### Helm Values Organization (Best Practice)

```yaml
# values.yaml - flat structure, well-documented
# Source: https://helm.sh/docs/chart_best_practices/values/

# replicaCount - Number of ArcherDB replicas (minimum 3 for production)
replicaCount: 3

# image - Container image configuration
image:
  repository: archerdb/archerdb
  tag: ""  # Defaults to Chart.appVersion
  pullPolicy: IfNotPresent

# resources - Resource requests and limits
resources:
  requests:
    memory: 2Gi
    cpu: 1000m
  limits:
    memory: 8Gi
    cpu: 4000m

# storage - Persistent volume configuration
storage:
  size: 10Gi
  storageClass: ""  # Use default if empty

# metrics - Prometheus metrics configuration
metrics:
  enabled: true
  port: 9100
  serviceMonitor:
    enabled: true
    interval: 15s

# backup - Backup configuration
backup:
  enabled: false
  provider: s3  # s3, gcs, azure, local
  bucket: ""
  region: ""
  mode: best-effort  # best-effort, mandatory
  retentionDays: 30

# upgrade - Rolling upgrade configuration
upgrade:
  healthCheckInterval: 10s
  healthCheckRetries: 3
  rollbackOnFailure: true
  p99LatencyThreshold: 200ms
  errorRateThreshold: 0.01
```

### KEDA ScaledObject for Custom Metrics

```yaml
# Source: https://keda.sh/docs/2.18/concepts/scaling-deployments/
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: archerdb-autoscaler
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: StatefulSet
    name: archerdb
  minReplicaCount: 3
  maxReplicaCount: 6
  pollingInterval: 30
  cooldownPeriod: 300
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://prometheus:9090
        metricName: archerdb_connections_active
        query: sum(archerdb_connections_active{job="archerdb"})
        threshold: "1000"
  fallback:
    failureThreshold: 3
    replicas: 3
```

### Upgrade CLI Skeleton

```zig
// Conceptual - upgrade command structure
const Upgrade = struct {
    addresses: []const u8,
    target_version: []const u8,
    dry_run: bool = false,
    skip_backup_check: bool = false,
    pause_on_failure: bool = true,
    p99_threshold_ms: u64 = 200,
    error_rate_threshold: f64 = 0.01,
    health_check_interval_ms: u64 = 10_000,
    health_check_retries: u32 = 3,
};

// Upgrade workflow:
// 1. Pre-flight checks (backup verified, all replicas healthy)
// 2. Identify primary vs followers
// 3. Upgrade followers one at a time (wait for catch-up)
// 4. Monitor health metrics after each node
// 5. Pause/rollback if thresholds exceeded
// 6. Upgrade primary last (triggers view change)
// 7. Post-upgrade verification
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Manual kubectl apply | Helm with values overlays | Helm 3 (2019) | Version tracking, atomic rollback |
| HPA with CPU only | KEDA with custom metrics | KEDA 2.0 (2021) | Database-aware scaling |
| Full backups | CDC streaming | Industry standard | Near-zero RPO |
| Manual runbooks | GitOps + automated DR | 2023+ | Reproducible recovery |

**Deprecated/outdated:**
- **Kubernetes 1.23 and below:** StatefulSet spec changes, use 1.24+
- **Helm 2.x:** Tiller removed, use Helm 3
- **Manual service discovery:** Use headless service DNS

## Open Questions

### 1. HPA vs KEDA for StatefulSet Autoscaling

- **What we know:** KEDA supports StatefulSet scaling and Prometheus triggers
- **What's unclear:** Whether horizontal scaling makes sense for ArcherDB write path (consensus quorum)
- **Recommendation:** Implement KEDA for read replicas only; write quorum is fixed at 3 (or 5/6)

### 2. CDC Implementation Detail

- **What we know:** Backup infrastructure exists, supports streaming blocks to S3
- **What's unclear:** Exact mechanism to ensure follower-only reads for zero traffic impact
- **Recommendation:** Verify `backup_coordinator.zig` can be configured to use follower; may need enhancement

### 3. Version Compatibility Matrix

- **What we know:** TigerBeetle model specifies oldest compatible source version
- **What's unclear:** ArcherDB's current version compatibility implementation
- **Recommendation:** Document version compatibility in Phase 8, test upgrade N to N+1

## Sources

### Primary (HIGH confidence)

- **Codebase inspection** - `deploy/`, `src/archerdb/`, `docs/`, `observability/`
- [Kubernetes StatefulSet docs](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/) - Rolling updates, ordering guarantees
- [Helm Best Practices](https://helm.sh/docs/chart_best_practices/) - Values organization, templates

### Secondary (MEDIUM confidence)

- [KEDA documentation](https://keda.sh/docs/2.18/concepts/scaling-deployments/) - StatefulSet support, Prometheus triggers
- [TigerBeetle deployment guide](https://docs.tigerbeetle.com/operating/deploying/) - Single binary philosophy, 6-replica production
- [CDC best practices](https://www.redpanda.com/guides/fundamentals-of-data-engineering-cdc-change-data-capture) - WAL streaming patterns

### Tertiary (LOW confidence)

- WebSearch for "Kubernetes StatefulSet rolling update best practices" - Community patterns
- WebSearch for "Helm chart database deployment best practices" - Common conventions

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Based on codebase inspection and official Kubernetes/Helm docs
- Architecture: HIGH - Patterns verified against existing implementation
- Pitfalls: HIGH - Based on TigerBeetle docs and database best practices
- HPA/KEDA: MEDIUM - Depends on specific ArcherDB write path constraints

**Research date:** 2026-01-31
**Valid until:** 2026-03-01 (30 days - Kubernetes/Helm ecosystem relatively stable)
