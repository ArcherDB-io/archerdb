#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 ArcherDB Contributors
#
# Deploy Parca agent for continuous profiling
#
# Parca provides always-on profiling with <1% overhead via eBPF.
# Profiles are stored and can be analyzed via the Parca web UI.
#
# Usage:
#   ./scripts/parca-agent.sh start [--server <url>]
#   ./scripts/parca-agent.sh stop
#   ./scripts/parca-agent.sh status

set -euo pipefail

PARCA_AGENT_VERSION="${PARCA_AGENT_VERSION:-0.33.0}"
PARCA_SERVER="${PARCA_SERVER:-http://localhost:7070}"
PARCA_AGENT_BIN="${PARCA_AGENT_BIN:-/usr/local/bin/parca-agent}"

usage() {
    cat <<EOF
Parca Agent Deployment Script

Usage: $0 <command> [options]

Commands:
    start           Start Parca agent
    stop            Stop Parca agent
    status          Check agent status
    install         Download and install Parca agent

Options:
    --server <url>  Parca server URL (default: http://localhost:7070)
    --version <v>   Parca agent version (default: $PARCA_AGENT_VERSION)

Environment Variables:
    PARCA_AGENT_VERSION  Agent version to install (default: 0.33.0)
    PARCA_SERVER         Parca server URL (default: http://localhost:7070)
    PARCA_AGENT_BIN      Path to parca-agent binary (default: /usr/local/bin/parca-agent)

Prerequisites:
    - Linux kernel >= 5.6 with eBPF support
    - Root privileges for eBPF programs
    - Parca server running (or use Parca Cloud)

Quick Start:
    # Install agent
    sudo ./scripts/parca-agent.sh install

    # Start with local Parca server
    sudo ./scripts/parca-agent.sh start

    # Or connect to Parca Cloud
    sudo ./scripts/parca-agent.sh start --server https://grpc.polarsignals.com:443

Examples:
    # Install specific version
    PARCA_AGENT_VERSION=0.32.0 sudo ./scripts/parca-agent.sh install

    # Start with custom server
    ./scripts/parca-agent.sh start --server http://parca.internal:7070

    # Check if agent is running
    ./scripts/parca-agent.sh status

For more information:
    https://www.parca.dev/docs/
    https://github.com/parca-dev/parca-agent
EOF
}

check_prerequisites() {
    # Check kernel version for eBPF support
    local kernel_version
    kernel_version=$(uname -r | cut -d. -f1,2)
    local kernel_major
    kernel_major=$(echo "$kernel_version" | cut -d. -f1)
    local kernel_minor
    kernel_minor=$(echo "$kernel_version" | cut -d. -f2)

    if [[ "$kernel_major" -lt 5 ]] || { [[ "$kernel_major" -eq 5 ]] && [[ "$kernel_minor" -lt 6 ]]; }; then
        echo "Warning: Kernel version $kernel_version may not have full eBPF support."
        echo "Parca agent requires Linux kernel >= 5.6 for best results."
    fi

    # Check for root privileges (needed for eBPF)
    if [[ $EUID -ne 0 ]] && [[ "${1:-}" != "status" ]]; then
        echo "Warning: Parca agent typically requires root privileges for eBPF."
        echo "Consider running with sudo."
    fi
}

install_agent() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) echo "Unsupported architecture: $arch"; exit 1 ;;
    esac

    local os
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    if [[ "$os" != "linux" ]]; then
        echo "Parca agent only supports Linux (eBPF requirement)"
        exit 1
    fi

    echo "Installing Parca agent v${PARCA_AGENT_VERSION} for ${os}/${arch}..."

    local url="https://github.com/parca-dev/parca-agent/releases/download/v${PARCA_AGENT_VERSION}/parca-agent_${PARCA_AGENT_VERSION}_${os}_${arch}.tar.gz"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf $tmp_dir" EXIT

    echo "Downloading from: $url"
    if command -v curl &> /dev/null; then
        curl -sL "$url" | tar -xzf - -C "$tmp_dir"
    elif command -v wget &> /dev/null; then
        wget -qO- "$url" | tar -xzf - -C "$tmp_dir"
    else
        echo "Error: curl or wget required for download"
        exit 1
    fi

    # Install binary
    if [[ -f "$tmp_dir/parca-agent" ]]; then
        sudo install -m 755 "$tmp_dir/parca-agent" "${PARCA_AGENT_BIN}"
        echo "Installed to ${PARCA_AGENT_BIN}"
    else
        echo "Error: parca-agent binary not found in archive"
        exit 1
    fi

    echo "Installation complete. Verify with: ${PARCA_AGENT_BIN} --version"
}

start_agent() {
    check_prerequisites start

    if ! command -v "${PARCA_AGENT_BIN}" &> /dev/null; then
        echo "Error: parca-agent not found at ${PARCA_AGENT_BIN}"
        echo "Run '$0 install' first."
        exit 1
    fi

    if pgrep -f "parca-agent" > /dev/null 2>&1; then
        echo "Parca agent is already running"
        status_agent
        return 0
    fi

    echo "Starting Parca agent..."
    echo "  Server: ${PARCA_SERVER}"
    echo "  Node: $(hostname)"

    # Start agent in background
    sudo "${PARCA_AGENT_BIN}" \
        --remote-store-address="${PARCA_SERVER}" \
        --node="$(hostname)" \
        --log-level=info \
        2>&1 | logger -t parca-agent &

    local pid=$!
    sleep 2

    if ps -p $pid > /dev/null 2>&1; then
        echo "Parca agent started (PID: $pid)"
        echo "Logs: journalctl -t parca-agent -f"
    else
        echo "Error: Parca agent failed to start"
        echo "Check system logs for details"
        exit 1
    fi
}

stop_agent() {
    echo "Stopping Parca agent..."
    if pgrep -f "parca-agent" > /dev/null 2>&1; then
        sudo pkill -f "parca-agent" || true
        sleep 1
        if pgrep -f "parca-agent" > /dev/null 2>&1; then
            echo "Warning: Agent still running, sending SIGKILL"
            sudo pkill -9 -f "parca-agent" || true
        fi
        echo "Parca agent stopped"
    else
        echo "Parca agent is not running"
    fi
}

status_agent() {
    echo "Parca Agent Status"
    echo "=================="

    if pgrep -f "parca-agent" > /dev/null 2>&1; then
        echo "Status: Running"
        echo ""
        echo "Processes:"
        pgrep -af "parca-agent" || true
        echo ""

        # Show resource usage
        if command -v ps &> /dev/null; then
            echo "Resource Usage:"
            ps -p "$(pgrep -f 'parca-agent' | head -1)" -o pid,ppid,%cpu,%mem,rss,vsz,cmd 2>/dev/null || true
        fi
    else
        echo "Status: Not running"

        if [[ -x "${PARCA_AGENT_BIN}" ]]; then
            echo ""
            echo "Agent binary found at: ${PARCA_AGENT_BIN}"
            "${PARCA_AGENT_BIN}" --version 2>/dev/null || true
        else
            echo ""
            echo "Agent binary not found at: ${PARCA_AGENT_BIN}"
            echo "Run '$0 install' to install."
        fi
    fi
}

# Parse arguments
COMMAND="${1:-}"
shift || true

while [[ $# -gt 0 ]]; do
    case $1 in
        --server)
            PARCA_SERVER="$2"
            shift 2
            ;;
        --version)
            PARCA_AGENT_VERSION="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

case "${COMMAND}" in
    start)
        start_agent
        ;;
    stop)
        stop_agent
        ;;
    status)
        status_agent
        ;;
    install)
        install_agent
        ;;
    --help|-h|help)
        usage
        exit 0
        ;;
    "")
        usage
        exit 1
        ;;
    *)
        echo "Unknown command: ${COMMAND}"
        usage
        exit 1
        ;;
esac
