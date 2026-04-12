// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.geo;

/**
 * Exception for cluster state errors.
 *
 * <p>
 * Per client-sdk/spec.md and error-codes/spec.md, cluster errors include:
 * <ul>
 * <li>ClusterUnavailable - No quorum available (code 201)</li>
 * <li>ViewChangeInProgress - Leader election in progress (code 202)</li>
 * <li>NotPrimary - Connected to backup replica (code 203)</li>
 * </ul>
 *
 * <p>
 * All cluster errors are retryable - the SDK should automatically retry with exponential backoff.
 */
public class ClusterException extends ArcherDBException {

    private static final long serialVersionUID = 1L;

    /**
     * Error code: Cluster has no quorum (too many replicas down).
     */
    public static final int CLUSTER_UNAVAILABLE = 201;

    /**
     * Error code: Cluster is performing view change.
     */
    public static final int VIEW_CHANGE_IN_PROGRESS = 202;

    /**
     * Error code: This replica is not the primary.
     */
    public static final int NOT_PRIMARY = 203;

    private final int view;
    private final int primaryIndex;

    /**
     * Creates a cluster exception.
     */
    public ClusterException(int errorCode, String message) {
        this(errorCode, message, 0, -1);
    }

    /**
     * Creates a cluster exception with view information.
     */
    public ClusterException(int errorCode, String message, int view, int primaryIndex) {
        // All cluster errors are retryable
        super(errorCode, message, true);
        this.view = view;
        this.primaryIndex = primaryIndex;
    }

    /**
     * Returns the current view number.
     */
    public int getView() {
        return view;
    }

    /**
     * Returns the primary index hint (for NOT_PRIMARY errors). Returns -1 if not available.
     */
    public int getPrimaryIndex() {
        return primaryIndex;
    }

    /**
     * Creates a cluster unavailable exception.
     */
    public static ClusterException clusterUnavailable(int view, int aliveCount,
            int quorumRequired) {
        return new ClusterException(CLUSTER_UNAVAILABLE,
                String.format("Cluster unavailable: %d/%d replicas alive (need %d for quorum)",
                        aliveCount, quorumRequired * 2 - 1, quorumRequired),
                view, -1);
    }

    /**
     * Creates a view change in progress exception.
     */
    public static ClusterException viewChangeInProgress(int oldView, int newView) {
        return new ClusterException(VIEW_CHANGE_IN_PROGRESS,
                String.format("View change in progress: view %d -> %d", oldView, newView), newView,
                -1);
    }

    /**
     * Creates a not primary exception.
     */
    public static ClusterException notPrimary(int view, int primaryIndex, int thisReplicaIndex) {
        return new ClusterException(NOT_PRIMARY,
                String.format("Not primary: replica %d is primary in view %d (this is replica %d)",
                        primaryIndex, view, thisReplicaIndex),
                view, primaryIndex);
    }
}
