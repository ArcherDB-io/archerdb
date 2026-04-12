// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
// Adds reference to sub-folders containing the external (non-Go) files
// required to build the ArcherDB client. Otherwise the `arch_client.h`
// header and library object files would be pruned during `go mod vendor`.
package native
