# ArcherDB Development Docker Image
# Per developer-tools/spec.md: Containerized deployment for development clusters
#
# Build: docker build -f deploy/Dockerfile -t archerdb:dev .
# Usage: See docker-compose.dev.yml for cluster deployment

# Build stage - compile ArcherDB from source
FROM debian:bookworm-slim AS builder

# Install Zig and build dependencies
RUN apt-get update && apt-get install -y \
    curl \
    xz-utils \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Zig 0.15.2 (per implementation-guide/spec.md)
ARG ZIG_VERSION=0.15.2
RUN curl -L "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz" | \
    tar -xJ -C /opt && \
    ln -s /opt/zig-linux-x86_64-${ZIG_VERSION}/zig /usr/local/bin/zig

WORKDIR /build

# Copy source code
COPY . .

# Build ArcherDB in release mode
RUN zig build -Drelease-safe

# Runtime stage - minimal image with just the binary
FROM debian:bookworm-slim

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user for security
RUN useradd -r -s /bin/false archerdb && \
    mkdir -p /data && \
    chown archerdb:archerdb /data

# Copy compiled binary from builder
COPY --from=builder /build/zig-out/bin/archerdb /usr/local/bin/archerdb

# Set ownership and permissions
RUN chmod 755 /usr/local/bin/archerdb

USER archerdb

WORKDIR /data

# Default ports per client-protocol/spec.md
# 3000: Client protocol
# 9100: Prometheus metrics (per observability/spec.md)
EXPOSE 3000 9100

# Health check endpoint
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD archerdb ping --addresses=localhost:3000 || exit 1

# Default entrypoint - allows format, start, inspect commands
ENTRYPOINT ["archerdb"]
CMD ["--help"]
