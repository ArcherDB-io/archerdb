window.BENCHMARK_DATA = {
  "lastUpdate": 1775993311686,
  "repoUrl": "https://github.com/ArcherDB-io/archerdb",
  "entries": {
    "Benchmark": [
      {
        "commit": {
          "author": {
            "email": "gevorg@galstyan.am",
            "name": "Gevorg A. Galstyan",
            "username": "gevorggalstyan"
          },
          "committer": {
            "email": "gevorg@galstyan.am",
            "name": "Gevorg A. Galstyan",
            "username": "gevorggalstyan"
          },
          "distinct": true,
          "id": "aec0f1aa0b14b245abf1e0476d46c88b19edbbde",
          "message": "fix(ci): harden coverage benchmark and integration jobs",
          "timestamp": "2026-04-12T13:10:43+02:00",
          "tree_id": "0726f05f2ec3f81389229f8feab3ed05cc3ad13d",
          "url": "https://github.com/ArcherDB-io/archerdb/commit/aec0f1aa0b14b245abf1e0476d46c88b19edbbde"
        },
        "date": 1775993310735,
        "tool": "customSmallerIsBetter",
        "benches": [
          {
            "name": "Insert Throughput",
            "value": 1400617,
            "unit": "events/s"
          },
          {
            "name": "Insert p99 Latency",
            "value": 6,
            "unit": "ms"
          },
          {
            "name": "Radius Query p99 Latency",
            "value": 130,
            "unit": "ms"
          },
          {
            "name": "Polygon Query p99 Latency",
            "value": 102,
            "unit": "ms"
          }
        ]
      }
    ]
  }
}