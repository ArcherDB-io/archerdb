# Proposal: Self-Intersecting Polygon Validation

## Summary

Add client-side validation to detect and reject self-intersecting polygons before sending to server, providing clear error messages and optional repair suggestions.

## Motivation

### Problem

Self-intersecting polygons (bow-ties, figure-8s) produce undefined behavior in containment queries:

```
     A ──────── B          Is point P inside?
      \        /           - Crossing rule: Inside (1 crossing)
       \  P   /            - Winding rule: Outside (net winding = 0)
        \    /
         \  /              Different algorithms give different answers!
          \/
          /\
         /  \
        /    \
       D ──── C
```

Currently, ArcherDB silently accepts these polygons, leading to incorrect query results.

### Current Behavior

- Polygons accepted without geometric validation
- Self-intersecting polygons produce undefined results
- No warning to users about invalid geometry
- Debugging issues requires manual polygon inspection

### Desired Behavior

- **Client-side validation**: Check before sending to server
- **Clear errors**: "Self-intersecting polygon at segment 2-3 and 5-6"
- **Optional repair**: Suggest or automatically fix simple cases
- **Strict mode**: Reject all invalid geometry

## Scope

### In Scope

1. **Self-intersection detection**: Find crossing segments
2. **SDK validation**: All client SDKs perform check
3. **Error messages**: Clear location of intersection
4. **Repair hints**: Suggest fixes for simple cases

### Out of Scope

1. **Server-side validation**: Focus on client-side
2. **Automatic repair**: Just detection and hints
3. **Complex topology repair**: Only simple cases
4. **3D geometry**: 2D polygons only

## Success Criteria

1. **Detection accuracy**: 100% of self-intersections caught
2. **Performance**: <1ms for typical polygons (<100 vertices)
3. **Actionable errors**: Developers can fix issues

## Risks & Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| Performance overhead | Latency increase | O(n log n) algorithm, cache results |
| False positives | Valid polygons rejected | Precise epsilon handling |
| Breaking changes | Existing code may fail | Opt-in strict mode initially |

## Stakeholders

- **Application developers**: Need clear error messages
- **Data quality teams**: Need geometry validation
- **Support teams**: Fewer ambiguous query results
