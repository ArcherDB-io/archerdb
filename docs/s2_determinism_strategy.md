# S2 Determinism Strategy (F0.4.6)

This document evaluates and documents the approach for ensuring S2 cell ID
computation produces bit-exact identical results across all replicas.

## The Problem

S2 cell ID computation uses transcendental functions (sin, cos, atan2) which are
NOT guaranteed to produce bit-exact results across:
- x86 vs ARM processors
- Different libc implementations (glibc, musl, macOS libc)
- Compiler optimization levels
- FPU rounding modes

Non-deterministic S2 computation would cause VSR hash-chain breaks and cluster
panics when replicas produce different cell IDs for the same coordinates.

## Option A: Pure Zig with Software Trigonometry

**Approach**: Implement S2 using software-based trigonometry in pure Zig.

### Implementation Details
- Chebyshev polynomials for sin/cos (7th order, error < 1e-15)
- CORDIC algorithm for atan2 (deterministic, no transcendentals)
- Fixed-point arithmetic where possible
- All math operations use only IEEE 754 +,-,×,÷ (which ARE bit-exact)

### Pros
- True cross-platform determinism
- No external dependencies
- Simplest to operate long-term
- Self-contained in Zig codebase

### Cons
- Slower than hardware trig (~2-3x)
- Implementation complexity (1-2 weeks)
- Higher risk of subtle bugs
- Requires extensive validation

### Success Criteria (ALL must pass)
1. Chebyshev polynomial error < 1e-15 on 1000 test angles
2. CORDIC atan2 error < 1e-15 on 1000 test points
3. S2 cell ID matches Google reference bit-exact on 10,000 golden vectors
4. Performance: covering < 1ms p99 on x86
5. Zig compilation succeeds with -O3 on all 4 platforms

### Fail Criteria (ANY one triggers fallback to Option B)
- Error > 1e-15 on any platform
- S2 cell mismatch on any platform or any golden vector
- Covering duration > 10ms (unacceptable performance)
- Platform-specific #ifdefs required

## Option B: Primary-Computed with Hash Verification

**Approach**: Primary computes S2 cell ID during prepare phase; replicas
verify via cryptographic hash (don't recompute S2).

### Implementation Details
- Primary uses proven C++ S2 library (via FFI or Go implementation)
- S2 cell ID included in prepare message
- Replicas trust primary's computation
- Hash chain verification catches any divergence

### Pros
- Simple implementation (1-2 days)
- Uses proven, battle-tested S2 implementation
- Fast (hardware trig)
- Low risk for v1

### Cons
- Primary is single point of S2 computation
- Requires C/C++ FFI or Go subprocess
- Cross-compilation complexity
- Not truly deterministic (but hash-verified)

### When This is Appropriate
- Option A spike reveals unacceptable complexity or risk
- Time pressure for v1 release
- Performance requirements exceed software trig capabilities

## Golden Vector Validation (F0.4.7)

Regardless of chosen option, validation requires:

1. **Generate golden vectors** using Google's C++ S2 reference implementation
2. **Test coverage**:
   - 10,000+ random lat/lon pairs
   - Edge cases: poles, antimeridian, equator
   - Different cell levels (1-30)
3. **Platform matrix**:
   - x86 Linux
   - ARM Linux
   - x86 macOS
   - ARM macOS (Apple Silicon)
   - Windows x64
4. **VOPR integration**: Deterministic replay on mixed x86/ARM cluster

### Golden Vector Format
```
lat,lon,cell_level,expected_cell_id
37.7749,-122.4194,30,0x89C2590000000000
...
```

### Existing Infrastructure
- `tools/s2_golden_gen/`: Go-based golden vector generator using Google S2
- `tools/s2_golden_gen/reference/`: Reference implementation wrapper

## Decision Timeline

1. **Week 1-2 (F0.4)**: Run Option A feasibility spike
   - Prototype Chebyshev sin/cos in Zig
   - Prototype CORDIC atan2
   - Validate on golden vectors

2. **Week 3**: Evaluate spike results against success criteria
   - If PASS: Proceed with Option A implementation
   - If FAIL: Implement Option B

3. **Week 4**: Integration and VOPR testing
   - Golden vector validation on all platforms
   - Mixed-architecture cluster testing

## Current Status

**Decision**: Defer to F1 state machine implementation phase.

For F0, the foundation is ready:
- GeoEvent struct with S2 cell ID field implemented
- Constants for S2 cell level defined
- Golden vector generator tool available
- CI/CD pipeline in place for cross-platform testing

The actual S2 computation implementation and determinism validation will occur
during F1 when the state machine is replaced.

## Recommendation

**For v1**: Start with Option A (Pure Zig) if the spike succeeds within
acceptable parameters. Fall back to Option B if complexity or performance
is unacceptable.

**Rationale**: True determinism (Option A) eliminates an entire class of
potential bugs and simplifies operations. The 2-3x performance cost for
software trig is acceptable given that:
1. S2 computation is not on the critical path (done once per event)
2. Most queries use pre-computed cell IDs from storage
3. Network latency dominates query time anyway

## References

- Google S2 Geometry Library: https://s2geometry.io/
- CORDIC Algorithm: https://en.wikipedia.org/wiki/CORDIC
- Chebyshev Polynomials: https://en.wikipedia.org/wiki/Chebyshev_polynomials
- IEEE 754 Determinism: Only +,-,×,÷ are guaranteed bit-exact
