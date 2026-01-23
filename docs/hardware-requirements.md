# ArcherDB Hardware Requirements

This document specifies minimum and recommended hardware requirements for ArcherDB deployments, along with cloud instance mappings and sizing formulas.

## Table of Contents

- [Quick Reference](#quick-reference)
- [Minimum Requirements](#minimum-requirements)
- [Recommended Specifications](#recommended-specifications)
- [Memory Sizing](#memory-sizing)
- [Storage Sizing](#storage-sizing)
- [Network Requirements](#network-requirements)
- [Cloud Instance Mapping](#cloud-instance-mapping)
- [Sizing Calculator](#sizing-calculator)

## Quick Reference

### By Entity Count

| Entities | Min RAM | Rec RAM | Min Disk | Rec Disk | Min CPU |
|----------|---------|---------|----------|----------|---------|
| 1M | 2 GB | 4 GB | 10 GB | 50 GB | 2 cores |
| 10M | 4 GB | 8 GB | 50 GB | 200 GB | 4 cores |
| 100M | 16 GB | 32 GB | 200 GB | 1 TB | 8 cores |
| 500M | 64 GB | 96 GB | 1 TB | 5 TB | 16 cores |
| 1B | 96 GB | 128 GB | 2 TB | 10 TB | 32 cores |

### By Throughput Target

| Events/sec | Min RAM | Rec RAM | Rec CPU | Rec Disk |
|------------|---------|---------|---------|----------|
| 10K | 4 GB | 8 GB | 4 cores | SATA SSD |
| 100K | 8 GB | 16 GB | 8 cores | NVMe |
| 500K | 16 GB | 32 GB | 16 cores | NVMe Gen3+ |
| 1M | 32 GB | 64 GB | 32 cores | NVMe Gen4 |

## Minimum Requirements

These are the absolute minimum specifications for ArcherDB to function. Performance may be limited.

### Development/Testing

For development, testing, and small-scale deployments (<1M entities):

| Component | Minimum | Notes |
|-----------|---------|-------|
| **CPU** | 2 cores, x86-64 | Must support AES-NI |
| **RAM** | 2 GB | Limits entity count to ~20M |
| **Disk** | 10 GB SSD | HDD not supported |
| **Disk Speed** | 100 MB/s seq | SATA SSD sufficient |
| **Network** | 100 Mbps | For replication |

### Production (Single Node)

For production single-node deployments (<100M entities):

| Component | Minimum | Notes |
|-----------|---------|-------|
| **CPU** | 4 cores, x86-64 | AVX2 recommended |
| **RAM** | 8 GB | Limits entity count to ~70M |
| **Disk** | 100 GB NVMe | Direct I/O requires NVMe |
| **Disk Speed** | 1 GB/s seq | NVMe Gen3 minimum |
| **Network** | 1 Gbps | 10 Gbps for replication |

### Production (Cluster)

For production cluster deployments:

| Component | Minimum per Node | Notes |
|-----------|-----------------|-------|
| **CPU** | 8 cores, x86-64 | AVX2 highly recommended |
| **RAM** | 16 GB | All nodes must match |
| **Disk** | 200 GB NVMe | Replicas need identical storage |
| **Disk Speed** | 2 GB/s seq | NVMe Gen3+ |
| **Network** | 10 Gbps | Between replicas |

## Recommended Specifications

### Standard Production

For typical production workloads (100M-500M entities, <500K events/sec):

| Component | Specification | Rationale |
|-----------|---------------|-----------|
| **CPU** | 16 cores, Intel Xeon or AMD EPYC | Handles compaction + queries |
| **RAM** | 64 GB ECC | 500M entities + cache |
| **Disk** | 1 TB NVMe Gen4 | 3+ GB/s for low latency |
| **Network** | 25 Gbps | Replication headroom |

### High Performance

For demanding workloads (>500M entities, >500K events/sec):

| Component | Specification | Rationale |
|-----------|---------------|-----------|
| **CPU** | 32+ cores, latest gen | Max throughput |
| **RAM** | 128-256 GB ECC | Billions of entities |
| **Disk** | 2+ TB NVMe Gen5 | 7+ GB/s peak |
| **Network** | 100 Gbps | Multi-region replication |

### CPU Requirements

Required CPU features:

| Feature | Required | Why |
|---------|----------|-----|
| x86-64 | Yes | Instruction set |
| AES-NI | Yes | Aegis-128L checksums, encryption |
| AVX2 | Recommended | SIMD operations |
| RDTSCP | Recommended | High-resolution timing |

ARM64 (Apple Silicon, Graviton) is also supported.

### Disk Requirements

| Metric | Minimum | Recommended | High Perf |
|--------|---------|-------------|-----------|
| Sequential Read | 1 GB/s | 3 GB/s | 7 GB/s |
| Sequential Write | 500 MB/s | 1.5 GB/s | 5 GB/s |
| Random Read IOPS | 50K | 200K | 500K |
| Random Write IOPS | 30K | 100K | 300K |
| Latency (p99) | <1ms | <0.5ms | <0.2ms |

**Important:** ArcherDB uses Direct I/O. Ensure:
- File system supports O_DIRECT (ext4, xfs, btrfs)
- No network-attached storage for data files
- NVMe strongly preferred over SATA

## Memory Sizing

### Memory Formula

ArcherDB maintains a RAM index for O(1) entity lookups:

```
Index Memory = (Entity Count / Load Factor) x Entry Size

Where:
- Load Factor = 0.70 (target 70% utilization)
- Entry Size = 64 bytes (cache-line aligned)

Recommended RAM = Index Memory x 1.4 (headroom for cache, buffers)
```

### Memory Sizing Table

| Entity Count | Index Size | Min RAM | Rec RAM |
|--------------|------------|---------|---------|
| 1 Million | 92 MB | 2 GB | 4 GB |
| 10 Million | 915 MB | 4 GB | 8 GB |
| 50 Million | 4.6 GB | 8 GB | 16 GB |
| 100 Million | 9.2 GB | 16 GB | 32 GB |
| 250 Million | 23 GB | 32 GB | 64 GB |
| 500 Million | 46 GB | 64 GB | 96 GB |
| 1 Billion | 92 GB | 128 GB | 192 GB |

### Memory Allocation Breakdown

For a production node with 64 GB RAM:

| Component | Allocation | Purpose |
|-----------|------------|---------|
| Index | ~46 GB | Entity lookup (500M entities) |
| Block Cache | 8 GB | LSM tree read caching |
| Query Buffers | 2 GB | Result assembly |
| VSR Buffers | 2 GB | Replication pipeline |
| OS/Overhead | 6 GB | Kernel, page cache |

## Storage Sizing

### Storage Formula

```
Base Storage = Entity Count x Event Size x History Depth

Where:
- Event Size = 128 bytes per GeoEvent
- History Depth = average events per entity

With Safety Margin:
Recommended Storage = Base Storage x 1.5
```

### Storage Sizing Table

| Entities | Latest Only | 10x History | 50x History |
|----------|-------------|-------------|-------------|
| 1M | 128 MB | 1.3 GB | 6.4 GB |
| 10M | 1.3 GB | 13 GB | 64 GB |
| 100M | 13 GB | 130 GB | 640 GB |
| 500M | 64 GB | 640 GB | 3.2 TB |
| 1B | 128 GB | 1.3 TB | 6.4 TB |

### Storage Type Guidelines

| Workload | Storage Type | Why |
|----------|--------------|-----|
| Development | SATA SSD | Cost-effective |
| Standard Production | NVMe Gen3 | Good balance |
| High Throughput | NVMe Gen4/Gen5 | Maximum IOPS |
| High Capacity | NVMe + S3 tiering | Cost-effective scale |

## Network Requirements

### Bandwidth Sizing

```
Replication Bandwidth = Events/sec x Event Size x Replicas

Example: 100K events/sec with 3 replicas
= 100,000 x 128 x 2 (primary to backups)
= 25.6 MB/s = 205 Mbps
```

### Network Requirements by Scale

| Events/sec | Min Bandwidth | Rec Bandwidth |
|------------|---------------|---------------|
| 10K | 100 Mbps | 1 Gbps |
| 100K | 1 Gbps | 10 Gbps |
| 500K | 5 Gbps | 25 Gbps |
| 1M | 10 Gbps | 50 Gbps |

### Latency Requirements

| Scenario | Max Latency | Recommended |
|----------|-------------|-------------|
| Same rack | 1ms | <0.1ms |
| Same datacenter | 5ms | <1ms |
| Same region | 20ms | <5ms |
| Cross-region | 100ms | <50ms |

## Cloud Instance Mapping

### AWS EC2

| Use Case | Instance | vCPUs | RAM | Storage | Cost/mo |
|----------|----------|-------|-----|---------|---------|
| Dev/Test | t3.large | 2 | 8 GB | gp3 | ~$60 |
| Small Prod | m6i.xlarge | 4 | 16 GB | gp3 | ~$140 |
| Standard Prod | m6i.4xlarge | 16 | 64 GB | io2 | ~$560 |
| High Perf | m6i.8xlarge | 32 | 128 GB | io2 | ~$1,120 |
| Extreme | i4i.4xlarge | 16 | 128 GB | local NVMe | ~$1,000 |

**Storage Notes:**
- Use io2 for production (up to 64K IOPS)
- i4i instances have local NVMe (best performance)
- gp3 sufficient for dev/test

### Google Cloud

| Use Case | Instance | vCPUs | RAM | Storage |
|----------|----------|-------|-----|---------|
| Dev/Test | e2-standard-2 | 2 | 8 GB | pd-ssd |
| Small Prod | n2-standard-4 | 4 | 16 GB | pd-ssd |
| Standard Prod | n2-standard-16 | 16 | 64 GB | pd-extreme |
| High Perf | n2-standard-32 | 32 | 128 GB | local SSD |
| Extreme | c3-standard-44 | 44 | 176 GB | local SSD |

### Azure

| Use Case | Instance | vCPUs | RAM | Storage |
|----------|----------|-------|-----|---------|
| Dev/Test | Standard_D2s_v5 | 2 | 8 GB | Premium SSD |
| Small Prod | Standard_D4s_v5 | 4 | 16 GB | Premium SSD |
| Standard Prod | Standard_D16s_v5 | 16 | 64 GB | Premium SSD v2 |
| High Perf | Standard_D32s_v5 | 32 | 128 GB | Ultra Disk |
| Extreme | Standard_L16s_v3 | 16 | 128 GB | local NVMe |

### Bare Metal Providers

| Provider | Configuration | Approx Cost |
|----------|--------------|-------------|
| Hetzner AX102 | 32 cores, 128 GB, 2x NVMe | ~$180/mo |
| OVH Advance-2 | 16 cores, 64 GB, 2x NVMe | ~$120/mo |
| Vultr Bare Metal | 24 cores, 256 GB, NVMe | ~$350/mo |
| Equinix m3.large | 24 cores, 64 GB, NVMe | ~$500/mo |

## Sizing Calculator

### Quick Sizing Formula

```
Required RAM (GB) = ceil(entities / 10_000_000) * 1.5 + 4

Required Disk (GB) = (entities * 128 * history_depth) / (1024^3) * 1.5

Required Cores = max(4, ceil(events_per_sec / 100_000) * 4)
```

### Example: 100M Entities, 50K events/sec

```
RAM:
  Index = (100M / 0.7) * 64 = 9.1 GB
  Recommended = 9.1 * 1.4 = 12.7 GB
  With headroom = 16 GB minimum, 32 GB recommended

Disk (with 20x history):
  Base = 100M * 128 * 20 = 256 GB
  Recommended = 256 * 1.5 = 384 GB
  Actual = 512 GB NVMe

CPU:
  Base = 50K / 100K * 4 = 2 cores
  Recommended = 8 cores (for compaction headroom)

Network:
  Replication = 50K * 128 * 2 = 12.8 MB/s
  Recommended = 1 Gbps
```

### Sizing Worksheet

```
1. Entity Estimation
   Current entities:     ____________
   Annual growth rate:   ____________%
   Planning horizon:     ____________ years
   Projected entities:   ____________

2. Throughput Estimation
   Peak events/sec:      ____________
   Average events/sec:   ____________
   Batch size:           ____________

3. Memory Calculation
   Index memory:         ____________ GB  (entities / 0.7 * 64 / 1GB)
   With headroom:        ____________ GB  (index * 1.4)
   Actual RAM:           ____________ GB  (round up to available)

4. Storage Calculation
   Base storage:         ____________ GB  (entities * 128 / 1GB)
   With history:         ____________ GB  (base * history_depth)
   With margin:          ____________ GB  (with_history * 1.5)
   Actual disk:          ____________ GB  (round up)

5. Instance Selection
   Cloud provider:       ____________
   Instance type:        ____________
   Monthly cost:         $____________
```

## Related Documentation

- [Capacity Planning](capacity-planning.md) - Detailed capacity planning guide
- [Benchmarks](benchmarks.md) - Performance benchmark results
- [Operations Runbook](operations-runbook.md) - Deployment and tuning
