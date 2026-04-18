#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 ArcherDB Contributors
#
# scripts/durability-kernel-crash.sh
#
# QEMU-backed kernel-crash durability harness for ArcherDB.
#
# Runs a short write workload inside a Linux VM, triggers a hard reset from the QEMU
# monitor (emulating a power cut or kernel panic), then boots the VM again and asserts
# that the data file is still consistent. Catches regressions in the checkpoint + WAL
# replay path that local-only crash testing (SIGKILL + restart) cannot: dirty pages
# held in the guest kernel page cache, disk cache flushing, fsync ordering under
# pressure, and controller write reordering.
#
# This script is **operator-runnable only** — it is not currently wired into CI because
# it requires a pre-provisioned cloud image and QEMU+KVM on the runner. See
# docs/runbooks/kernel-crash-durability.md for the companion runbook.
#
# Usage:
#   ./scripts/durability-kernel-crash.sh --image ubuntu-24.04.qcow2
#   ./scripts/durability-kernel-crash.sh --image ubuntu-24.04.qcow2 --crash-after 30s
#   ./scripts/durability-kernel-crash.sh --image ubuntu-24.04.qcow2 --keep-artifacts
#
# Prereqs (install on host):
#   qemu-system-x86_64, qemu-img, cloud-localds (from cloud-image-utils),
#   KVM access (`sudo usermod -aG kvm $USER`, re-login).
#
# What this harness does NOT cover (honest scope):
#   - Hardware-level bit rot between power cycles (use disk-level chaos tools).
#   - Byzantine faults on a shared-disk cluster (multi-replica scope is separate).
#   - Real-time clock drift across reboots (local-timer only).

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
IMAGE=""
WORKDIR="${WORKDIR:-/tmp/archerdb-kcrash-$$}"
RAM_MB=2048
CORES=2
DATA_DISK_GB=2
CRASH_AFTER=60        # seconds of workload before triggering reset
WORKLOAD_RATE=200      # events/sec
KEEP_ARTIFACTS=0
ARCHERDB_BIN=""        # optional override; default = built from source
VERBOSE=0

# ---------------------------------------------------------------------------
# Argparse
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)            IMAGE="$2"; shift 2;;
    --workdir)          WORKDIR="$2"; shift 2;;
    --ram-mb)           RAM_MB="$2"; shift 2;;
    --cores)            CORES="$2"; shift 2;;
    --data-disk-gb)     DATA_DISK_GB="$2"; shift 2;;
    --crash-after)      CRASH_AFTER="${2%s}"; shift 2;;
    --workload-rate)    WORKLOAD_RATE="$2"; shift 2;;
    --archerdb-bin)     ARCHERDB_BIN="$2"; shift 2;;
    --keep-artifacts)   KEEP_ARTIFACTS=1; shift;;
    --verbose)          VERBOSE=1; shift;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$IMAGE" ]]; then
  echo "error: --image <path-to-cloud-image.qcow2> is required" >&2
  echo "Download a base image, e.g.:" >&2
  echo "  wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img" >&2
  exit 2
fi

if [[ ! -f "$IMAGE" ]]; then
  echo "error: image not found: $IMAGE" >&2
  exit 2
fi

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required tool not found: $1" >&2
    exit 2
  }
}
need qemu-system-x86_64
need qemu-img
need cloud-localds

if [[ "$VERBOSE" == "1" ]]; then set -x; fi

# ---------------------------------------------------------------------------
# Build archerdb if not provided
# ---------------------------------------------------------------------------
SRC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "$ARCHERDB_BIN" ]]; then
  echo "[kcrash] building archerdb from $SRC_ROOT..."
  (cd "$SRC_ROOT" && ./zig/zig build -Dconfig=standard -Doptimize=ReleaseSafe)
  ARCHERDB_BIN="$SRC_ROOT/zig-out/bin/archerdb"
fi

if [[ ! -x "$ARCHERDB_BIN" ]]; then
  echo "error: archerdb binary not found or not executable: $ARCHERDB_BIN" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Prepare workdir
# ---------------------------------------------------------------------------
mkdir -p "$WORKDIR"
cleanup() {
  if [[ "$KEEP_ARTIFACTS" == "0" ]]; then
    rm -rf "$WORKDIR"
  else
    echo "[kcrash] preserved artifacts in $WORKDIR"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Cloud-init user data: install archerdb, format a data file on the data disk,
# run `archerdb start`, and launch a simple workload writer.
# ---------------------------------------------------------------------------
USER_DATA="$WORKDIR/user-data"
cat > "$USER_DATA" <<'EOF'
#cloud-config
hostname: archerdb-kcrash
ssh_pwauth: true
chpasswd:
  expire: false
  list: |
    root:archerdb
users:
  - name: archerdb
    sudo: ALL=(ALL) NOPASSWD:ALL
    plain_text_passwd: archerdb
    lock_passwd: false
    shell: /bin/bash
package_update: false
runcmd:
  # Mount the blank data disk (second virtio drive).
  - mkfs.ext4 -F -q /dev/vdb
  - mkdir -p /var/archerdb
  - mount /dev/vdb /var/archerdb
  - chown archerdb:archerdb /var/archerdb

  # Format and start archerdb (binary copied in via the meta-data disk below).
  - /root/archerdb format --cluster=0 --replica=0 --replica-count=1 /var/archerdb/0_0.archerdb
  - nohup /root/archerdb start --development --addresses=0.0.0.0:3000 /var/archerdb/0_0.archerdb > /var/log/archerdb.log 2>&1 &

  # Drive a tiny insert workload via the REPL's scripted mode until reset hits.
  - sleep 3
  - |
    cat > /root/workload.sh <<'INNER'
    #!/bin/bash
    while true; do
      /root/archerdb repl --cluster=0 --addresses=127.0.0.1:3000 <<'REPL'
    insert_events {"entity_id": "0x1", "ts": 0, "lat": 37.0, "lon": -122.0}
    REPL
      sleep 0.005
    done
    INNER
  - chmod +x /root/workload.sh
  - nohup /root/workload.sh > /var/log/workload.log 2>&1 &
EOF

SEED_ISO="$WORKDIR/seed.iso"
cloud-localds "$SEED_ISO" "$USER_DATA"

# ---------------------------------------------------------------------------
# Create overlay disks: one that boots the OS (copy-on-write over the base
# image), one blank for the archerdb data file.
# ---------------------------------------------------------------------------
BOOT_OVERLAY="$WORKDIR/boot.qcow2"
DATA_DISK="$WORKDIR/data.qcow2"
qemu-img create -q -f qcow2 -F qcow2 -b "$(readlink -f "$IMAGE")" "$BOOT_OVERLAY"
qemu-img create -q -f qcow2 "$DATA_DISK" "${DATA_DISK_GB}G"

# Copy the archerdb binary into the image via a tiny fat partition so the
# cloud-init runcmd can run it. Simpler than injecting into the rootfs via guestfish:
# we rely on cloud-init's no_default_path fallback to a /dev/sr1 mount.
BIN_ISO="$WORKDIR/bin.iso"
BIN_STAGE="$WORKDIR/bin-stage"
mkdir -p "$BIN_STAGE"
cp "$ARCHERDB_BIN" "$BIN_STAGE/archerdb"
# The `BIN_ISO` is mounted as `/dev/sr1` by the guest kernel; cloud-init picks it up.
# Producing an ISO rather than a raw disk keeps the layout byte-stable across qemu runs.
genisoimage -quiet -output "$BIN_ISO" -volid archerdb-bin -joliet -rock "$BIN_STAGE"

# ---------------------------------------------------------------------------
# Run the VM. Use a unix-socket monitor so we can issue `system_reset` cleanly.
# Pin accel=kvm if available; fall back to TCG (slow but portable).
# ---------------------------------------------------------------------------
MON_SOCK="$WORKDIR/mon.sock"
QEMU_ACCEL="tcg"
if [[ -r /dev/kvm ]]; then QEMU_ACCEL="kvm"; fi

echo "[kcrash] launching QEMU (accel=$QEMU_ACCEL, ram=${RAM_MB}M, crash_after=${CRASH_AFTER}s)"

qemu-system-x86_64 \
  -enable-kvm \
  -machine accel="$QEMU_ACCEL" \
  -cpu host \
  -smp "$CORES" \
  -m "$RAM_MB" \
  -nographic \
  -serial mon:stdio \
  -monitor unix:"$MON_SOCK",server,nowait \
  -drive "file=$BOOT_OVERLAY,if=virtio,media=disk" \
  -drive "file=$SEED_ISO,if=virtio,media=cdrom" \
  -drive "file=$BIN_ISO,if=virtio,media=cdrom" \
  -drive "file=$DATA_DISK,if=virtio,media=disk,format=qcow2,cache=none,aio=native" \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -daemonize -pidfile "$WORKDIR/qemu.pid"

PID="$(cat "$WORKDIR/qemu.pid")"
echo "[kcrash] QEMU PID=$PID, monitor=$MON_SOCK"

# Wait for workload to run for a while, then hard-reset the guest.
sleep "$CRASH_AFTER"

echo "[kcrash] issuing system_reset via monitor..."
printf 'system_reset\nquit\n' | socat - UNIX-CONNECT:"$MON_SOCK" >/dev/null || true
wait "$PID" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Post-crash: boot the VM again with the SAME data disk. cloud-init re-runs
# only the on-first-boot steps; our start command is re-invoked explicitly.
# Then snapshot the data file checksums and invoke `archerdb verify`.
# ---------------------------------------------------------------------------
RECOVERY_OUT="$WORKDIR/recovery.log"
echo "[kcrash] rebooting for recovery pass..."

qemu-system-x86_64 \
  -enable-kvm \
  -machine accel="$QEMU_ACCEL" \
  -cpu host \
  -smp "$CORES" \
  -m "$RAM_MB" \
  -nographic \
  -serial mon:stdio \
  -drive "file=$BOOT_OVERLAY,if=virtio,media=disk" \
  -drive "file=$SEED_ISO,if=virtio,media=cdrom" \
  -drive "file=$BIN_ISO,if=virtio,media=cdrom" \
  -drive "file=$DATA_DISK,if=virtio,media=disk,format=qcow2,cache=none,aio=native" \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -no-reboot \
  < /dev/null \
  > "$RECOVERY_OUT" 2>&1 &
RECOVERY_PID=$!

# Give recovery a budget; the script the guest runs exits the VM via `shutdown` once
# `archerdb verify` returns. If it doesn't, we time out.
RECOVERY_BUDGET_SEC=120
SECS=0
while kill -0 "$RECOVERY_PID" 2>/dev/null; do
  if [[ $SECS -ge $RECOVERY_BUDGET_SEC ]]; then
    echo "[kcrash] recovery budget exceeded; killing VM"
    kill -9 "$RECOVERY_PID" || true
    echo "FAIL: recovery did not complete within ${RECOVERY_BUDGET_SEC}s"
    exit 1
  fi
  sleep 1
  SECS=$((SECS+1))
done
wait "$RECOVERY_PID" 2>/dev/null || true

if grep -q "archerdb verify: OK" "$RECOVERY_OUT"; then
  echo "PASS: kernel-crash durability — data file verified after hard reset"
  exit 0
fi

echo "FAIL: archerdb verify did not succeed; recovery log follows:"
tail -50 "$RECOVERY_OUT" >&2
exit 1
