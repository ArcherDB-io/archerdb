package com.archerdb.geo;

import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.function.Consumer;

/**
 * Pluggable logger for SDK internal operations.
 *
 * <p>
 * Per client-sdk/spec.md, the SDK logs at appropriate levels:
 * <ul>
 * <li>DEBUG: Connection state changes, request/response details</li>
 * <li>INFO: Successful connection, session registration</li>
 * <li>WARN: Reconnection, view change handling, retries</li>
 * <li>ERROR: Connection failures, unrecoverable errors</li>
 * </ul>
 *
 * <p>
 * Applications can provide a custom logger via {@link #setLogger(Consumer)}.
 */
public final class ClientLogger {

    /**
     * Log levels.
     */
    public enum Level {
        DEBUG,
        INFO,
        WARN,
        ERROR
    }

    /**
     * Log entry containing all log information.
     */
    public static final class LogEntry {
        private final Level level;
        private final String message;
        private final Instant timestamp;
        private final String traceId;
        private final String spanId;

        LogEntry(Level level, String message, String traceId, String spanId) {
            this.level = level;
            this.message = message;
            this.timestamp = Instant.now();
            this.traceId = traceId;
            this.spanId = spanId;
        }

        public Level getLevel() {
            return level;
        }

        public String getMessage() {
            return message;
        }

        public Instant getTimestamp() {
            return timestamp;
        }

        public String getTraceId() {
            return traceId;
        }

        public String getSpanId() {
            return spanId;
        }

        /**
         * Formats as text log line.
         */
        public String toText() {
            String ts = DateTimeFormatter.ISO_INSTANT.format(timestamp.atOffset(ZoneOffset.UTC));
            if (traceId != null) {
                return String.format("[%s] %s trace=%s span=%s: %s", level, ts, traceId, spanId,
                        message);
            }
            return String.format("[%s] %s: %s", level, ts, message);
        }

        /**
         * Formats as JSON log line.
         */
        public String toJson() {
            StringBuilder sb = new StringBuilder();
            sb.append("{");
            sb.append("\"level\":\"").append(level).append("\"");
            sb.append(",\"timestamp\":\"").append(
                    DateTimeFormatter.ISO_INSTANT.format(timestamp.atOffset(ZoneOffset.UTC)))
                    .append("\"");
            sb.append(",\"message\":\"").append(escapeJson(message)).append("\"");
            if (traceId != null) {
                sb.append(",\"trace_id\":\"").append(traceId).append("\"");
            }
            if (spanId != null) {
                sb.append(",\"span_id\":\"").append(spanId).append("\"");
            }
            sb.append("}");
            return sb.toString();
        }

        private static String escapeJson(String s) {
            return s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n")
                    .replace("\r", "\\r").replace("\t", "\\t");
        }
    }

    private static volatile Consumer<LogEntry> logger = null;
    private static volatile Level minLevel = Level.INFO;
    private static volatile boolean jsonFormat = false;

    // Thread-local trace context
    private static final ThreadLocal<String> currentTraceId = new ThreadLocal<>();
    private static final ThreadLocal<String> currentSpanId = new ThreadLocal<>();

    private ClientLogger() {}

    /**
     * Sets a custom logger to receive log entries.
     */
    public static void setLogger(Consumer<LogEntry> logger) {
        ClientLogger.logger = logger;
    }

    /**
     * Sets the minimum log level.
     */
    public static void setMinLevel(Level level) {
        ClientLogger.minLevel = level;
    }

    /**
     * Sets whether to use JSON format (for default console output).
     */
    public static void setJsonFormat(boolean json) {
        ClientLogger.jsonFormat = json;
    }

    /**
     * Sets the current trace context for this thread.
     */
    public static void setTraceContext(String traceId, String spanId) {
        currentTraceId.set(traceId);
        currentSpanId.set(spanId);
    }

    /**
     * Clears the current trace context for this thread.
     */
    public static void clearTraceContext() {
        currentTraceId.remove();
        currentSpanId.remove();
    }

    /**
     * Logs a message at the specified level.
     */
    public static void log(Level level, String message) {
        if (level.ordinal() < minLevel.ordinal()) {
            return;
        }

        LogEntry entry = new LogEntry(level, message, currentTraceId.get(), currentSpanId.get());

        Consumer<LogEntry> customLogger = logger;
        if (customLogger != null) {
            customLogger.accept(entry);
        } else {
            // Default console output
            String formatted = jsonFormat ? entry.toJson() : entry.toText();
            if (level == Level.ERROR) {
                System.err.println(formatted);
            } else {
                System.out.println(formatted);
            }
        }
    }

    /**
     * Logs a DEBUG message.
     */
    public static void debug(String message) {
        log(Level.DEBUG, message);
    }

    /**
     * Logs a DEBUG message with format args.
     */
    public static void debug(String format, Object... args) {
        if (Level.DEBUG.ordinal() >= minLevel.ordinal()) {
            log(Level.DEBUG, String.format(format, args));
        }
    }

    /**
     * Logs an INFO message.
     */
    public static void info(String message) {
        log(Level.INFO, message);
    }

    /**
     * Logs an INFO message with format args.
     */
    public static void info(String format, Object... args) {
        if (Level.INFO.ordinal() >= minLevel.ordinal()) {
            log(Level.INFO, String.format(format, args));
        }
    }

    /**
     * Logs a WARN message.
     */
    public static void warn(String message) {
        log(Level.WARN, message);
    }

    /**
     * Logs a WARN message with format args.
     */
    public static void warn(String format, Object... args) {
        if (Level.WARN.ordinal() >= minLevel.ordinal()) {
            log(Level.WARN, String.format(format, args));
        }
    }

    /**
     * Logs an ERROR message.
     */
    public static void error(String message) {
        log(Level.ERROR, message);
    }

    /**
     * Logs an ERROR message with format args.
     */
    public static void error(String format, Object... args) {
        if (Level.ERROR.ordinal() >= minLevel.ordinal()) {
            log(Level.ERROR, String.format(format, args));
        }
    }

    /**
     * Logs an ERROR message with exception.
     */
    public static void error(String message, Throwable t) {
        log(Level.ERROR, message + ": " + t.getMessage());
    }
}
