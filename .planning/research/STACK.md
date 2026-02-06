# Stack Research: SDK Testing & Benchmarking

**Domain:** Database SDK Testing and Performance Benchmarking
**Researched:** 2026-02-01
**Confidence:** HIGH (verified with existing codebase, official docs, and recent search results)

## Recommended Stack

### Testing Frameworks Per Language

| Language | Framework | Version | Purpose | Why Recommended |
|----------|-----------|---------|---------|-----------------|
| Python | pytest | 9.x | Unit/integration testing | Already in use, de facto Python standard, excellent plugin ecosystem |
| Python | pytest-benchmark | 5.x | Microbenchmarking | Integrates with pytest, captures p50/p99 latency, exports JSON |
| Node.js | Node.js Test Runner | 20+ built-in | Unit testing | Built-in since Node 18, zero dependencies, TypeScript-friendly |
| Node.js | Vitest | 3.x | Alternative unit testing | Faster than Jest, modern, excellent TypeScript support |
| Go | testing (std) | 1.21+ | Unit/benchmark | Built-in, industry standard, native benchmarking with `go test -bench` |
| Java | JUnit 5 (Jupiter) | 5.10.x | Unit testing | Already in use, parameterized tests, modern assertions |
| Java | JMH | 1.37+ | Microbenchmarking | OpenJDK standard, handles JVM warmup/JIT correctly |
| C | Custom + assertions | N/A | Unit testing | Minimal framework needed; existing `arch_client_errors_test.c` pattern |

### Benchmarking Infrastructure

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| github-action-benchmark | v1 | CI regression detection | Already in use in ci.yml, tracks history, alerts on regression |
| Bencher | latest | Advanced tracking | Better visualization than github-action-benchmark, relative benchmarking |
| k6 | latest | Load testing | Language-agnostic, Grafana integration, SLO thresholds |
| JSON output format | N/A | Cross-language results | Already established pattern in benchmark.yml |

### Test Data Generation

| Library | Language | Purpose | Why Recommended |
|---------|----------|---------|-----------------|
| Faker (geo provider) | Python | Geographic coordinates | Built-in geo provider, reproducible with seeds |
| Custom generators | All | Spatial distributions | Control over uniform vs concentrated patterns |
| Shared JSON test cases | All | Wire format validation | Already exists at `src/clients/test-data/` |

### CI Integration

| Tool | Purpose | Why Recommended |
|------|---------|-----------------|
| GitHub Actions | CI orchestration | Already in use, excellent matrix support |
| actions/setup-python/node/go/java | Language setup | Standard, maintained |
| codecov/codecov-action | Coverage tracking | Already in use |
| benchmark-action/github-action-benchmark | Perf tracking | Already configured |

## Installation

### Python SDK Testing

```bash
# Core testing
pip install pytest pytest-benchmark

# Optional: async support, coverage
pip install pytest-asyncio pytest-cov hypothesis

# pyproject.toml additions
[project.optional-dependencies]
test = [
    "pytest>=9.0.0",
    "pytest-benchmark>=5.0.0",
    "hypothesis>=6.0.0",
]
```

### Node.js SDK Testing

```bash
# Minimal (use built-in test runner)
npm install -D typescript @types/node

# If using Vitest (recommended for faster feedback)
npm install -D vitest @vitest/coverage-v8

# For benchmarking
npm install -D kelonio
```

### Go SDK Testing

```bash
# Built-in testing - no additional dependencies
go test ./... -bench=.

# Optional: testify for assertions (if not using stdlib)
go get github.com/stretchr/testify
```

### Java SDK Testing

```xml
<!-- pom.xml additions for JMH benchmarking -->
<dependency>
    <groupId>org.openjdk.jmh</groupId>
    <artifactId>jmh-core</artifactId>
    <version>1.37</version>
    <scope>test</scope>
</dependency>
<dependency>
    <groupId>org.openjdk.jmh</groupId>
    <artifactId>jmh-generator-annprocess</artifactId>
    <version>1.37</version>
    <scope>test</scope>
</dependency>
```

### Cross-Language Load Testing

```bash
# k6 installation
brew install k6  # macOS
# or
sudo apt-get install k6  # Ubuntu

# Usage
k6 run benchmark-load-test.js
```

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| pytest-benchmark | asv (airspeed velocity) | Need historical tracking across commits with HTML reports |
| Node built-in | Jest | Large existing Jest test suite, familiar with Jest ecosystem |
| JUnit 5 | TestNG | Complex test dependencies, custom reporters needed |
| JMH | custom timing | One-off measurements only, no need for statistical rigor |
| k6 | Locust (Python) | Need Python scripting, already have Python infrastructure |
| k6 | Vegeta (Go) | HTTP-only, Go-native toolchain preference |
| github-action-benchmark | Bencher | Need better visualization, self-hosted tracking |
| Custom data gen | FakeGeo API | Need realistic city-based distributions quickly |

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| Benchmark.js (Node) | Outdated, no longer maintained | kelonio or built-in performance hooks |
| unittest (Python) | Verbose, less plugin ecosystem | pytest |
| JUnit 4 | Legacy, fewer features | JUnit 5 (already configured) |
| Custom CI scripts for perf | Error-prone, no history | github-action-benchmark |
| Manual timing in tests | JVM warmup issues, statistical noise | JMH for Java, pytest-benchmark for Python |
| mocha (Node) | Slower, less TypeScript-native | Node built-in or Vitest |
| Raw `time` command | No percentiles, no warmup, single sample | Proper benchmark frameworks |

## Stack Patterns by Variant

**If testing unit behavior (correctness):**
- Use language-native test framework
- Focus on edge cases, error conditions
- Mock external dependencies
- Pattern: `test_*.py`, `*_test.go`, `*Test.java`

**If testing integration (SDK-to-server):**
- Use same frameworks with server fixtures
- Start ArcherDB server in CI job
- Use environment variables for connection
- Pattern: existing `test-sdk-*` jobs in ci.yml

**If testing performance (benchmarks):**
- Use dedicated benchmark frameworks (JMH, pytest-benchmark)
- Implement warmup phases
- Run multiple iterations
- Output JSON for tracking
- Pattern: existing `benchmark_test.go`, `Benchmark.java`

**If testing cross-SDK consistency:**
- Use shared JSON test cases in `src/clients/test-data/`
- Each SDK reads same test cases
- Validates wire format encoding matches
- Pattern: existing `wire-format-test-cases.json`

## Version Compatibility

| Package A | Compatible With | Notes |
|-----------|-----------------|-------|
| pytest 9.x | Python 3.8+ | Supports async, parametrize |
| JUnit 5.10.x | Java 11+ | Project uses Java 11 |
| Go testing | Go 1.21+ | Project uses Go 1.21 |
| Node test runner | Node 20+ | Built-in since Node 18, stable in 20 |

## Benchmark Reliability Practices

### Warmup Protocol

All benchmark frameworks must implement warmup:

```
1. Python: pytest-benchmark handles automatically (warmup_iterations config)
2. Go: built-in with b.ResetTimer() after warmup loop
3. Java: JMH @Warmup annotation
4. Node: kelonio automatic warmup (100 iterations default)
```

### Statistical Stability

| Metric | Minimum Samples | Report |
|--------|-----------------|--------|
| Throughput | 10 batches | ops/sec with stddev |
| Latency | 1000 ops | p50, p99, p999 |
| Memory | 5 runs | peak bytes, average |

### CI Noise Reduction

For GitHub Actions (per research findings):
1. **Relative benchmarking**: Compare PR vs base in same job
2. **Multiple runs**: Average 3+ runs per benchmark
3. **Thresholds**: Allow 5% variance before flagging regression
4. **Dedicated runners**: Consider self-hosted for consistent hardware

## Test Data Generation Strategy

### Uniform Distribution (Stress Testing)

```python
# Python example with Faker
from faker import Faker
fake = Faker()
fake.seed_instance(42)  # Reproducible

def generate_uniform_point():
    return (fake.latitude(), fake.longitude())
```

### City-Concentrated Distribution (Realistic Testing)

```python
# Center points for major cities
CITY_CENTERS = {
    "san_francisco": (37.7749, -122.4194),
    "tokyo": (35.6762, 139.6503),
    "london": (51.5074, -0.1278),
}

def generate_city_point(city: str, radius_km: float = 50):
    center = CITY_CENTERS[city]
    # Add gaussian noise within radius
    lat_offset = random.gauss(0, radius_km / 111)
    lon_offset = random.gauss(0, radius_km / 111)
    return (center[0] + lat_offset, center[1] + lon_offset)
```

### Shared Test Data Format

Extend existing `wire-format-test-cases.json` for:
- Operation test vectors
- Edge cases (max values, boundaries)
- Error condition test cases

## Sources

- [pytest-benchmark documentation](https://pytest-benchmark.readthedocs.io/) - Verified 2026-02-01
- [Go testing package](https://pkg.go.dev/testing) - Official docs
- [JMH OpenJDK](https://openjdk.org/projects/code-tools/jmh/) - Official docs
- [github-action-benchmark](https://github.com/benchmark-action/github-action-benchmark) - Verified in ci.yml
- [kelonio GitHub](https://github.com/mtkennerly/kelonio) - Node.js TypeScript benchmarking
- [k6 Grafana documentation](https://grafana.com/docs/k6/latest/) - Load testing
- [Bencher documentation](https://bencher.dev/docs/how-to/github-actions/) - CI benchmarking

---
*Stack research for: SDK Testing & Benchmarking*
*Researched: 2026-02-01*
