# Capacity Planning Guide

This guide helps you size ArcherDB deployments for your expected workload.

## Table of Contents

- [Quick Reference](#quick-reference)
- [Memory Planning](#memory-planning)
- [Disk Planning](#disk-planning)
- [Hardware Recommendations](#hardware-recommendations)
- [Scaling Scenarios](#scaling-scenarios)
- [Monitoring Capacity](#monitoring-capacity)
- [Growth Planning](#growth-planning)

## Quick Reference

### Memory Requirements

| Entity Count | Index Memory | Recommended RAM | Minimum RAM |
|--------------|--------------|-----------------|-------------|
| 1 Million | ~92 MB | 4 GB | 2 GB |
| 10 Million | ~915 MB | 8 GB | 4 GB |
| 100 Million | ~9.15 GB | 32 GB | 16 GB |
| 500 Million | ~45.7 GB | 96 GB | 64 GB |
| 1 Billion | ~91.5 GB | 128 GB | 96 GB |

### Disk Requirements (Latest Position Only)

| Entity Count | Data Size | With 5x History | With 10x History |
|--------------|-----------|-----------------|------------------|
| 1 Million | 128 MB | 640 MB | 1.28 GB |
| 10 Million | 1.28 GB | 6.4 GB | 12.8 GB |
| 100 Million | 12.8 GB | 64 GB | 128 GB |
| 1 Billion | 128 GB | 640 GB | 1.28 TB |

## Memory Planning

### Index Memory Formula

ArcherDB maintains a RAM index for O(1) entity lookups. The index entry size is **64 bytes** (cache-line aligned).

```
Index Memory = (Entity Count / Load Factor) × 64 bytes

Where:
- Target Load Factor = 0.70 (70% capacity utilization)
- 64 bytes = IndexEntry size (cache-line aligned for performance)
```

**Example for 1 billion entities:**
```
Capacity = 1,000,000,000 / 0.70 = ~1,428,571,428 slots
Memory = 1,428,571,428 × 64 bytes = ~91.5 GB
```

### RAM Allocation Breakdown

For a 128 GB system targeting 1 billion entities:

| Component | Allocation | Purpose |
|-----------|------------|---------|
| Primary Index | ~92 GB | O(1) entity lookups |
| Block Cache | 4-16 GB | LSM tree read caching |
| Query Buffers | 1-2 GB | Result set assembly |
| VSR Buffers | 1-2 GB | Replication pipeline |
| Operating System | 8-16 GB | Kernel, page cache |

### Memory Headroom Requirements

Always provision more RAM than the raw index size:

```
Recommended RAM = Index Memory × 1.4

Reasons:
- Hash table performance degrades near capacity
- Memory fragmentation overhead
- Operating system buffers
- Query result buffers
- Grid cache for frequently accessed blocks
```

### Large Page Support

For optimal performance with large indexes:

```bash
# Enable Transparent Huge Pages (Linux)
echo always > /sys/kernel/mm/transparent_hugepage/enabled

# Or allocate explicit huge pages (2MB pages)
# For 100GB index, allocate 51,200 huge pages
echo 51200 > /proc/sys/vm/nr_hugepages
```

Large pages reduce TLB misses during random index access.

## Disk Planning

### GeoEvent Storage

Each GeoEvent record is **128 bytes**:

```
Disk Space (Latest Only) = Entity Count × 128 bytes
```

### Historical Retention Multiplier

Disk usage increases based on how often entities are updated:

| Workload Type | Updates per Entity | Example | Storage Multiplier |
|---------------|-------------------|---------|-------------------|
| Low frequency | 1-5 updates | Asset tracking | 1-5× |
| Medium frequency | 5-20 updates | Fleet management | 5-20× |
| High frequency | 20+ updates | Real-time delivery | 20-50× |

**Example calculations for 1 billion entities:**

```
Low frequency (monthly position updates):
  128GB × 5 = 640 GB SSD required

Medium frequency (hourly updates):
  128GB × 10 = 1.28 TB SSD required

High frequency (every 30 seconds):
  128GB × 30 = 3.84 TB SSD required
```

### TTL and Disk Reclamation

If using TTL (time-to-live) for automatic data expiration:

```
Effective Storage = (Event Rate × TTL Duration) × 128 bytes
```

**Example:**
```
Event Rate: 10,000 events/second
TTL: 30 days (2,592,000 seconds)

Effective Storage = 10,000 × 2,592,000 × 128 bytes
                 = 3.32 TB
```

### Disk Performance Requirements

| Workload | Sequential Read | Random Read | Sequential Write |
|----------|-----------------|-------------|------------------|
| Development | >500 MB/s | >10K IOPS | >200 MB/s |
| Production | >2 GB/s | >50K IOPS | >1 GB/s |
| High Performance | >5 GB/s | >100K IOPS | >3 GB/s |

**Recommended:** NVMe SSDs with >3 GB/s sequential read for production workloads.

### Data File Size Limits

```
Maximum data file size: 16 TB
Maximum events per file: ~137 billion (at 128 bytes each)
```

## Hardware Recommendations

### Development Environment

For development and testing (up to 300 million entities):

| Component | Specification |
|-----------|---------------|
| CPU | 8 cores, x86-64 with AES-NI |
| RAM | 32 GB |
| Disk | 500 GB NVMe SSD |
| Network | 1 Gbps |

### Production (1 Billion Entities)

For production deployments targeting 1 billion entities:

| Component | Specification |
|-----------|---------------|
| CPU | 16+ cores, x86-64 with AVX2 |
| RAM | 128 GB (ECC recommended) |
| Disk | 1 TB+ NVMe SSD (3+ GB/s) |
| Network | 10 Gbps between replicas |

### High Performance (>1M Events/sec)

For maximum throughput requirements:

| Component | Specification |
|-----------|---------------|
| CPU | 32+ cores, Intel Sapphire Rapids or AMD Zen 4 |
| RAM | 256 GB (ECC required) |
| Disk | 2 TB+ NVMe Gen4/Gen5 (5+ GB/s) |
| Network | 25-100 Gbps |

### CPU Features Required

- **AES-NI**: Required for Aegis-128L checksumming
- **AVX2**: Improves SIMD operations (recommended)
- **RDTSCP**: Timestamp counter for profiling

## Scaling Scenarios

### Scenario 1: Fleet Management (100K Vehicles)

```
Entities: 100,000 vehicles
Update frequency: Every 10 seconds
Retention: 90 days

Memory:
  Index = (100,000 / 0.7) × 64 = ~9.1 MB
  Recommended RAM: 4 GB

Disk:
  Events/day = 100,000 × 8,640 = 864M events
  90-day retention = 77.8B events × 128 bytes = ~10 TB
  Recommended: 12 TB NVMe SSD

Throughput:
  Write rate = 100,000 / 10 = 10,000 events/sec
  Single replica sufficient
```

### Scenario 2: Mobile App (10M Users)

```
Entities: 10,000,000 users
Update frequency: Every 60 seconds (when app active)
Active ratio: 10% at any time
Retention: 7 days

Memory:
  Index = (10,000,000 / 0.7) × 64 = ~915 MB
  Recommended RAM: 8 GB

Disk:
  Active users: 1,000,000
  Events/day = 1,000,000 × 1,440 = 1.44B events
  7-day retention = 10.1B events × 128 bytes = ~1.3 TB
  Recommended: 2 TB NVMe SSD

Throughput:
  Peak write rate = 1,000,000 / 60 = ~16,700 events/sec
  3-replica cluster recommended
```

### Scenario 3: IoT Platform (100M Devices)

```
Entities: 100,000,000 devices
Update frequency: Varies (1 min to 1 hour)
Average: 15-minute intervals
Retention: 30 days

Memory:
  Index = (100,000,000 / 0.7) × 64 = ~9.15 GB
  Recommended RAM: 32 GB

Disk:
  Events/day = 100,000,000 × 96 = 9.6B events
  30-day retention = 288B events × 128 bytes = ~37 TB
  Data tiering required (recent on NVMe, archived on HDD/S3)

Throughput:
  Average write rate = 100,000,000 / 900 = ~111,000 events/sec
  5-replica cluster with sharding
```

### Scenario 4: Global Logistics (1B Shipments)

```
Entities: 1,000,000,000 shipments (cumulative)
Active: 50,000,000 in-transit
Update frequency: Every 5 minutes when moving
Retention: Indefinite for audit

Memory:
  Index = (1,000,000,000 / 0.7) × 64 = ~91.5 GB
  Recommended RAM: 128 GB per node

Disk:
  Active events/day = 50,000,000 × 288 = 14.4B events
  Plus completions: ~10M/day
  Growing storage: ~1.8 TB/day
  Multi-region with S3 archival required

Throughput:
  Write rate = 50,000,000 / 300 = ~166,000 events/sec
  Multi-region deployment with geo-sharding
```

## Monitoring Capacity

### Key Metrics to Watch

| Metric | Warning | Critical | Action |
|--------|---------|----------|--------|
| `archerdb_index_load_factor` | > 0.6 | > 0.75 | Scale or rebuild |
| `archerdb_disk_usage_bytes` | > 70% | > 85% | Add storage |
| `archerdb_memory_usage_bytes` | > 75% | > 90% | Add RAM or scale |
| `archerdb_index_tombstone_ratio` | > 0.1 | > 0.3 | Schedule rebuild |

### Prometheus Alerts

```yaml
groups:
  - name: archerdb_capacity
    rules:
      # Index approaching capacity
      - alert: IndexCapacityWarning
        expr: archerdb_index_load_factor > 0.6
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Index load factor {{ $value | humanizePercentage }}"
          action: "Plan capacity increase within 2 weeks"

      - alert: IndexCapacityCritical
        expr: archerdb_index_load_factor > 0.75
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Index at critical capacity"
          action: "Immediate action required"

      # Disk space
      - alert: DiskSpaceWarning
        expr: archerdb_disk_usage_bytes / archerdb_disk_total_bytes > 0.7
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "Disk usage {{ $value | humanizePercentage }}"
          action: "Plan storage expansion"

      - alert: DiskSpaceCritical
        expr: archerdb_disk_usage_bytes / archerdb_disk_total_bytes > 0.85
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Disk critically low"
          action: "Immediate storage expansion required"

      # Memory
      - alert: MemoryWarning
        expr: archerdb_memory_usage_bytes / node_memory_total_bytes > 0.75
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Memory usage {{ $value | humanizePercentage }}"
```

### Capacity Dashboard

Create a Grafana dashboard showing:

1. **Current vs. Maximum Capacity**
   - Entity count / max entities
   - Disk used / disk available
   - Memory used / memory available

2. **Growth Trends**
   - Entity count over 30 days
   - Disk growth rate (GB/day)
   - Event ingestion rate

3. **Resource Efficiency**
   - Index load factor
   - Query latency trends
   - Compaction throughput

4. **Projected Exhaustion**
   - Days until 80% index capacity
   - Days until 90% disk capacity
   - Required expansion timeline

## Growth Planning

### Capacity Planning Worksheet

Use this worksheet when planning deployments:

```
1. Entity Estimation
   ─────────────────
   Current entities:      ____________
   Growth rate/month:     ____________ %
   Target timeline:       ____________ months
   Projected entities:    ____________

2. Memory Calculation
   ─────────────────
   Projected entities:    ____________
   ÷ Load factor (0.7):   ÷ 0.7
   × Entry size (64B):    × 64
   = Index memory:        ____________ GB
   × Headroom (1.4):      × 1.4
   = Recommended RAM:     ____________ GB

3. Disk Calculation
   ─────────────────
   Projected entities:    ____________
   × Event size (128B):   × 128
   = Base storage:        ____________ GB
   × History multiplier:  × ____________
   = Required storage:    ____________ GB
   × Safety margin (1.2): × 1.2
   = Recommended disk:    ____________ GB

4. Throughput Calculation
   ──────────────────────
   Peak concurrent users: ____________
   × Events per second:   × ____________
   = Required throughput: ____________ events/sec
   ÷ Per-replica capacity (10K): ÷ 10,000
   = Minimum replicas:    ____________
```

### Scaling Decision Tree

```
                    Entity Growth?
                         │
         ┌───────────────┴───────────────┐
         ▼                               ▼
    < 20% annually                  > 20% annually
         │                               │
         ▼                               ▼
    Vertical scaling              Horizontal scaling
    (larger nodes)                (more nodes)
         │                               │
         │                               │
    ┌────┴────┐                    ┌─────┴─────┐
    ▼         ▼                    ▼           ▼
 RAM      Storage              Sharding    Multi-region
upgrade   expansion              by         deployment
                             group_id
```

### Pre-Scaling Checklist

Before scaling capacity:

- [ ] Verify monitoring is capturing growth trends
- [ ] Calculate time to capacity exhaustion
- [ ] Determine scaling method (vertical vs. horizontal)
- [ ] Plan maintenance window (if vertical scaling)
- [ ] Test backup/restore procedures
- [ ] Update capacity monitoring thresholds
- [ ] Document new capacity limits
- [ ] Schedule next capacity review

### Capacity Review Schedule

| Deployment Size | Review Frequency | Growth Threshold |
|-----------------|------------------|------------------|
| < 100M entities | Quarterly | > 50% capacity |
| 100M - 500M | Monthly | > 60% capacity |
| > 500M | Weekly | > 70% capacity |

## Appendix: Capacity Formulas

### Memory

```
Index Memory (GB) = (entities / 0.7) × 64 / 1,073,741,824
Recommended RAM (GB) = Index Memory × 1.4
```

### Disk

```
Base Storage (GB) = entities × 128 / 1,073,741,824
With History (GB) = Base Storage × (1 + updates_per_entity)
With TTL (GB) = event_rate_per_sec × ttl_seconds × 128 / 1,073,741,824
```

### Throughput

```
Events per Second = concurrent_entities / update_interval_seconds
Required Replicas = events_per_second / 10,000 (rounded up)
```

### Network

```
Replication Bandwidth (Mbps) = events_per_second × 128 × 8 / 1,000,000
With 3 replicas: Total = Replication Bandwidth × 2 (primary to backups)
```
