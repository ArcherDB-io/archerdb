// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 Anthus Labs, Inc.

package com.archerdb.geo;

/**
 * Exception thrown when parsing GeoJSON or WKT format fails.
 */
public class GeoFormatException extends Exception {

    /**
     * Creates a new GeoFormatException with the specified message.
     *
     * @param message the detail message
     */
    public GeoFormatException(String message) {
        super(message);
    }

    /**
     * Creates a new GeoFormatException with the specified message and cause.
     *
     * @param message the detail message
     * @param cause the cause of this exception
     */
    public GeoFormatException(String message, Throwable cause) {
        super(message, cause);
    }
}
