#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 ArcherDB Contributors
set -e
ROOT="$(dirname "$(dirname "$(dirname "$(dirname "$(realpath "$0")")")")")"
cd "$ROOT"

echo "Building Python client..."
./zig/zig build clients:python

echo "Building Server..."
./zig/zig build

echo "Starting Server..."
./zig-out/bin/archerdb format --cluster=0 --replica=0 --replica-count=1 data.archerdb
./zig-out/bin/archerdb start --addresses=3001 data.archerdb > server.log 2>&1 &
SERVER_PID=$!

trap "kill $SERVER_PID 2>/dev/null; rm -f data.archerdb" EXIT

sleep 2

echo "Running reproduction script..."
export ARCHERDB_ADDRESS="127.0.0.1:3001"
python3 src/clients/python/reproduce_crash.py > python.out 2> python.err || true
cat python.out
echo "--- stderr ---"
cat python.err
