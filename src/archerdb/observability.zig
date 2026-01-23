// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 ArcherDB Contributors
//! Observability module for ArcherDB.
//!
//! Provides distributed tracing capabilities:
//! - Correlation context propagation (W3C Trace Context, B3)
//! - OTLP trace export to Jaeger/Tempo/etc.
//!
//! Example:
//!
//!     const observability = @import("archerdb/observability.zig");
//!
//!     // Parse incoming trace context
//!     const ctx = observability.correlation.CorrelationContext.fromTraceparent(header) orelse
//!         observability.correlation.CorrelationContext.newRoot(replica_id);
//!
//!     // Export spans
//!     var exporter = try observability.trace_export.OtlpTraceExporter.init(allocator, endpoint);
//!     defer exporter.deinit();

pub const correlation = @import("observability/correlation.zig");
pub const trace_export = @import("observability/trace_export.zig");

// Re-export commonly used types for convenience
pub const CorrelationContext = correlation.CorrelationContext;
pub const TraceFlags = correlation.TraceFlags;
pub const OtlpTraceExporter = trace_export.OtlpTraceExporter;
pub const Span = trace_export.Span;
pub const SpanKind = trace_export.SpanKind;
pub const SpanStatus = trace_export.SpanStatus;
pub const Attribute = trace_export.Attribute;
pub const AttributeValue = trace_export.AttributeValue;

// Thread-local context management
pub const setCurrent = correlation.setCurrent;
pub const getCurrent = correlation.getCurrent;

// Span builder helpers
pub const geoSpan = trace_export.geoSpan;

test {
    _ = correlation;
    _ = trace_export;
}
