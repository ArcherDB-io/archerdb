# Tier Profiles and Product Positioning

This document defines the intended product behavior of ArcherDB tier presets.
It is normative guidance for release packaging, performance tuning, and future
configuration changes.

## Canonical Tier Names

ArcherDB supports exactly these build tiers:

- `lite`
- `standard`
- `pro`
- `enterprise`
- `ultra`

## Tier Intent

All tiers run the same high-performance runtime profile. Tiering is capacity-only.

|Tier|Primary intent|RAM index budget (default)|Storage limits (default / max)|
|----|--------------|--------------------------|------------------------------|
|`lite`|Smallest-capacity entry tier with full runtime behavior|`128 MiB`|`16 GiB / 16 GiB`|
|`standard`|Baseline production capacity tier|`16 GiB`|`256 GiB / 1 TiB`|
|`pro`|Mid-tier capacity profile|`32 GiB`|`2 TiB / 8 TiB`|
|`enterprise`|Large-capacity production profile|`64 GiB`|`16 TiB / 64 TiB`|
|`ultra`|Highest-capacity profile|`128 GiB`|`64 TiB / 256 TiB`|

## Non-Negotiables

- All tiers must use the same high-performance runtime knobs (request envelope, LSM tuning, I/O concurrency, pipeline settings).
- Tier progression must be monotonic by capacity from `lite` to `ultra`.
- Capacity boundaries should be enforced through RAM and disk quotas, not transport/request ceilings.
- Tier names should remain canonical; do not introduce compatibility aliases.

## Release Packaging Guidance

- Publish tier-labeled binaries so users can compare and choose quickly (for example: `archerdb-lite`, `archerdb-standard`, ...).
- Make `lite` the default recommendation for demos/evaluation.
- Build release artifacts with performance-appropriate optimization settings for the release target.

## Change Checklist (When Editing Tier Defaults)

1. Confirm all tiers still share the same runtime/performance knobs.
2. Confirm only RAM/disk quotas differ across tiers.
3. Verify tier ordering remains monotonic by capacity (`lite` -> `standard` -> `pro` -> `enterprise` -> `ultra`).
4. Update this document and linked user-facing docs in the same change.
