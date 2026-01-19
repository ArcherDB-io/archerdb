# Proposal: Sub-Meter Precision

## Summary

Document and validate ArcherDB's sub-meter precision capabilities, which now exceed typical GPS accuracy due to advances in positioning technology (RTK GPS, UWB, carrier-phase).

## Motivation

### Problem

ArcherDB was designed with "nanodegree precision" (10^-9 degrees ≈ 0.1mm), but documentation suggested this exceeds practical GPS accuracy. Modern positioning technology has caught up:

| Technology | Typical Accuracy |
|------------|------------------|
| Consumer GPS (2010) | 3-5 meters |
| Consumer GPS (2024) | 1-3 meters |
| Dual-frequency GPS | 0.3-1 meter |
| RTK GPS | 1-2 centimeters |
| UWB indoor positioning | 10-30 centimeters |
| Carrier-phase GPS | 1-5 centimeters |

The documentation needs updating to reflect that sub-meter precision is now practical.

### Current Behavior

- Nanodegree storage provides 0.1mm theoretical precision
- Documentation mentions "GPS accuracy limits"
- No validation that precision is actually preserved
- No guidance on sub-meter use cases

### Desired Behavior

- **Documented precision**: Clear specification of actual precision
- **Validation tests**: Prove precision through testing
- **Use case guidance**: When sub-meter precision matters
- **SDK precision options**: Control coordinate rounding

## Scope

### In Scope

1. **Documentation update**: Clarify precision capabilities
2. **Precision validation**: Tests proving sub-meter accuracy
3. **Use case documentation**: RTK, UWB, indoor positioning
4. **SDK precision controls**: Optional rounding for display

### Out of Scope

1. **New data types**: Nanodegrees sufficient
2. **Higher precision**: 0.1mm is more than enough
3. **Coordinate systems**: WGS84 only
4. **Height precision**: Focus on horizontal

## Success Criteria

1. **Documentation accuracy**: Clearly states sub-meter capability
2. **Test validation**: Round-trip precision verified
3. **Use case enablement**: RTK/UWB users confident in storage

## Risks & Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| Floating-point errors in SDKs | Precision loss | Use integer arithmetic, document SDK behavior |
| User confusion | Wrong precision expectations | Clear documentation with examples |
| S2 cell precision limits | Coarser than nanodegrees | Document S2 precision (cm level) |

## Stakeholders

- **Precision agriculture**: Need cm-level accuracy
- **Construction/surveying**: RTK GPS users
- **Indoor positioning**: UWB/BLE beacon users
- **Drone operators**: Precise flight paths
