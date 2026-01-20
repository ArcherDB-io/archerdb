# Pre-Commit Testing Requirements

**CRITICAL**: Before running `git commit` or `git push`, the following checks run automatically
via the hook in `.claude/hooks/pre-commit-check.sh`:

1. **Build check**: `./zig/zig build` - catches compilation errors
2. **License headers**: `./scripts/add-license-headers.sh --check` - ensures headers present
3. **Quick unit tests**: Runs a representative test subset

If any check fails, the commit is **BLOCKED**. Fix the issue first:
- Build failures: Fix compilation errors
- License headers: Run `./scripts/add-license-headers.sh`
- Test failures: Debug and fix the failing tests

**Important**: The full test suite (`./zig/zig build test:unit`) is too slow for pre-commit.
Run targeted tests for areas you modified before committing:
```bash
./zig/zig build test:unit -- --test-filter "encryption"  # encryption tests
./zig/zig build test:unit -- --test-filter "parse_args"  # CLI tests
./zig/zig build test:unit -- --test-filter "error_codes" # error code tests
./zig/zig build test:unit -- --test-filter "sharding"    # sharding tests
```

GitHub CI runs the full test suite - if CI fails but local checks passed, run the full
suite locally to reproduce: `./zig/zig build test:unit`
