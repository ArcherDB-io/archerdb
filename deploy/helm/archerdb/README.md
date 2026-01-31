# ArcherDB Helm Chart

A Helm chart for deploying ArcherDB, a distributed geospatial database for real-time location tracking.

## Prerequisites

- Kubernetes 1.24+
- Helm 3.x
- PersistentVolume provisioner support in the underlying infrastructure
- (Optional) Prometheus Operator for ServiceMonitor and alerting

## Quick Start

```bash
# Add the helm repository (if published)
# helm repo add archerdb https://charts.archerdb.io

# Install with default values (development/staging)
helm install archerdb ./deploy/helm/archerdb

# Check deployment status
kubectl get pods -l app.kubernetes.io/name=archerdb
```

## Production Deployment

For production deployments, use the production values overlay:

```bash
helm install archerdb ./deploy/helm/archerdb \
  -f ./deploy/helm/archerdb/values-production.yaml \
  --namespace archerdb \
  --create-namespace
```

## Configuration

### Core Settings

| Parameter | Description | Default |
|-----------|-------------|---------|
| `replicaCount` | Number of ArcherDB replicas (minimum 3 for production) | `3` |
| `image.repository` | Container image repository | `archerdb/archerdb` |
| `image.tag` | Container image tag (defaults to Chart appVersion) | `""` |
| `image.pullPolicy` | Image pull policy | `IfNotPresent` |

### Resource Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `resources.requests.cpu` | CPU request | `1000m` |
| `resources.requests.memory` | Memory request | `2Gi` |
| `resources.limits.cpu` | CPU limit | `4000m` |
| `resources.limits.memory` | Memory limit | `8Gi` |

### Storage Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `storage.size` | Persistent volume size per replica | `10Gi` |
| `storage.storageClassName` | Storage class name (empty = cluster default) | `""` |
| `storage.accessModes` | PVC access modes | `[ReadWriteOnce]` |

### ArcherDB Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `config.clusterId` | Cluster ID (all replicas must match) | `0` |
| `config.development` | Enable development mode (disable for production) | `true` |
| `config.cacheGridSize` | Grid cache size for spatial index | `256MiB` |
| `config.connectTimeoutMs` | Connection timeout in milliseconds | `5000` |
| `config.requestTimeoutMs` | Request timeout in milliseconds | `30000` |

### Network Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `ports.client` | Client API port | `3000` |
| `ports.metrics` | Prometheus metrics port | `9100` |

### Pod Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `terminationGracePeriodSeconds` | Graceful shutdown timeout | `60` |
| `podAntiAffinity.enabled` | Enable pod anti-affinity | `true` |
| `podAntiAffinity.weight` | Anti-affinity weight (1-100) | `100` |
| `pdb.enabled` | Create PodDisruptionBudget | `true` |
| `pdb.minAvailable` | Minimum available pods during disruptions | `2` |
| `nodeSelector` | Node selector for pod scheduling | `{}` |
| `tolerations` | Tolerations for pod scheduling | `[]` |

### Metrics Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `metrics.enabled` | Enable Prometheus metrics endpoint | `true` |
| `metrics.serviceMonitor.enabled` | Create ServiceMonitor resource | `false` |
| `metrics.serviceMonitor.interval` | Scrape interval | `15s` |
| `metrics.alerts.enabled` | Create PrometheusRule resource | `false` |
| `metrics.alerts.latencyP99WarningMs` | P99 latency warning threshold | `25` |
| `metrics.alerts.latencyP99CriticalMs` | P99 latency critical threshold | `100` |

### Health Probes

| Parameter | Description | Default |
|-----------|-------------|---------|
| `probes.liveness.initialDelaySeconds` | Liveness probe initial delay | `60` |
| `probes.liveness.periodSeconds` | Liveness probe period | `30` |
| `probes.readiness.initialDelaySeconds` | Readiness probe initial delay | `30` |
| `probes.readiness.periodSeconds` | Readiness probe period | `10` |

## Upgrading

```bash
# Upgrade to new version
helm upgrade archerdb ./deploy/helm/archerdb

# Upgrade with production values
helm upgrade archerdb ./deploy/helm/archerdb \
  -f ./deploy/helm/archerdb/values-production.yaml
```

### Upgrade Notes

- **PVCs are retained** by default (helm.sh/resource-policy: keep annotation)
- Rolling updates are performed with OrderedReady pod management
- Allow sufficient time for graceful VSR consensus handoff between replicas

## Uninstalling

```bash
helm uninstall archerdb
```

**Important:** PersistentVolumeClaims are **not** deleted when uninstalling to prevent data loss. To completely remove all data:

```bash
# Delete PVCs manually after uninstall
kubectl delete pvc -l app.kubernetes.io/name=archerdb
```

## Examples

### Custom Replica Count

```yaml
# values-5-node.yaml
replicaCount: 5
```

### High-Memory Configuration

```yaml
# values-highmem.yaml
resources:
  requests:
    memory: "8Gi"
  limits:
    memory: "32Gi"
config:
  cacheGridSize: "4GiB"
```

### Using Specific Storage Class

```yaml
# values-aws.yaml
storage:
  size: "500Gi"
  storageClassName: "gp3"
```

### Enable Full Monitoring Stack

```yaml
# values-monitoring.yaml
metrics:
  enabled: true
  serviceMonitor:
    enabled: true
    interval: "15s"
  alerts:
    enabled: true
    latencyP99WarningMs: 25
    latencyP99CriticalMs: 100
    diskWarningPercent: 80
    diskCriticalPercent: 90
```

## Troubleshooting

### Pods Not Starting

1. Check events: `kubectl describe pod archerdb-0`
2. Verify storage class exists: `kubectl get storageclass`
3. Check PVC status: `kubectl get pvc -l app.kubernetes.io/name=archerdb`

### High Latency

1. Check metrics: `kubectl port-forward svc/archerdb 9100:9100`
2. Review Grafana dashboards (if deployed)
3. Consider increasing resources or cache size

### Cluster Not Forming

1. Verify all 3 pods are running
2. Check DNS resolution: `kubectl exec archerdb-0 -- nslookup archerdb-headless`
3. Review logs: `kubectl logs archerdb-0`

## Documentation

- [Operations Runbook](../../../docs/operations-runbook.md)
- [ArcherDB Documentation](https://github.com/archerdb/archerdb)

## License

Apache License 2.0
