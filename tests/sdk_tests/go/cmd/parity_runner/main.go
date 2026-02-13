package main

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"os"
	"sort"
	"strconv"
	"strings"

	archerdb "github.com/archerdb/archerdb-go"
	"github.com/archerdb/archerdb-go/pkg/types"
)

func main() {
	if len(os.Args) < 2 {
		writeJSON(map[string]any{"error": "operation argument required"})
		return
	}
	operation := os.Args[1]

	input, err := readInput()
	if err != nil {
		writeJSON(map[string]any{"error": err.Error()})
		return
	}

	address := parseServerAddress(os.Getenv("ARCHERDB_URL"))
	config := archerdb.GeoClientConfig{
		ClusterID: types.ToUint128(0),
		Addresses: []string{address},
	}

	client, err := archerdb.NewGeoClient(config)
	if err != nil {
		writeJSON(map[string]any{"error": err.Error()})
		return
	}
	defer client.Close()

	result, err := runOperation(client, operation, input)
	if err != nil {
		writeJSON(map[string]any{"error": err.Error()})
		return
	}
	writeJSON(result)
}

func readInput() (map[string]any, error) {
	decoder := json.NewDecoder(os.Stdin)
	decoder.UseNumber()

	var input map[string]any
	err := decoder.Decode(&input)
	if err == nil {
		return input, nil
	}
	if err == io.EOF {
		return map[string]any{}, nil
	}
	return nil, fmt.Errorf("invalid input JSON: %w", err)
}

func parseServerAddress(url string) string {
	trimmed := strings.TrimSpace(url)
	if trimmed == "" {
		return "127.0.0.1:7000"
	}
	trimmed = strings.TrimPrefix(trimmed, "http://")
	trimmed = strings.TrimPrefix(trimmed, "https://")
	if slash := strings.Index(trimmed, "/"); slash >= 0 {
		trimmed = trimmed[:slash]
	}
	if trimmed == "" {
		return "127.0.0.1:7000"
	}
	return trimmed
}

func runOperation(client archerdb.GeoClient, operation string, input map[string]any) (map[string]any, error) {
	switch operation {
	case "ping":
		ok, err := client.Ping()
		if err != nil {
			return nil, err
		}
		return map[string]any{"success": ok}, nil

	case "status":
		status, err := client.GetStatus()
		if err != nil {
			return nil, err
		}
		return map[string]any{
			"ram_index_count":    uint64(status.RAMIndexCount),
			"ram_index_capacity": uint64(status.RAMIndexCapacity),
			"ram_index_load_pct": uint32(status.RAMIndexLoadPct),
			"tombstone_count":    uint64(status.TombstoneCount),
			"ttl_expirations":    uint64(status.TTLExpirations),
			"deletion_count":     uint64(status.DeletionCount),
		}, nil

	case "topology":
		topology, err := client.GetTopology()
		if err != nil {
			return nil, err
		}
		return formatTopology(topology), nil

	case "insert":
		events, err := buildEvents(input["events"])
		if err != nil {
			return nil, err
		}
		errors, err := client.InsertEvents(events)
		if err != nil {
			return nil, err
		}

		results := make([]map[string]any, 0, len(errors))
		for _, insertErr := range errors {
			results = append(results, map[string]any{
				"index": insertErr.Index,
				"code":  int(insertErr.Result),
			})
		}
		return map[string]any{
			"result_code": 0,
			"count":       len(events),
			"results":     results,
		}, nil

	case "upsert":
		events, err := buildEvents(input["events"])
		if err != nil {
			return nil, err
		}
		errors, err := client.UpsertEvents(events)
		if err != nil {
			return nil, err
		}

		results := make([]map[string]any, 0, len(errors))
		for _, upsertErr := range errors {
			results = append(results, map[string]any{
				"index": upsertErr.Index,
				"code":  int(upsertErr.Result),
			})
		}
		return map[string]any{
			"result_code": 0,
			"count":       len(events),
			"results":     results,
		}, nil

	case "delete":
		entityIDs, err := extractEntityIDs(input)
		if err != nil {
			return nil, err
		}
		for _, entityID := range entityIDs {
			if uint128IsZero(entityID) {
				return map[string]any{"error": "entity_id must not be zero"}, nil
			}
		}
		result, err := client.DeleteEntities(entityIDs)
		if err != nil {
			return nil, err
		}
		return map[string]any{
			"deleted_count":   result.DeletedCount,
			"not_found_count": result.NotFoundCount,
		}, nil

	case "query-uuid":
		entityID, err := toEntityID(input["entity_id"])
		if err != nil {
			return nil, err
		}
		event, err := client.GetLatestByUUID(entityID)
		if err != nil {
			return nil, err
		}
		if event == nil {
			return map[string]any{"found": false, "event": nil}, nil
		}
		return map[string]any{"found": true, "event": formatEvent(*event)}, nil

	case "query-uuid-batch":
		entityIDs, err := extractEntityIDs(input)
		if err != nil {
			return nil, err
		}
		result, err := client.QueryUUIDBatch(entityIDs)
		if err != nil {
			return nil, err
		}

		notFoundSet := make(map[int]struct{}, len(result.NotFoundIndices))
		for _, idx := range result.NotFoundIndices {
			notFoundSet[int(idx)] = struct{}{}
		}

		events := make([]map[string]any, 0, len(result.Events))
		notFoundEntityIDs := make([]any, 0, len(result.NotFoundIndices))
		eventIndex := 0
		for i, id := range entityIDs {
			if _, missing := notFoundSet[i]; missing {
				notFoundEntityIDs = append(notFoundEntityIDs, uint128ToJSONNumber(id))
				continue
			}
			if eventIndex < len(result.Events) {
				events = append(events, formatEvent(result.Events[eventIndex]))
				eventIndex++
			}
		}

		return map[string]any{
			"found_count":          len(events),
			"not_found_count":      len(notFoundEntityIDs),
			"events":               events,
			"not_found_entity_ids": notFoundEntityIDs,
		}, nil

	case "query-radius":
		latVal, hasLat := firstValue(input, "latitude", "center_latitude", "center_lat")
		lonVal, hasLon := firstValue(input, "longitude", "center_longitude", "center_lon")
		radiusVal, hasRadius := input["radius_m"]
		if !hasLat || !hasLon || !hasRadius {
			return map[string]any{"error": "query-radius requires latitude/longitude/radius_m"}, nil
		}

		limit := uint32(asInt64(input["limit"], 1000))
		filter, err := types.NewRadiusQuery(
			asFloat64(latVal, 0),
			asFloat64(lonVal, 0),
			asFloat64(radiusVal, 0),
			limit,
		)
		if err != nil {
			return nil, err
		}
		filter.TimestampMin = uint64(asInt64(input["timestamp_min"], 0))
		filter.TimestampMax = uint64(asInt64(input["timestamp_max"], 0))
		filter.GroupID = types.ToUint128(uint64(asInt64(input["group_id"], 0)))

		queryResult, err := client.QueryRadius(filter)
		if err != nil {
			return nil, err
		}
		return formatQueryResult(queryResult), nil

	case "query-polygon":
		vertices := parseVertices(input["vertices"])
		limit := uint32(asInt64(input["limit"], 1000))
		holes := parseHoles(input["holes"])

		var filter types.QueryPolygonFilter
		var err error
		if len(holes) > 0 {
			filter, err = types.NewPolygonQuery(vertices, limit, holes...)
		} else {
			filter, err = types.NewPolygonQuery(vertices, limit)
		}
		if err != nil {
			return nil, err
		}
		filter.TimestampMin = uint64(asInt64(input["timestamp_min"], 0))
		filter.TimestampMax = uint64(asInt64(input["timestamp_max"], 0))
		filter.GroupID = types.ToUint128(uint64(asInt64(input["group_id"], 0)))

		queryResult, err := client.QueryPolygon(filter)
		if err != nil {
			return nil, err
		}
		return formatQueryResult(queryResult), nil

	case "query-latest":
		filter := types.QueryLatestFilter{
			Limit:           uint32(asInt64(input["limit"], 100)),
			GroupID:         uint64(asInt64(input["group_id"], 0)),
			CursorTimestamp: uint64(asInt64(input["cursor_timestamp"], 0)),
		}
		queryResult, err := client.QueryLatest(filter)
		if err != nil {
			return nil, err
		}
		return formatQueryResult(queryResult), nil

	case "ttl-set":
		entityID, err := toEntityID(input["entity_id"])
		if err != nil {
			return nil, err
		}
		ttl := uint32(asInt64(input["ttl_seconds"], 0))
		response, err := client.SetTTL(entityID, ttl)
		if err != nil {
			return nil, err
		}
		return map[string]any{
			"entity_id":            uint128ToJSONNumber(response.EntityID),
			"previous_ttl_seconds": response.PreviousTTLSeconds,
			"new_ttl_seconds":      response.NewTTLSeconds,
			"result_code":          int(response.Result),
		}, nil

	case "ttl-extend":
		entityID, err := toEntityID(input["entity_id"])
		if err != nil {
			return nil, err
		}
		extendBy := uint32(asInt64(input["extension_seconds"], asInt64(input["extend_by_seconds"], 0)))
		response, err := client.ExtendTTL(entityID, extendBy)
		if err != nil {
			return nil, err
		}
		return map[string]any{
			"entity_id":            uint128ToJSONNumber(response.EntityID),
			"previous_ttl_seconds": response.PreviousTTLSeconds,
			"new_ttl_seconds":      response.NewTTLSeconds,
			"result_code":          int(response.Result),
		}, nil

	case "ttl-clear":
		if queryEntityID, ok := input["query_entity_id"]; ok {
			entityID, err := toEntityID(queryEntityID)
			if err != nil {
				return nil, err
			}
			event, err := client.GetLatestByUUID(entityID)
			if err != nil {
				return nil, err
			}
			return map[string]any{
				"entity_still_exists": event != nil,
			}, nil
		}

		entityID, err := toEntityID(input["entity_id"])
		if err != nil {
			return nil, err
		}
		response, err := client.ClearTTL(entityID)
		if err != nil {
			return nil, err
		}
		return map[string]any{
			"entity_id":            uint128ToJSONNumber(response.EntityID),
			"previous_ttl_seconds": response.PreviousTTLSeconds,
			"result_code":          int(response.Result),
		}, nil

	default:
		return map[string]any{"error": fmt.Sprintf("Unknown operation: %s", operation)}, nil
	}
}

func buildEvents(value any) ([]types.GeoEvent, error) {
	eventsRaw, ok := value.([]any)
	if !ok {
		return []types.GeoEvent{}, nil
	}
	events := make([]types.GeoEvent, 0, len(eventsRaw))
	for _, raw := range eventsRaw {
		eventMap, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		event, err := buildEvent(eventMap)
		if err != nil {
			return nil, err
		}
		events = append(events, event)
	}
	return events, nil
}

func buildEvent(raw map[string]any) (types.GeoEvent, error) {
	entityID, err := toEntityID(raw["entity_id"])
	if err != nil {
		return types.GeoEvent{}, err
	}
	correlationID, err := toEntityID(raw["correlation_id"])
	if err != nil {
		return types.GeoEvent{}, err
	}
	userData, err := toEntityID(raw["user_data"])
	if err != nil {
		return types.GeoEvent{}, err
	}

	lat := asFloat64(raw["latitude"], 0)
	lon := asFloat64(raw["longitude"], 0)
	if _, ok := raw["latitude"]; !ok {
		if latNanoRaw, exists := raw["lat_nano"]; exists {
			lat = asFloat64(latNanoRaw, 0) / 1_000_000_000.0
		}
	}
	if _, ok := raw["longitude"]; !ok {
		if lonNanoRaw, exists := raw["lon_nano"]; exists {
			lon = asFloat64(lonNanoRaw, 0) / 1_000_000_000.0
		}
	}

	event := types.GeoEvent{
		EntityID:      entityID,
		CorrelationID: correlationID,
		UserData:      userData,
		LatNano:       types.DegreesToNano(lat),
		LonNano:       types.DegreesToNano(lon),
		GroupID:       uint64(asInt64(raw["group_id"], 0)),
		Timestamp:     uint64(asInt64(raw["timestamp"], 0)) * 1_000_000_000,
		AltitudeMM:    types.MetersToMM(asFloat64(raw["altitude_m"], 0)),
		VelocityMMS:   uint32(asFloat64(raw["velocity_mps"], 0) * 1000.0),
		TTLSeconds:    uint32(asInt64(raw["ttl_seconds"], 0)),
		AccuracyMM:    uint32(asFloat64(raw["accuracy_m"], 0) * 1000.0),
		HeadingCdeg:   types.HeadingToCentidegrees(asFloat64(raw["heading"], 0)),
		Flags:         types.GeoEventFlags(uint16(asInt64(raw["flags"], 0))),
	}

	// Imported events with explicit timestamps must have composite IDs.
	if event.Timestamp != 0 {
		s2CellID := types.ComputeS2CellID(event.LatNano, event.LonNano)
		event.ID = types.PackCompositeID(s2CellID, event.Timestamp)
		event.Flags |= types.GeoEventFlagImported
	}

	return event, nil
}

func extractEntityIDs(input map[string]any) ([]types.Uint128, error) {
	if raw, ok := input["entity_ids"]; ok {
		items, ok := raw.([]any)
		if !ok {
			return []types.Uint128{}, nil
		}
		out := make([]types.Uint128, 0, len(items))
		for _, item := range items {
			id, err := toEntityID(item)
			if err != nil {
				return nil, err
			}
			out = append(out, id)
		}
		return out, nil
	}

	if raw, ok := input["entity_ids_range"]; ok {
		rangeMap, ok := raw.(map[string]any)
		if !ok {
			return []types.Uint128{}, nil
		}
		start := asInt64(rangeMap["start"], 0)
		count := asInt64(rangeMap["count"], 0)
		if count < 0 {
			count = 0
		}
		out := make([]types.Uint128, 0, count)
		for i := int64(0); i < count; i++ {
			out = append(out, types.ToUint128(uint64(start+i)))
		}
		return out, nil
	}

	return []types.Uint128{}, nil
}

func toEntityID(value any) (types.Uint128, error) {
	if value == nil {
		return types.Uint128{}, nil
	}

	switch v := value.(type) {
	case types.Uint128:
		return v, nil
	case json.Number:
		return entityIDFromString(v.String())
	case string:
		return entityIDFromString(v)
	case float64:
		return types.ToUint128(uint64(v)), nil
	case float32:
		return types.ToUint128(uint64(v)), nil
	case int:
		return types.ToUint128(uint64(v)), nil
	case int64:
		return types.ToUint128(uint64(v)), nil
	case int32:
		return types.ToUint128(uint64(v)), nil
	case uint64:
		return types.ToUint128(v), nil
	case uint32:
		return types.ToUint128(uint64(v)), nil
	default:
		return types.Uint128{}, fmt.Errorf("unsupported entity_id type: %T", value)
	}
}

func entityIDFromString(raw string) (types.Uint128, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return types.Uint128{}, nil
	}

	if isDecimal(trimmed) {
		if bigInt, ok := new(big.Int).SetString(trimmed, 10); ok {
			return types.BigIntToUint128(*bigInt), nil
		}
	}

	hexCandidate := trimmed
	if strings.HasPrefix(hexCandidate, "0x") || strings.HasPrefix(hexCandidate, "0X") {
		hexCandidate = hexCandidate[2:]
	}
	if isHex(hexCandidate) {
		if parsed, err := types.HexStringToUint128(hexCandidate); err == nil {
			return parsed, nil
		}
		if bigInt, ok := new(big.Int).SetString(hexCandidate, 16); ok {
			return types.BigIntToUint128(*bigInt), nil
		}
	}

	// Stable fallback for non-numeric IDs.
	digest := sha256.Sum256([]byte(trimmed))
	var bytes [16]byte
	copy(bytes[:], digest[:16])
	id := types.BytesToUint128(bytes)
	if uint128IsZero(id) {
		return types.ToUint128(1), nil
	}
	return id, nil
}

func parseVertices(value any) [][]float64 {
	rawVertices, ok := value.([]any)
	if !ok {
		return [][]float64{}
	}
	vertices := make([][]float64, 0, len(rawVertices))
	for _, rawVertex := range rawVertices {
		if lat, lon, ok := parseVertex(rawVertex); ok {
			vertices = append(vertices, []float64{lat, lon})
		}
	}
	return vertices
}

func parseHoles(value any) [][][]float64 {
	rawHoles, ok := value.([]any)
	if !ok {
		return nil
	}
	holes := make([][][]float64, 0, len(rawHoles))
	for _, rawHole := range rawHoles {
		vertices := parseVertices(rawHole)
		if len(vertices) > 0 {
			holes = append(holes, vertices)
		}
	}
	return holes
}

func parseVertex(value any) (float64, float64, bool) {
	switch v := value.(type) {
	case []any:
		if len(v) == 2 {
			return asFloat64(v[0], 0), asFloat64(v[1], 0), true
		}
	case map[string]any:
		lat, hasLat := firstValue(v, "lat", "latitude")
		lon, hasLon := firstValue(v, "lon", "longitude")
		if hasLat && hasLon {
			return asFloat64(lat, 0), asFloat64(lon, 0), true
		}
	}
	return 0, 0, false
}

func formatQueryResult(result types.QueryResult) map[string]any {
	events := make([]map[string]any, 0, len(result.Events))
	for _, event := range result.Events {
		events = append(events, formatEvent(event))
	}
	return map[string]any{
		"count":    len(events),
		"has_more": result.HasMore,
		"events":   events,
	}
}

func formatEvent(event types.GeoEvent) map[string]any {
	return map[string]any{
		"entity_id":      uint128ToJSONNumber(event.EntityID),
		"latitude":       float64(event.LatNano) / 1_000_000_000.0,
		"longitude":      float64(event.LonNano) / 1_000_000_000.0,
		"timestamp":      uint64(event.Timestamp),
		"correlation_id": uint128ToJSONNumber(event.CorrelationID),
		"user_data":      uint128ToJSONNumber(event.UserData),
		"group_id":       uint64(event.GroupID),
		"ttl_seconds":    uint32(event.TTLSeconds),
	}
}

func formatTopology(topology *types.TopologyResponse) map[string]any {
	if topology == nil {
		return map[string]any{"nodes": []any{}}
	}

	rolesByAddress := make(map[string]string)
	for _, shard := range topology.Shards {
		primary := strings.Trim(shard.Primary, "\x00")
		if primary != "" {
			rolesByAddress[primary] = "primary"
		}
		for _, replica := range shard.Replicas {
			replica = strings.Trim(replica, "\x00")
			if replica == "" {
				continue
			}
			if _, has := rolesByAddress[replica]; !has {
				rolesByAddress[replica] = "replica"
			}
		}
	}

	addresses := make([]string, 0, len(rolesByAddress))
	for address := range rolesByAddress {
		addresses = append(addresses, address)
	}
	sort.Strings(addresses)

	nodes := make([]map[string]any, 0, len(addresses))
	for _, address := range addresses {
		nodes = append(nodes, map[string]any{
			"address": address,
			"role":    rolesByAddress[address],
		})
	}
	return map[string]any{"nodes": nodes}
}

func uint128ToJSONNumber(id types.Uint128) json.Number {
	value := uint128ToBigInt(id)
	return json.Number(value.String())
}

func uint128ToBigInt(id types.Uint128) *big.Int {
	bytes := id.Bytes()
	lo := binary.LittleEndian.Uint64(bytes[:8])
	hi := binary.LittleEndian.Uint64(bytes[8:])

	hiBig := new(big.Int).SetUint64(hi)
	loBig := new(big.Int).SetUint64(lo)

	return new(big.Int).Add(new(big.Int).Lsh(hiBig, 64), loBig)
}

func uint128IsZero(id types.Uint128) bool {
	bytes := id.Bytes()
	for _, b := range bytes {
		if b != 0 {
			return false
		}
	}
	return true
}

func writeJSON(value map[string]any) {
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetEscapeHTML(false)
	_ = encoder.Encode(value)
}

func firstValue(m map[string]any, keys ...string) (any, bool) {
	for _, key := range keys {
		if value, ok := m[key]; ok {
			return value, true
		}
	}
	return nil, false
}

func asFloat64(value any, defaultValue float64) float64 {
	switch v := value.(type) {
	case nil:
		return defaultValue
	case float64:
		return v
	case float32:
		return float64(v)
	case int:
		return float64(v)
	case int64:
		return float64(v)
	case int32:
		return float64(v)
	case uint64:
		return float64(v)
	case uint32:
		return float64(v)
	case json.Number:
		if f, err := v.Float64(); err == nil {
			return f
		}
	case string:
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return f
		}
	}
	return defaultValue
}

func asInt64(value any, defaultValue int64) int64 {
	switch v := value.(type) {
	case nil:
		return defaultValue
	case int:
		return int64(v)
	case int64:
		return v
	case int32:
		return int64(v)
	case uint64:
		return int64(v)
	case uint32:
		return int64(v)
	case float64:
		return int64(v)
	case float32:
		return int64(v)
	case json.Number:
		if i, err := v.Int64(); err == nil {
			return i
		}
		if f, err := v.Float64(); err == nil {
			return int64(f)
		}
	case string:
		if i, err := strconv.ParseInt(v, 10, 64); err == nil {
			return i
		}
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return int64(f)
		}
	}
	return defaultValue
}

func isDecimal(value string) bool {
	if value == "" {
		return false
	}
	for i, ch := range value {
		if i == 0 && (ch == '-' || ch == '+') {
			continue
		}
		if ch < '0' || ch > '9' {
			return false
		}
	}
	return true
}

func isHex(value string) bool {
	if value == "" {
		return false
	}
	for _, ch := range value {
		if (ch >= '0' && ch <= '9') ||
			(ch >= 'a' && ch <= 'f') ||
			(ch >= 'A' && ch <= 'F') {
			continue
		}
		return false
	}
	return true
}
