# Tier Profiles and Runtime Presets

This document defines the intended behavior of ArcherDB tier presets as
open-source runtime and capacity profiles. It is normative guidance for release
artifacts, performance tuning, and future configuration changes.

## Canonical Tier Names

ArcherDB supports exactly these build tiers:

- `lite`
- `standard`
- `pro`
- `enterprise`
- `ultra`

## Tier Intent

Standard through ultra tiers share the same high-performance runtime profile and differ
only in capacity. The lite tier uses a reduced-overhead runtime (fewer clients, smaller
pipeline and journal) so its data file fits on a dev laptop.

|Tier|Primary intent|RAM index (default)|Storage (default / max)|Runtime|
|----|--------------|-------------------|----------------------|-------|
|`lite`|Demo/evaluation — small footprint, fast startup|`128 MiB`|`4 GiB / 4 GiB`|lite (64 clients, journal 256)|
|`standard`|Baseline production capacity tier|`4 GiB`|`64 GiB / 256 GiB`|high-perf (256 clients, journal 1024)|
|`pro`|Mid-tier capacity profile|`16 GiB`|`512 GiB / 2 TiB`|high-perf|
|`enterprise`|Large-capacity production profile|`32 GiB`|`4 TiB / 16 TiB`|high-perf|
|`ultra`|Highest-capacity profile|`64 GiB`|`16 TiB / 64 TiB`|high-perf|

## Non-Negotiables

- Standard through ultra tiers must use the same high-performance runtime knobs (request envelope, LSM tuning, I/O concurrency, pipeline settings).
- The lite tier may reduce runtime parameters (clients, pipeline, journal, compaction batch size, I/O concurrency) to shrink fixed overhead.
- Tier progression must be monotonic by capacity from `lite` to `ultra`.
- Capacity boundaries should be enforced through RAM and disk quotas, not transport/request ceilings.
- Tier names should remain canonical; do not introduce compatibility aliases.

## Release Artifact Guidance

- Publish tier-labeled binaries if you ship prebuilt artifacts (for example: `archerdb-lite`, `archerdb-standard`, ...).
- Make `lite` the default recommendation for demos/evaluation.
- Build release artifacts with performance-appropriate optimization settings for the release target.

## Change Checklist (When Editing Tier Defaults)

1. Confirm standard–ultra tiers still share the same runtime/performance knobs.
2. Confirm lite uses the lite runtime; standard–ultra use the high-perf runtime.
3. Confirm only RAM/disk quotas differ across tiers within each runtime class.
4. Verify tier ordering remains monotonic by capacity (`lite` -> `standard` -> `pro` -> `enterprise` -> `ultra`).
5. Update this document and linked user-facing docs in the same change.
