package com.archerdb.geo;

import java.util.Objects;

/**
 * Notification about a topology change event (F5.1.3 Topology Change Push Notifications).
 */
public final class TopologyChangeNotification {

    private final long newVersion;
    private final long oldVersion;
    private final TopologyChangeType changeType;
    private final int affectedShard;
    private final long timestampNs;

    /**
     * Creates a new TopologyChangeNotification.
     *
     * @param newVersion the new topology version
     * @param oldVersion the previous topology version
     * @param changeType the type of change
     * @param affectedShard the shard affected by the change
     * @param timestampNs timestamp of the change (nanoseconds since epoch)
     */
    public TopologyChangeNotification(long newVersion, long oldVersion,
            TopologyChangeType changeType, int affectedShard, long timestampNs) {
        this.newVersion = newVersion;
        this.oldVersion = oldVersion;
        this.changeType = changeType;
        this.affectedShard = affectedShard;
        this.timestampNs = timestampNs;
    }

    /**
     * Creates a simple version change notification.
     */
    public TopologyChangeNotification(long newVersion, long oldVersion, long timestampNs) {
        this(newVersion, oldVersion, null, -1, timestampNs);
    }

    /**
     * Returns the new topology version.
     */
    public long getNewVersion() {
        return newVersion;
    }

    /**
     * Returns the previous topology version.
     */
    public long getOldVersion() {
        return oldVersion;
    }

    /**
     * Returns the type of change, or null if not specified.
     */
    public TopologyChangeType getChangeType() {
        return changeType;
    }

    /**
     * Returns the shard affected by the change, or -1 if not specified.
     */
    public int getAffectedShard() {
        return affectedShard;
    }

    /**
     * Returns the timestamp of the change (nanoseconds since epoch).
     */
    public long getTimestampNs() {
        return timestampNs;
    }

    @Override
    public boolean equals(Object obj) {
        if (this == obj)
            return true;
        if (!(obj instanceof TopologyChangeNotification))
            return false;
        TopologyChangeNotification other = (TopologyChangeNotification) obj;
        return newVersion == other.newVersion && oldVersion == other.oldVersion
                && changeType == other.changeType && affectedShard == other.affectedShard
                && timestampNs == other.timestampNs;
    }

    @Override
    public int hashCode() {
        return Objects.hash(newVersion, oldVersion, changeType, affectedShard, timestampNs);
    }

    @Override
    public String toString() {
        if (changeType != null) {
            return String.format("TopologyChange{%d->%d, type=%s, shard=%d}", oldVersion,
                    newVersion, changeType, affectedShard);
        }
        return String.format("TopologyChange{%d->%d}", oldVersion, newVersion);
    }
}
