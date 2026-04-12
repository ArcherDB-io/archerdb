# Contributing to ArcherDB

Thank you for your interest in contributing to ArcherDB! This document provides guidelines and information for contributors.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Contribution Workflow](#contribution-workflow)
- [Code Style](#code-style)
- [Testing](#testing)
- [Documentation](#documentation)
- [Developer Certificate of Origin](#developer-certificate-of-origin)
- [Governance](#governance)
- [Support](#support)
- [Questions?](#questions)

## Code of Conduct

ArcherDB is an open-source project. All contributors are expected to follow
the project [Code of Conduct](CODE_OF_CONDUCT.md).

## Getting Started

### Types of Contributions

We welcome:

- **Bug reports**: Open an issue describing the bug, steps to reproduce, and expected behavior
- **Feature requests**: Open an issue describing the use case and proposed solution
- **Code contributions**: Bug fixes, features, tests, documentation improvements
- **Documentation**: Improvements to docs, examples, tutorials

### Before Contributing

1. Check existing [issues](https://github.com/ArcherDB-io/archerdb/issues) to avoid duplicates
2. For significant changes, open an issue first to discuss the approach
3. Review the [project board](https://github.com/orgs/ArcherDB-io/projects/1) for current priorities
4. Read [GOVERNANCE.md](GOVERNANCE.md) for maintainer decision-making and release expectations
5. Read [SUPPORT.md](SUPPORT.md) for issue-routing guidance

## Development Setup

### Prerequisites

- Linux (kernel >= 5.6), macOS, or Windows
- Git

### Building from Source

```bash
# Clone the repository
git clone https://github.com/ArcherDB-io/archerdb.git
cd archerdb

# Download the bundled Zig compiler
./zig/download.sh

# Build
./zig/zig build

# Run tests
./zig/zig build test
```

### Local Development Cluster

For testing and development, use the provided cluster script:

```bash
# Start a 3-node development cluster
./scripts/dev-cluster.sh start

# Start a single-node cluster (faster for development)
./scripts/dev-cluster.sh start --nodes=1

# Stop the cluster
./scripts/dev-cluster.sh stop

# Clean up data files
./scripts/dev-cluster.sh clean
```

## Contribution Workflow

### For Bug Fixes and Small Changes

1. Fork the repository
2. Create a feature branch: `git checkout -b fix/issue-123-description`
3. Make your changes
4. Run tests: `./zig/zig build test`
5. Commit with a descriptive message
6. Push to your fork
7. Open a Pull Request

### For Larger Features

1. Open an issue to discuss the feature
2. Wait for maintainer feedback before significant implementation work
3. Follow the same process as above
4. Reference the issue in your PR description

### Commit Messages

Write clear, descriptive commit messages:

```
Short summary (50 chars or less)

More detailed explanation if needed. Wrap at 72 characters.
Explain what and why, not how.

Fixes #123
```

### Pull Request Guidelines

- Keep PRs focused on a single change
- Include tests for new functionality
- Update documentation as needed
- Reference related issues
- Respond to review feedback promptly

## Code Style

ArcherDB follows a pragmatic systems-engineering style. Key principles:

### Safety First

- Safety, performance, and developer experience, in that order
- All three are important, but safety is paramount
- Zero technical debt policy - do it right the first time

### Zig Code Style

- Use `zig fmt` to format code: `./zig/zig fmt src/`
- Simple, explicit control flow
- No recursion (ensures bounded execution)
- Comprehensive error handling
- Clear variable and function names

### Documentation

- Document public APIs
- Add comments for non-obvious logic
- Keep comments up to date with code changes

## Testing

### Running Tests

```bash
# Run all tests
./zig/zig build test

# Run specific tests
./zig/zig build test -- --test-filter="geo_event"
```

### Writing Tests

- Write tests for all new functionality
- Test edge cases and error conditions
- For geospatial code, include tests for:
  - Boundary conditions (poles, anti-meridian)
  - Precision limits (nanosecond coordinates)
  - Empty and maximum-size result sets

### Deterministic Testing

ArcherDB uses VOPR (Viewstamped Operation Replayer) for deterministic simulation testing. When adding new state machine operations:

1. Add workload generators in `src/testing/geo_workload.zig`
2. Ensure operations are deterministic
3. Test with various fault injection scenarios

## Documentation

### Where Documentation Lives

- `README.md` - Project overview
- `docs/` - User documentation
- Code comments - Implementation details

### Documentation Standards

- Use clear, concise language
- Include code examples where helpful
- Keep examples up to date and tested
- Use consistent terminology

## Developer Certificate of Origin

ArcherDB does not currently require a separate Contributor License Agreement.
Instead, contributions are accepted under the Apache License 2.0 project
license using a Developer Certificate of Origin style sign-off.

By contributing to ArcherDB, you certify that:

1. **Original Work**: Your contribution is your original work, or you have the right to submit it.
2. **License Grant**: Your contribution may be distributed under the repository's Apache License 2.0 terms.
3. **Patent Grant**: The Apache License 2.0 patent terms apply to your contribution.
4. **Attribution**: Your contribution may be attributed to you unless you request otherwise.

### Signing your work

Include a sign-off in your commit message:

```
Signed-off-by: Your Name <your.email@example.com>
```

This indicates that you certify the contribution under the Developer
Certificate of Origin process. You can add this automatically:

```bash
git commit -s -m "Your commit message"
```

## Governance

Project governance and maintainer responsibilities live in
[GOVERNANCE.md](GOVERNANCE.md).

## Support

Issue-routing and support guidance live in [SUPPORT.md](SUPPORT.md).

## Attribution

ArcherDB incorporates derivative work and implementation ideas from
[TigerBeetle](https://github.com/tigerbeetle/tigerbeetle). See the
[NOTICE](NOTICE) file for project attribution details.

When contributing code that originates from or is inspired by other open source projects, please ensure proper attribution in the code comments and update the NOTICE file if required.

## Questions?

- **Issues**: Open a [GitHub issue](https://github.com/ArcherDB-io/archerdb/issues)
- **Discussions**: Use [GitHub Discussions](https://github.com/ArcherDB-io/archerdb/discussions) for questions

Thank you for contributing to ArcherDB!
