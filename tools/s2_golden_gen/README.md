# S2 Golden Vector Generator

ArcherDB is a Zig project. This directory exists only to make the **S2 golden vectors** used by tests/specs reproducible.

### What this tool does

- Generates a deterministic set of `(lat_nano, lon_nano, level)` inputs.
- Produces `testdata/s2/golden_vectors_v1.tsv` by computing `cell_id` using a **pinned reference implementation** (not ArcherDB’s Zig S2).

### Why a pinned reference is needed

If ArcherDB’s Zig S2 implementation generates the expected values, tests can become self-fulfilling. Golden vectors must come from an independent implementation.

### Reference implementation policy (v1)

- **Reference**: Go `github.com/golang/geo/s2` at a pinned module version.
- **How it is used**: `tools/s2_golden_gen/main.zig` shells out to a small Go runner in `tools/s2_golden_gen/reference/go_s2_ref/` using `go run -mod=vendor`.
- **Reproducibility**: the Go module is vendored (`go mod vendor`) so regeneration does not require network access.

### Regenerate command (v1)

This is the intended flow (exact details are defined in the specs):

1. Generate inputs + compute reference `cell_id` values (deterministic):

```sh
zig run tools/s2_golden_gen/main.zig -- \
  --out testdata/s2/golden_vectors_v1.tsv \
  --seed 1 \
  --random 1024 \
  --levels 0,1,5,10,15,18,30
```

Notes:

- Requires `go` on your `PATH`.
- The generator writes its Go build cache under `.zig-cache/s2_golden_gen/go-build-cache` (so it stays workspace-local).
