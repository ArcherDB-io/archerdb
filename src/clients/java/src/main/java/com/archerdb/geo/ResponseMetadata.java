// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

import java.util.Objects;

/**
 * Metadata about a response from a multi-region cluster.
 *
 * <p>
 * Per client-sdk/spec.md v2 multi-region support, response metadata includes:
 * <ul>
 * <li>readStalenessNs - How stale the data may be when read from a follower (nanoseconds)</li>
 * <li>sourceRegion - Which region served the request</li>
 * <li>minCommitOp - Minimum committed operation ID on the serving region</li>
 * </ul>
 *
 * <p>
 * For primary region reads, staleness is always 0. For follower reads, staleness indicates the lag
 * behind the primary region's committed state.
 *
 * <p>
 * This class is immutable and thread-safe.
 */
public final class ResponseMetadata {

    /**
     * Metadata instance indicating a primary region read with no staleness.
     */
    public static final ResponseMetadata PRIMARY =
            new ResponseMetadata(0, "primary", 0, RegionRole.PRIMARY);

    private final long readStalenessNs;
    private final String sourceRegion;
    private final long minCommitOp;
    private final RegionRole sourceRole;

    /**
     * Creates response metadata.
     *
     * @param readStalenessNs staleness in nanoseconds (0 for primary reads)
     * @param sourceRegion name of the region that served the request
     * @param minCommitOp minimum committed operation ID
     * @param sourceRole role of the source region
     */
    public ResponseMetadata(long readStalenessNs, String sourceRegion, long minCommitOp,
            RegionRole sourceRole) {
        this.readStalenessNs = readStalenessNs;
        this.sourceRegion = sourceRegion;
        this.minCommitOp = minCommitOp;
        this.sourceRole = sourceRole;
    }

    /**
     * Returns the read staleness in nanoseconds.
     *
     * <p>
     * For reads from the primary region, this is always 0. For reads from followers, this indicates
     * how far behind the primary the follower may be.
     */
    public long getReadStalenessNs() {
        return readStalenessNs;
    }

    /**
     * Returns the read staleness in milliseconds.
     */
    public long getReadStalenessMs() {
        return readStalenessNs / 1_000_000;
    }

    /**
     * Returns the name of the region that served this request.
     */
    public String getSourceRegion() {
        return sourceRegion;
    }

    /**
     * Returns the minimum committed operation ID on the serving region.
     *
     * <p>
     * This can be used to track replication progress across regions.
     */
    public long getMinCommitOp() {
        return minCommitOp;
    }

    /**
     * Returns the role of the source region (PRIMARY or FOLLOWER).
     */
    public RegionRole getSourceRole() {
        return sourceRole;
    }

    /**
     * Returns true if this response came from the primary region.
     */
    public boolean isFromPrimary() {
        return sourceRole == RegionRole.PRIMARY;
    }

    /**
     * Returns true if this response came from a follower region.
     */
    public boolean isFromFollower() {
        return sourceRole == RegionRole.FOLLOWER;
    }

    /**
     * Returns true if the data may be stale (staleness > 0).
     */
    public boolean isStale() {
        return readStalenessNs > 0;
    }

    @Override
    public boolean equals(Object obj) {
        if (this == obj) {
            return true;
        }
        if (!(obj instanceof ResponseMetadata)) {
            return false;
        }
        ResponseMetadata other = (ResponseMetadata) obj;
        return readStalenessNs == other.readStalenessNs
                && Objects.equals(sourceRegion, other.sourceRegion)
                && minCommitOp == other.minCommitOp && sourceRole == other.sourceRole;
    }

    @Override
    public int hashCode() {
        return Objects.hash(readStalenessNs, sourceRegion, minCommitOp, sourceRole);
    }

    @Override
    public String toString() {
        return "ResponseMetadata{readStalenessNs=" + readStalenessNs + ", sourceRegion='"
                + sourceRegion + "', minCommitOp=" + minCommitOp + ", sourceRole=" + sourceRole
                + "}";
    }

    /**
     * Creates a builder for ResponseMetadata.
     */
    public static Builder builder() {
        return new Builder();
    }

    /**
     * Builder for ResponseMetadata.
     */
    public static class Builder {
        private long readStalenessNs = 0;
        private String sourceRegion = "primary";
        private long minCommitOp = 0;
        private RegionRole sourceRole = RegionRole.PRIMARY;

        public Builder setReadStalenessNs(long readStalenessNs) {
            this.readStalenessNs = readStalenessNs;
            return this;
        }

        public Builder setSourceRegion(String sourceRegion) {
            this.sourceRegion = sourceRegion;
            return this;
        }

        public Builder setMinCommitOp(long minCommitOp) {
            this.minCommitOp = minCommitOp;
            return this;
        }

        public Builder setSourceRole(RegionRole sourceRole) {
            this.sourceRole = sourceRole;
            return this;
        }

        public ResponseMetadata build() {
            return new ResponseMetadata(readStalenessNs, sourceRegion, minCommitOp, sourceRole);
        }
    }
}
