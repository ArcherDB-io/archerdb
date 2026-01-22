# Phase 3: Core Geospatial - Context

**Gathered:** 2026-01-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Verify all geospatial operations work correctly — S2 indexing, radius/polygon queries, entity operations, RAM index. This is verification of existing functionality, not new feature development.

</domain>

<decisions>
## Implementation Decisions

### S2 Reference Validation
- Direct comparison against Google S2 reference implementation
- All S2 levels (0-30) verified exhaustively
- Strict correctness for all edge cases — poles, antimeridian, cell boundaries must match Google S2 exactly
- Test vectors pre-generated and committed to repository (not dynamic generation)
- Global geographic distribution in test vectors — all continents, oceans, poles, antimeridian
- Comprehensive test vectors (1000+ per category): cell ID, neighbors, containment, etc.
- Full verification of S2 cell union operations (covering, interior covering, union/intersection)
- Bit-exact coordinate precision — lat/lng to S2 roundtrip must be bit-identical
- WGS84 vs sphere assumptions explicitly documented and tested
- Full Hilbert curve verification — locality, bijectivity, ordering properties
- Test vector generator script committed alongside vectors for reproducibility
- No known issues — systematic verification across all operations

### Query Accuracy Thresholds
- Boundary cases are inclusive — points exactly on radius edge ARE included
- Polygon edge points are inclusive — points on polygon edges ARE inside
- Counter-clockwise winding order required (GeoJSON convention: exterior CCW, holes CW)
- Self-intersecting polygons rejected with error — require valid input
- Native antimeridian support — polygons crossing 180° longitude work without splitting
- High polygon complexity supported (10,000+ vertices) — coastlines, admin boundaries
- Polygon holes (interior rings) required — donut shapes must work correctly

### Entity Operation Semantics
- TTL-based tombstones — expire after configured TTL, then compaction removes
- Atomic move for upsert location changes — old entry deleted and new created atomically
- Insert on existing entity ID returns error — use upsert for updates

### RAM Index Guarantees
- Linearizable consistency — reads always see effects of completed writes
- Memory capacity exceeded → reject new entries (error), allow updates to existing
- Explicit recovery tests — verify RAM index rebuilds correctly from persistent state

### Claude's Discretion
- Distance calculation method (great-circle vs ellipsoidal) — based on S2 library capabilities
- Batch operation atomicity — based on VSR transaction model
- Race condition verification method (line 1859) — choose stress testing vs formal analysis

</decisions>

<specifics>
## Specific Ideas

- "Bit-exact" precision requirement reflects need for deterministic, reproducible results
- S2 library should match Google's reference implementation exactly — no approximations for edge cases
- High polygon complexity requirement suggests real-world use cases like administrative boundaries

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 03-core-geospatial*
*Context gathered: 2026-01-22*
