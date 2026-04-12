// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
package com.archerdb.core;

public final class ClientClosedException extends IllegalStateException {

    public ClientClosedException() {}

    @Override
    public String getMessage() {
        return toString();
    }

    @Override
    public String toString() {
        return "Client was closed.";
    }
}
