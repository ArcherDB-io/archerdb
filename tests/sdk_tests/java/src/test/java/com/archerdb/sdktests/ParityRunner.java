package com.archerdb.sdktests;

import com.archerdb.geo.DeleteResult;
import com.archerdb.geo.ClientConfig;
import com.archerdb.geo.GeoClient;
import com.archerdb.geo.GeoEvent;
import com.archerdb.geo.InsertGeoEventsError;
import com.archerdb.geo.QueryLatestFilter;
import com.archerdb.geo.QueryPolygonFilter;
import com.archerdb.geo.QueryRadiusFilter;
import com.archerdb.geo.QueryResult;
import com.archerdb.geo.RegionConfig;
import com.archerdb.geo.ShardInfo;
import com.archerdb.geo.StatusResponse;
import com.archerdb.geo.TopologyResponse;
import com.archerdb.geo.TtlClearResponse;
import com.archerdb.geo.TtlExtendResponse;
import com.archerdb.geo.TtlSetResponse;
import com.archerdb.geo.UInt128;
import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.google.gson.JsonPrimitive;

import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;

public final class ParityRunner {
    private static final Gson GSON = new GsonBuilder().serializeNulls().create();
    private static final Pattern DECIMAL_PATTERN = Pattern.compile("^[+-]?\\d+$");
    private static final Pattern HEX_PATTERN = Pattern.compile("^(0x)?[0-9a-fA-F]+$");
    private static final BigInteger MASK_64 = BigInteger.ONE.shiftLeft(64).subtract(BigInteger.ONE);

    private ParityRunner() {}

    public static void main(String[] args) {
        if (args.length < 1) {
            printError("operation argument required");
            return;
        }

        final String operation = args[0];
        final JsonObject input;
        try {
            input = readInput();
        } catch (Exception e) {
            printError("invalid input JSON: " + e.getMessage());
            return;
        }

        final String address = parseServerAddress(System.getenv("ARCHERDB_URL"));

        ClientConfig config = ClientConfig.builder()
                .setClusterId(UInt128.fromLong(0L))
                .addRegion(RegionConfig.primary("default", address))
                .setRequestTimeoutMs(120_000)
                .build();

        try (GeoClient client = GeoClient.create(config)) {
            JsonObject result = runOperation(client, operation, input);
            System.out.println(GSON.toJson(result));
        } catch (Exception e) {
            printError(e.getMessage() == null ? e.toString() : e.getMessage());
        }
    }

    private static JsonObject runOperation(GeoClient client, String operation, JsonObject input)
            throws Exception {
        switch (operation) {
            case "ping":
                return object("success", client.ping());

            case "status":
                return formatStatus(client.getStatus());

            case "topology":
                return formatTopology(client.getTopology());

            case "insert":
                return runInsert(client, input, false);

            case "upsert":
                return runInsert(client, input, true);

            case "delete":
                return runDelete(client, input);

            case "query-uuid":
                return runQueryUuid(client, input);

            case "query-uuid-batch":
                return runQueryUuidBatch(client, input);

            case "query-radius":
                return runQueryRadius(client, input);

            case "query-polygon":
                return runQueryPolygon(client, input);

            case "query-latest":
                return runQueryLatest(client, input);

            case "ttl-set":
                return runTtlSet(client, input);

            case "ttl-extend":
                return runTtlExtend(client, input);

            case "ttl-clear":
                return runTtlClear(client, input);

            default:
                return object("error", "Unknown operation: " + operation);
        }
    }

    private static JsonObject runInsert(GeoClient client, JsonObject input, boolean upsert)
            throws Exception {
        List<GeoEvent> validEvents = new ArrayList<>();
        List<Integer> validToOriginalIndex = new ArrayList<>();
        JsonArray results = new JsonArray();
        int inputCount = 0;

        JsonElement eventsElement = input.get("events");
        if (eventsElement != null && eventsElement.isJsonArray()) {
            JsonArray inputEvents = eventsElement.getAsJsonArray();
            inputCount = inputEvents.size();
            for (int i = 0; i < inputEvents.size(); i++) {
                JsonElement element = inputEvents.get(i);
                if (!element.isJsonObject()) {
                    continue;
                }

                try {
                    validEvents.add(buildEvent(element.getAsJsonObject()));
                    validToOriginalIndex.add(i);
                } catch (IllegalArgumentException e) {
                    Integer mappedCode = mapClientValidationCode(e.getMessage());
                    if (mappedCode == null) {
                        throw e;
                    }
                    JsonObject localError = new JsonObject();
                    localError.addProperty("index", i);
                    localError.addProperty("code", mappedCode);
                    results.add(localError);
                }
            }
        }

        List<InsertGeoEventsError> errors = validEvents.isEmpty()
                ? Collections.emptyList()
                : (upsert ? client.upsertEvents(validEvents) : client.insertEvents(validEvents));
        for (InsertGeoEventsError err : errors) {
            JsonObject item = new JsonObject();
            int originalIndex = err.getIndex() < validToOriginalIndex.size()
                    ? validToOriginalIndex.get(err.getIndex()) : err.getIndex();
            item.addProperty("index", originalIndex);
            item.addProperty("code", err.getResult().getCode());
            results.add(item);
        }

        JsonObject output = new JsonObject();
        output.addProperty("result_code", 0);
        output.addProperty("count", inputCount);
        output.add("results", results);
        return output;
    }

    private static JsonObject runDelete(GeoClient client, JsonObject input) throws Exception {
        List<UInt128> entityIds = extractEntityIds(input);
        for (UInt128 entityId : entityIds) {
            if (entityId.isZero()) {
                return object("error", "entity_id must not be zero");
            }
        }
        DeleteResult result = client.deleteEntities(entityIds);
        JsonObject output = new JsonObject();
        output.addProperty("deleted_count", result.getDeletedCount());
        output.addProperty("not_found_count", result.getNotFoundCount());
        return output;
    }

    private static JsonObject runQueryUuid(GeoClient client, JsonObject input) throws Exception {
        UInt128 entityId = toEntityId(input.get("entity_id"));
        GeoEvent event = client.getLatestByUuid(entityId);

        JsonObject output = new JsonObject();
        if (event == null) {
            output.addProperty("found", false);
            output.addProperty("event", (String) null);
        } else {
            output.addProperty("found", true);
            output.add("event", formatEvent(event));
        }
        return output;
    }

    private static JsonObject runQueryUuidBatch(GeoClient client, JsonObject input)
            throws Exception {
        List<UInt128> entityIds = extractEntityIds(input);
        JsonArray events = new JsonArray();
        JsonArray notFoundEntityIds = new JsonArray();

        for (UInt128 entityId : entityIds) {
            GeoEvent event = client.getLatestByUuid(entityId);
            if (event == null) {
                notFoundEntityIds.add(uint128ToJsonNumber(entityId));
            } else {
                events.add(formatEvent(event));
            }
        }

        JsonObject output = new JsonObject();
        output.addProperty("found_count", events.size());
        output.addProperty("not_found_count", notFoundEntityIds.size());
        output.add("events", events);
        output.add("not_found_entity_ids", notFoundEntityIds);
        return output;
    }

    private static JsonObject runQueryRadius(GeoClient client, JsonObject input) throws Exception {
        JsonElement latElement = firstValue(input, "latitude", "center_latitude", "center_lat");
        JsonElement lonElement = firstValue(input, "longitude", "center_longitude", "center_lon");
        JsonElement radiusElement = input.get("radius_m");
        if (latElement == null || lonElement == null || radiusElement == null) {
            return object("error", "query-radius requires latitude/longitude/radius_m");
        }

        QueryRadiusFilter.Builder builder = new QueryRadiusFilter.Builder()
                .setCenterLatitude(asDouble(latElement, 0))
                .setCenterLongitude(asDouble(lonElement, 0))
                .setRadiusMeters(asDouble(radiusElement, 0))
                .setLimit(asInt(input.get("limit"), 1000))
                .setTimestampMin(asLong(input.get("timestamp_min"), 0))
                .setTimestampMax(asLong(input.get("timestamp_max"), 0))
                .setGroupId(asLong(input.get("group_id"), 0));

        QueryResult result = client.queryRadius(builder.build());
        return formatQueryResult(result);
    }

    private static JsonObject runQueryPolygon(GeoClient client, JsonObject input)
            throws Exception {
        QueryPolygonFilter.Builder builder = new QueryPolygonFilter.Builder();
        for (double[] vertex : parseVertices(input.get("vertices"))) {
            builder.addVertex(vertex[0], vertex[1]);
        }

        JsonElement holesElement = input.get("holes");
        if (holesElement != null && holesElement.isJsonArray()) {
            for (JsonElement holeElement : holesElement.getAsJsonArray()) {
                List<double[]> holeVertices = parseVertices(holeElement);
                if (holeVertices.isEmpty()) {
                    continue;
                }
                double[][] hole = new double[holeVertices.size()][2];
                for (int i = 0; i < holeVertices.size(); i++) {
                    hole[i][0] = holeVertices.get(i)[0];
                    hole[i][1] = holeVertices.get(i)[1];
                }
                builder.addHole(hole);
            }
        }

        builder.setLimit(asInt(input.get("limit"), 1000))
                .setTimestampMin(asLong(input.get("timestamp_min"), 0))
                .setTimestampMax(asLong(input.get("timestamp_max"), 0))
                .setGroupId(asLong(input.get("group_id"), 0));

        QueryResult result = client.queryPolygon(builder.build());
        return formatQueryResult(result);
    }

    private static JsonObject runQueryLatest(GeoClient client, JsonObject input)
            throws Exception {
        QueryLatestFilter filter = new QueryLatestFilter(
                asInt(input.get("limit"), 100),
                asLong(input.get("group_id"), 0),
                asLong(input.get("cursor_timestamp"), 0));
        return formatQueryResult(client.queryLatest(filter));
    }

    private static JsonObject runTtlSet(GeoClient client, JsonObject input) throws Exception {
        UInt128 entityId = toEntityId(input.get("entity_id"));
        int ttlSeconds = asInt(input.get("ttl_seconds"), 0);
        TtlSetResponse result = client.setTtl(entityId, ttlSeconds);

        JsonObject output = new JsonObject();
        output.add("entity_id", uint128ToJsonNumber(entityId));
        output.addProperty("previous_ttl_seconds", result.getPreviousTtlSeconds());
        output.addProperty("new_ttl_seconds", result.getNewTtlSeconds());
        output.addProperty("result_code", result.getResult().getCode());
        return output;
    }

    private static JsonObject runTtlExtend(GeoClient client, JsonObject input)
            throws Exception {
        UInt128 entityId = toEntityId(input.get("entity_id"));
        int extensionSeconds = asInt(input.get("extension_seconds"),
                asInt(input.get("extend_by_seconds"), 0));
        TtlExtendResponse result = client.extendTtl(entityId, extensionSeconds);

        JsonObject output = new JsonObject();
        output.add("entity_id", uint128ToJsonNumber(entityId));
        output.addProperty("previous_ttl_seconds", result.getPreviousTtlSeconds());
        output.addProperty("new_ttl_seconds", result.getNewTtlSeconds());
        output.addProperty("result_code", result.getResult().getCode());
        return output;
    }

    private static JsonObject runTtlClear(GeoClient client, JsonObject input)
            throws Exception {
        if (input.has("query_entity_id")) {
            UInt128 queryEntityId = toEntityId(input.get("query_entity_id"));
            GeoEvent event = client.getLatestByUuid(queryEntityId);

            JsonObject output = new JsonObject();
            output.addProperty("entity_still_exists", event != null);
            return output;
        }

        UInt128 entityId = toEntityId(input.get("entity_id"));
        TtlClearResponse result = client.clearTtl(entityId);

        JsonObject output = new JsonObject();
        output.add("entity_id", uint128ToJsonNumber(entityId));
        output.addProperty("previous_ttl_seconds", result.getPreviousTtlSeconds());
        output.addProperty("result_code", result.getResult().getCode());
        return output;
    }

    private static JsonObject formatStatus(StatusResponse status) {
        JsonObject output = new JsonObject();
        output.addProperty("ram_index_count", status.getRamIndexCount());
        output.addProperty("ram_index_capacity", status.getRamIndexCapacity());
        output.addProperty("ram_index_load_pct", status.getRamIndexLoadPct());
        output.addProperty("tombstone_count", status.getTombstoneCount());
        output.addProperty("ttl_expirations", status.getTtlExpirations());
        output.addProperty("deletion_count", status.getDeletionCount());
        return output;
    }

    private static JsonObject formatTopology(TopologyResponse topology) {
        Map<String, String> rolesByAddress = new HashMap<>();
        for (ShardInfo shard : topology.getShards()) {
            if (shard.getPrimary() != null && !shard.getPrimary().isEmpty()) {
                rolesByAddress.put(shard.getPrimary(), "primary");
            }
            for (String replica : shard.getReplicas()) {
                if (replica == null || replica.isEmpty()) {
                    continue;
                }
                rolesByAddress.putIfAbsent(replica, "replica");
            }
        }

        List<Map.Entry<String, String>> entries = new ArrayList<>(rolesByAddress.entrySet());
        entries.sort(Comparator.comparing(Map.Entry::getKey));

        JsonArray nodes = new JsonArray();
        for (Map.Entry<String, String> entry : entries) {
            JsonObject node = new JsonObject();
            node.addProperty("address", entry.getKey());
            node.addProperty("role", entry.getValue());
            nodes.add(node);
        }

        JsonObject output = new JsonObject();
        output.add("nodes", nodes);
        return output;
    }

    private static JsonObject formatQueryResult(QueryResult result) {
        JsonArray events = new JsonArray();
        for (GeoEvent event : result.getEvents()) {
            events.add(formatEvent(event));
        }

        JsonObject output = new JsonObject();
        output.addProperty("count", events.size());
        output.addProperty("has_more", result.hasMore());
        output.add("events", events);
        return output;
    }

    private static JsonObject formatEvent(GeoEvent event) {
        JsonObject output = new JsonObject();
        output.add("entity_id", uint128ToJsonNumber(event.getEntityId()));
        output.addProperty("latitude", event.getLatitude());
        output.addProperty("longitude", event.getLongitude());
        output.addProperty("timestamp", event.getTimestamp());
        output.add("correlation_id", uint128ToJsonNumber(event.getCorrelationId()));
        output.add("user_data", uint128ToJsonNumber(event.getUserData()));
        output.addProperty("group_id", event.getGroupId());
        output.addProperty("ttl_seconds", event.getTtlSeconds());
        return output;
    }

    private static List<GeoEvent> buildEvents(JsonElement eventsElement) throws Exception {
        List<GeoEvent> events = new ArrayList<>();
        if (eventsElement == null || !eventsElement.isJsonArray()) {
            return events;
        }
        for (JsonElement element : eventsElement.getAsJsonArray()) {
            if (!element.isJsonObject()) {
                continue;
            }
            events.add(buildEvent(element.getAsJsonObject()));
        }
        return events;
    }

    private static GeoEvent buildEvent(JsonObject raw) throws Exception {
        UInt128 entityId = toEntityId(raw.get("entity_id"));
        UInt128 correlationId = toEntityId(raw.get("correlation_id"));
        UInt128 userData = toEntityId(raw.get("user_data"));

        double latitude = raw.has("latitude") ? asDouble(raw.get("latitude"), 0)
                : asDouble(raw.get("lat_nano"), 0) / 1_000_000_000.0;
        double longitude = raw.has("longitude") ? asDouble(raw.get("longitude"), 0)
                : asDouble(raw.get("lon_nano"), 0) / 1_000_000_000.0;

        GeoEvent.Builder builder = new GeoEvent.Builder()
                .setEntityId(entityId)
                .setCorrelationId(correlationId)
                .setUserData(userData)
                .setLatitude(latitude)
                .setLongitude(longitude)
                .setGroupId(asLong(raw.get("group_id"), 0))
                .setAltitude(asDouble(raw.get("altitude_m"), 0))
                .setVelocity(asDouble(raw.get("velocity_mps"), 0))
                .setTtlSeconds(asInt(raw.get("ttl_seconds"), 0))
                .setAccuracy(asDouble(raw.get("accuracy_m"), 0))
                .setHeading(asDouble(raw.get("heading"), 0))
                .setFlags((short) asInt(raw.get("flags"), 0));

        if (raw.has("timestamp")) {
            long timestampNs = asLong(raw.get("timestamp"), 0) * 1_000_000_000L;
            builder.setTimestamp(timestampNs);
        }

        return builder.build();
    }

    private static List<UInt128> extractEntityIds(JsonObject input) throws Exception {
        if (input.has("entity_ids") && input.get("entity_ids").isJsonArray()) {
            List<UInt128> ids = new ArrayList<>();
            for (JsonElement element : input.getAsJsonArray("entity_ids")) {
                ids.add(toEntityId(element));
            }
            return ids;
        }

        if (input.has("entity_ids_range") && input.get("entity_ids_range").isJsonObject()) {
            JsonObject range = input.getAsJsonObject("entity_ids_range");
            long start = asLong(range.get("start"), 0);
            long count = asLong(range.get("count"), 0);
            if (count < 0) {
                count = 0;
            }
            List<UInt128> ids = new ArrayList<>();
            for (long i = 0; i < count; i++) {
                ids.add(UInt128.of(start + i));
            }
            return ids;
        }

        return new ArrayList<>();
    }

    private static List<double[]> parseVertices(JsonElement verticesElement) {
        List<double[]> vertices = new ArrayList<>();
        if (verticesElement == null || !verticesElement.isJsonArray()) {
            return vertices;
        }
        for (JsonElement vertexElement : verticesElement.getAsJsonArray()) {
            double[] vertex = parseVertex(vertexElement);
            if (vertex != null) {
                vertices.add(vertex);
            }
        }
        return vertices;
    }

    private static double[] parseVertex(JsonElement element) {
        if (element == null) {
            return null;
        }
        if (element.isJsonArray()) {
            JsonArray arr = element.getAsJsonArray();
            if (arr.size() == 2) {
                return new double[] {asDouble(arr.get(0), 0), asDouble(arr.get(1), 0)};
            }
        } else if (element.isJsonObject()) {
            JsonObject obj = element.getAsJsonObject();
            JsonElement lat = firstValue(obj, "lat", "latitude");
            JsonElement lon = firstValue(obj, "lon", "longitude");
            if (lat != null && lon != null) {
                return new double[] {asDouble(lat, 0), asDouble(lon, 0)};
            }
        }
        return null;
    }

    private static UInt128 toEntityId(JsonElement element) throws Exception {
        if (element == null || element.isJsonNull()) {
            return UInt128.ZERO;
        }

        if (element.isJsonPrimitive()) {
            JsonPrimitive primitive = element.getAsJsonPrimitive();
            if (primitive.isNumber()) {
                return uint128FromBigInteger(primitive.getAsBigDecimal().toBigInteger());
            }
            if (primitive.isString()) {
                return entityIdFromString(primitive.getAsString());
            }
        }

        throw new IllegalArgumentException("Unsupported entity_id: " + element);
    }

    private static UInt128 entityIdFromString(String raw) throws Exception {
        String trimmed = raw == null ? "" : raw.trim();
        if (trimmed.isEmpty()) {
            return UInt128.ZERO;
        }

        if (DECIMAL_PATTERN.matcher(trimmed).matches()) {
            return uint128FromBigInteger(new BigInteger(trimmed));
        }

        String hexCandidate = trimmed.startsWith("0x") || trimmed.startsWith("0X")
                ? trimmed.substring(2) : trimmed;
        if (HEX_PATTERN.matcher(trimmed).matches() && !hexCandidate.isEmpty()) {
            return uint128FromBigInteger(new BigInteger(hexCandidate, 16));
        }

        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        byte[] hash = digest.digest(trimmed.getBytes(StandardCharsets.UTF_8));
        byte[] first16 = new byte[16];
        System.arraycopy(hash, 0, first16, 0, 16);
        UInt128 hashed = UInt128.fromBytes(first16);
        if (hashed.isZero()) {
            return UInt128.of(1L);
        }
        return hashed;
    }

    private static Integer mapClientValidationCode(String message) {
        if (message == null) {
            return null;
        }
        String lowered = message.toLowerCase();
        if (lowered.contains("latitude") && lowered.contains("out of range")) {
            return 9; // LAT_OUT_OF_RANGE
        }
        if (lowered.contains("longitude") && lowered.contains("out of range")) {
            return 10; // LON_OUT_OF_RANGE
        }
        if (lowered.contains("entity_id") && lowered.contains("zero")) {
            return 7; // ENTITY_ID_MUST_NOT_BE_ZERO
        }
        return null;
    }

    private static UInt128 uint128FromBigInteger(BigInteger value) {
        if (value.signum() < 0) {
            value = value.negate();
        }
        BigInteger lo = value.and(MASK_64);
        BigInteger hi = value.shiftRight(64).and(MASK_64);
        return UInt128.of(lo.longValue(), hi.longValue());
    }

    private static JsonPrimitive uint128ToJsonNumber(UInt128 value) {
        return new JsonPrimitive(uint128ToBigInteger(value));
    }

    private static BigInteger uint128ToBigInteger(UInt128 value) {
        BigInteger lo = unsignedLongToBigInteger(value.getLo());
        BigInteger hi = unsignedLongToBigInteger(value.getHi());
        return hi.shiftLeft(64).add(lo);
    }

    private static BigInteger unsignedLongToBigInteger(long value) {
        BigInteger result = BigInteger.valueOf(value & Long.MAX_VALUE);
        if (value < 0) {
            result = result.setBit(63);
        }
        return result;
    }

    private static JsonObject readInput() throws Exception {
        byte[] bytes = System.in.readAllBytes();
        String raw = new String(bytes, StandardCharsets.UTF_8).trim();
        if (raw.isEmpty()) {
            return new JsonObject();
        }
        JsonElement parsed = JsonParser.parseString(raw);
        if (!parsed.isJsonObject()) {
            return new JsonObject();
        }
        return parsed.getAsJsonObject();
    }

    private static String parseServerAddress(String url) {
        if (url == null || url.isBlank()) {
            return "127.0.0.1:7000";
        }
        String address = url.trim().replaceFirst("^https?://", "");
        int slash = address.indexOf('/');
        if (slash >= 0) {
            address = address.substring(0, slash);
        }
        if (address.isBlank()) {
            return "127.0.0.1:7000";
        }
        return address;
    }

    private static JsonElement firstValue(JsonObject object, String... keys) {
        for (String key : keys) {
            if (object.has(key)) {
                return object.get(key);
            }
        }
        return null;
    }

    private static double asDouble(JsonElement element, double defaultValue) {
        if (element == null || element.isJsonNull()) {
            return defaultValue;
        }
        try {
            if (element.isJsonPrimitive() && element.getAsJsonPrimitive().isNumber()) {
                return element.getAsDouble();
            }
            if (element.isJsonPrimitive() && element.getAsJsonPrimitive().isString()) {
                return Double.parseDouble(element.getAsString());
            }
        } catch (Exception ignored) {
            // Fall through.
        }
        return defaultValue;
    }

    private static int asInt(JsonElement element, int defaultValue) {
        if (element == null || element.isJsonNull()) {
            return defaultValue;
        }
        try {
            if (element.isJsonPrimitive() && element.getAsJsonPrimitive().isNumber()) {
                return element.getAsInt();
            }
            if (element.isJsonPrimitive() && element.getAsJsonPrimitive().isString()) {
                return Integer.parseInt(element.getAsString());
            }
        } catch (Exception ignored) {
            // Fall through.
        }
        return defaultValue;
    }

    private static long asLong(JsonElement element, long defaultValue) {
        if (element == null || element.isJsonNull()) {
            return defaultValue;
        }
        try {
            if (element.isJsonPrimitive() && element.getAsJsonPrimitive().isNumber()) {
                return element.getAsBigDecimal().longValue();
            }
            if (element.isJsonPrimitive() && element.getAsJsonPrimitive().isString()) {
                return Long.parseLong(element.getAsString());
            }
        } catch (Exception ignored) {
            // Fall through.
        }
        return defaultValue;
    }

    private static JsonObject object(String key, Object value) {
        JsonObject obj = new JsonObject();
        if (value instanceof Boolean) {
            obj.addProperty(key, (Boolean) value);
        } else if (value instanceof Number) {
            obj.addProperty(key, (Number) value);
        } else if (value == null) {
            obj.add(key, null);
        } else {
            obj.addProperty(key, String.valueOf(value));
        }
        return obj;
    }

    private static void printError(String message) {
        JsonObject error = new JsonObject();
        error.addProperty("error", message == null ? "unknown error" : message);
        System.out.println(GSON.toJson(error));
    }
}
