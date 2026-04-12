# SDK Comparison Matrix

This matrix summarizes the common ArcherDB operation surface that is intended to behave consistently across all five SDKs.

## Core Operation Matrix

| Feature | Python | Node.js | Go | Java | C |
|---------|--------|---------|----|------|---|
| Insert events | yes | yes | yes | yes | yes |
| Upsert events | yes | yes | yes | yes | yes |
| Delete entities | yes | yes | yes | yes | yes |
| Query by UUID | yes | yes | yes | yes | yes |
| Batch query by UUID | yes | yes | yes | yes | yes |
| Radius query | yes | yes | yes | yes | yes |
| Polygon query | yes | yes | yes | yes | yes |
| Latest query | yes | yes | yes | yes | yes |
| Ping | yes | yes | yes | yes | yes |
| Status | yes | yes | yes | yes | yes |
| Topology discovery | yes | yes | yes | yes | yes |
| TTL set | yes | yes | yes | yes | yes |
| TTL extend | yes | yes | yes | yes | yes |
| TTL clear | yes | yes | yes | yes | yes |

## Packaging And Ergonomics

| Concern | Python | Node.js | Go | Java | C |
|---------|--------|---------|----|------|---|
| Generated README | yes | yes | yes | yes | no |
| Native binding layer | yes | yes | yes | yes | direct C ABI |
| 128-bit IDs ergonomic type | Python `int` | `BigInt` | custom `Uint128` | wrapper types | raw struct / integer API |
| Thread-safe client abstraction | yes | yes | yes | yes | manual coordination required |
| Lowest-level manual control | medium | low | medium | medium | high |

## Validation Notes

- Repo parity evidence is summarized in [docs/PARITY.md](/home/g/archerdb/docs/PARITY.md).
- SDK-specific setup, examples, and type details live in the language READMEs under [`src/clients/`](/home/g/archerdb/src/clients).
- The C SDK is intentionally the lowest-level interface and exposes callback- and buffer-oriented behavior directly. See [SDK Limitations](../SDK_LIMITATIONS.md).
