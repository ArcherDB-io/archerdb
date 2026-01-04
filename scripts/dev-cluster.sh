#!/usr/bin/env bash
#
# dev-cluster.sh - Local development cluster management for ArcherDB
#
# Usage:
#   ./scripts/dev-cluster.sh start [--nodes=N] [--data-dir=PATH] [--base-port=PORT] [--clean]
#   ./scripts/dev-cluster.sh stop
#   ./scripts/dev-cluster.sh status
#   ./scripts/dev-cluster.sh clean
#   ./scripts/dev-cluster.sh logs [replica-index]
#
# Examples:
#   ./scripts/dev-cluster.sh start                    # Start 3-node cluster
#   ./scripts/dev-cluster.sh start --nodes=1         # Start single-node cluster
#   ./scripts/dev-cluster.sh start --nodes=5 --clean # Start 5-node cluster, remove old data
#   ./scripts/dev-cluster.sh stop                    # Stop all replicas
#   ./scripts/dev-cluster.sh status                  # Check cluster status
#   ./scripts/dev-cluster.sh clean                   # Remove all data files
#   ./scripts/dev-cluster.sh logs 0                  # View logs for replica 0
#
# Per spec/developer-tools/spec.md: "local orchestration SHALL require
# <=3 commands to start a 3-node development cluster"
#
# This script makes it a single command.

set -e

# Configuration defaults
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARCHERDB_BIN="${PROJECT_ROOT}/zig-out/bin/archerdb"
DEFAULT_DATA_DIR="${PROJECT_ROOT}/.dev-cluster"
DEFAULT_NODES=3
BASE_PORT=3001
CLUSTER_ID=0

# ANSI colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
COMMAND="${1:-help}"
shift || true

NODES=$DEFAULT_NODES
DATA_DIR=$DEFAULT_DATA_DIR
CLEAN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --nodes=*)
            NODES="${1#*=}"
            ;;
        --data-dir=*)
            DATA_DIR="${1#*=}"
            ;;
        --base-port=*)
            BASE_PORT="${1#*=}"
            ;;
        --clean)
            CLEAN=true
            ;;
        *)
            # For 'logs' command, this is the replica index
            REPLICA_INDEX="$1"
            ;;
    esac
    shift
done

# Validate node count (must be odd for consensus: 1, 3, 5, 7...)
if [[ $((NODES % 2)) -eq 0 ]] && [[ $NODES -ne 1 ]]; then
    echo -e "${RED}Error: Node count must be odd (1, 3, 5, 7...) for consensus${NC}"
    exit 1
fi

# Generate addresses string (e.g., "3001,3002,3003")
generate_addresses() {
    local addrs=""
    for ((i=0; i<NODES; i++)); do
        if [[ -n "$addrs" ]]; then
            addrs="${addrs},"
        fi
        addrs="${addrs}$((BASE_PORT + i))"
    done
    echo "$addrs"
}

# Check if archerdb binary exists
check_binary() {
    if [[ ! -x "$ARCHERDB_BIN" ]]; then
        echo -e "${RED}Error: archerdb binary not found at $ARCHERDB_BIN${NC}"
        echo -e "${YELLOW}Run: ./zig/zig build${NC}"
        exit 1
    fi
}

# Get PID file path for a replica
pid_file() {
    echo "${DATA_DIR}/replica-${1}.pid"
}

# Get log file path for a replica
log_file() {
    echo "${DATA_DIR}/replica-${1}.log"
}

# Get data file path for a replica
data_file() {
    echo "${DATA_DIR}/replica-${1}.archerdb"
}

# Check if a replica is running
is_running() {
    local pidfile
    pidfile=$(pid_file "$1")
    if [[ -f "$pidfile" ]]; then
        local pid
        pid=$(cat "$pidfile")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# Start the cluster
cmd_start() {
    check_binary

    echo -e "${BLUE}Starting ArcherDB development cluster...${NC}"
    echo -e "  Nodes:    ${GREEN}$NODES${NC}"
    echo -e "  Data dir: ${GREEN}$DATA_DIR${NC}"
    echo -e "  Ports:    ${GREEN}$BASE_PORT-$((BASE_PORT + NODES - 1))${NC}"
    echo ""

    # Clean if requested
    if [[ "$CLEAN" == "true" ]]; then
        cmd_clean
    fi

    # Create data directory
    mkdir -p "$DATA_DIR"

    # Check for running replicas
    local running=0
    for ((i=0; i<NODES; i++)); do
        if is_running "$i"; then
            running=$((running + 1))
        fi
    done

    if [[ $running -gt 0 ]]; then
        echo -e "${YELLOW}Warning: $running replica(s) already running. Stop them first or use --clean${NC}"
        exit 1
    fi

    # Format data files if they don't exist
    echo -e "${BLUE}Formatting data files...${NC}"
    for ((i=0; i<NODES; i++)); do
        local df
        df=$(data_file "$i")
        if [[ ! -f "$df" ]]; then
            echo -e "  Formatting replica ${GREEN}$i${NC}..."
            "$ARCHERDB_BIN" format \
                --cluster="$CLUSTER_ID" \
                --replica="$i" \
                --replica-count="$NODES" \
                "$df" 2>&1 | head -5
        else
            echo -e "  Replica ${GREEN}$i${NC} already formatted, skipping"
        fi
    done

    # Start all replicas
    local addresses
    addresses=$(generate_addresses)
    echo ""
    echo -e "${BLUE}Starting replicas...${NC}"

    for ((i=0; i<NODES; i++)); do
        local df lf pf
        df=$(data_file "$i")
        lf=$(log_file "$i")
        pf=$(pid_file "$i")

        echo -e "  Starting replica ${GREEN}$i${NC} on port ${GREEN}$((BASE_PORT + i))${NC}..."

        # Start in background, redirect output to log file
        "$ARCHERDB_BIN" start \
            --addresses="$addresses" \
            "$df" \
            >"$lf" 2>&1 &

        local pid=$!
        echo "$pid" > "$pf"

        # Brief wait to check if it started
        sleep 0.5
        if ! kill -0 "$pid" 2>/dev/null; then
            echo -e "${RED}  Replica $i failed to start. Check log: $lf${NC}"
            tail -10 "$lf"
            exit 1
        fi
    done

    echo ""
    echo -e "${GREEN}Cluster started successfully!${NC}"
    echo ""
    echo -e "Connect using:"
    echo -e "  ${BLUE}$ARCHERDB_BIN repl --cluster=$CLUSTER_ID --addresses=$addresses${NC}"
    echo ""
    echo -e "View logs with:"
    echo -e "  ${BLUE}$0 logs [0-$((NODES-1))]${NC}"
    echo ""
    echo -e "Stop with:"
    echo -e "  ${BLUE}$0 stop${NC}"
}

# Stop the cluster
cmd_stop() {
    echo -e "${BLUE}Stopping ArcherDB development cluster...${NC}"

    local stopped=0

    # Find all PID files
    shopt -s nullglob
    for pidfile in "$DATA_DIR"/replica-*.pid; do
        if [[ -f "$pidfile" ]]; then
            local replica pid
            replica=$(basename "$pidfile" | sed 's/replica-\([0-9]*\)\.pid/\1/')
            pid=$(cat "$pidfile")

            if kill -0 "$pid" 2>/dev/null; then
                echo -e "  Stopping replica ${GREEN}$replica${NC} (PID $pid)..."
                kill "$pid" 2>/dev/null || true

                # Wait for graceful shutdown (up to 5 seconds)
                for ((j=0; j<50; j++)); do
                    if ! kill -0 "$pid" 2>/dev/null; then
                        break
                    fi
                    sleep 0.1
                done

                # Force kill if still running
                if kill -0 "$pid" 2>/dev/null; then
                    echo -e "${YELLOW}  Force killing replica $replica...${NC}"
                    kill -9 "$pid" 2>/dev/null || true
                fi

                stopped=$((stopped + 1))
            fi

            rm -f "$pidfile"
        fi
    done

    if [[ $stopped -eq 0 ]]; then
        echo -e "${YELLOW}No replicas were running${NC}"
    else
        echo -e "${GREEN}Stopped $stopped replica(s)${NC}"
    fi
}

# Show cluster status
cmd_status() {
    echo -e "${BLUE}ArcherDB development cluster status${NC}"
    echo -e "  Data dir: ${GREEN}$DATA_DIR${NC}"
    echo ""

    if [[ ! -d "$DATA_DIR" ]]; then
        echo -e "${YELLOW}No cluster data directory found${NC}"
        exit 0
    fi

    local running=0
    local stopped=0

    # Check all data files
    shopt -s nullglob
    for datafile in "$DATA_DIR"/replica-*.archerdb; do
        if [[ -f "$datafile" ]]; then
            local replica port
            replica=$(basename "$datafile" | sed 's/replica-\([0-9]*\)\.archerdb/\1/')
            port=$((BASE_PORT + replica))

            if is_running "$replica"; then
                local pid
                pid=$(cat "$(pid_file "$replica")")
                echo -e "  Replica ${GREEN}$replica${NC}: ${GREEN}RUNNING${NC} (PID $pid, port $port)"
                running=$((running + 1))
            else
                echo -e "  Replica ${GREEN}$replica${NC}: ${RED}STOPPED${NC} (data exists)"
                stopped=$((stopped + 1))
            fi
        fi
    done

    if [[ $running -eq 0 ]] && [[ $stopped -eq 0 ]]; then
        echo -e "${YELLOW}No replicas found${NC}"
    else
        echo ""
        echo -e "  Running: ${GREEN}$running${NC}, Stopped: ${RED}$stopped${NC}"
    fi
}

# Clean all data files
cmd_clean() {
    echo -e "${BLUE}Cleaning ArcherDB development cluster data...${NC}"

    # Stop first if running
    cmd_stop 2>/dev/null || true

    if [[ -d "$DATA_DIR" ]]; then
        rm -rf "$DATA_DIR"
        echo -e "${GREEN}Removed $DATA_DIR${NC}"
    else
        echo -e "${YELLOW}No data directory to clean${NC}"
    fi
}

# View logs for a replica
cmd_logs() {
    local replica="${REPLICA_INDEX:-0}"
    local lf
    lf=$(log_file "$replica")

    if [[ ! -f "$lf" ]]; then
        echo -e "${RED}No log file found for replica $replica${NC}"
        echo -e "${YELLOW}Expected: $lf${NC}"
        exit 1
    fi

    echo -e "${BLUE}Logs for replica $replica:${NC}"
    echo ""

    # Check if tail supports -F (follow with retry)
    if tail --help 2>&1 | grep -q '\-F'; then
        tail -F "$lf"
    else
        tail -f "$lf"
    fi
}

# Show help
cmd_help() {
    echo "ArcherDB Development Cluster Management"
    echo ""
    echo "Usage:"
    echo "  $0 start [OPTIONS]   Start the development cluster"
    echo "  $0 stop              Stop all replicas"
    echo "  $0 status            Show cluster status"
    echo "  $0 clean             Remove all data files"
    echo "  $0 logs [INDEX]      View logs for a replica (default: 0)"
    echo ""
    echo "Start Options:"
    echo "  --nodes=N            Number of replicas (1, 3, 5, ...) [default: 3]"
    echo "  --data-dir=PATH      Directory for data files [default: .dev-cluster]"
    echo "  --base-port=PORT     Base port number [default: 3001]"
    echo "  --clean              Remove existing data before starting"
    echo ""
    echo "Examples:"
    echo "  $0 start                    # Start 3-node cluster"
    echo "  $0 start --nodes=1          # Start single-node for development"
    echo "  $0 start --nodes=5 --clean  # Start fresh 5-node cluster"
    echo "  $0 stop                     # Stop all replicas"
    echo "  $0 logs 1                   # View replica 1 logs"
    echo ""
    echo "Quick Start (per spec: <=3 commands for 3-node cluster):"
    echo "  1. ./zig/zig build           # Build ArcherDB"
    echo "  2. ./scripts/dev-cluster.sh start  # Start cluster"
    echo ""
    echo "Connect to cluster:"
    echo "  ./zig-out/bin/archerdb repl --cluster=0 --addresses=3001,3002,3003"
}

# Main dispatch
case "$COMMAND" in
    start)
        cmd_start
        ;;
    stop)
        cmd_stop
        ;;
    status)
        cmd_status
        ;;
    clean)
        cmd_clean
        ;;
    logs)
        cmd_logs
        ;;
    help|--help|-h)
        cmd_help
        ;;
    *)
        echo -e "${RED}Unknown command: $COMMAND${NC}"
        echo ""
        cmd_help
        exit 1
        ;;
esac
