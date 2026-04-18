# Runbook — Kernel-crash durability verification

This runbook drives the `scripts/durability-kernel-crash.sh` harness, which boots
ArcherDB inside a QEMU VM, runs a write workload, hard-resets the VM from the QEMU
monitor, and then verifies that the data file is still consistent on the next boot.

It catches regressions in the **checkpoint + WAL replay path** that local-only
crash testing (`SIGKILL` + restart) cannot catch: dirty pages held in the guest
kernel page cache, disk cache flushing, `fsync` ordering under I/O pressure, and
controller write reordering.

## When to run

- After any change to: `src/vsr/journal.zig`, `src/storage.zig`, `src/lsm/grid.zig`,
  the checkpoint artifact path (`src/archerdb/checkpoint_artifact.zig`), or the
  underlying IO plumbing in `src/io/linux.zig`.
- Before a release candidate that touches durability claims in the operations
  runbook.
- When investigating a field report of "replica lost data after a power event".

## When NOT to run

- For routine changes unrelated to durability (CI's VOPR is sufficient).
- On machines without KVM access — the harness falls back to TCG, which is 5–10×
  slower and usually not worth the wall-clock time.

## Prerequisites

On the host:

```
sudo apt install qemu-system-x86 qemu-utils cloud-image-utils genisoimage socat
sudo usermod -aG kvm "$USER"   # then re-login so /dev/kvm is accessible
```

Download a base cloud image once:

```
cd ~/ci-assets
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
```

## Run

```
./scripts/durability-kernel-crash.sh \
    --image ~/ci-assets/noble-server-cloudimg-amd64.img \
    --crash-after 60s
```

The script builds ArcherDB from source, boots a VM, launches `archerdb start`
plus a continuous insert workload driven by `archerdb repl`, waits for
`--crash-after` seconds, then issues `system_reset` via the QEMU monitor. It
reboots the same data disk and runs `archerdb verify`. Exit code:

- `0` — `PASS: kernel-crash durability — data file verified after hard reset`
- `1` — `FAIL: archerdb verify did not succeed` (recovery log tail is printed)
- `2` — setup error (missing tool, missing image)

## Expected runtime

- Build: ~2 min on a fresh machine, cached afterward.
- Workload + crash: `--crash-after` seconds (default 60).
- Recovery boot + verify: ~30–60 s under KVM, up to 5 min under TCG.

## Tuning knobs

| Flag | Default | When to change |
|---|---|---|
| `--crash-after` | `60s` | Longer to exercise more checkpoints; shorter for a quick smoke. |
| `--ram-mb` | `2048` | Increase if you see OOM kills in `recovery.log`. |
| `--data-disk-gb` | `2` | Increase if the workload generates more than ~1 GB of LSM data. |
| `--workload-rate` | `200` events/sec | Cranking this up stresses the write path more aggressively. |
| `--keep-artifacts` | off | Keeps the VM overlays, data disk, and logs under `$WORKDIR` for forensics. |

## Interpreting failures

**`FAIL: recovery did not complete within 120s`**
The recovery VM hung before `archerdb verify` printed a result. Common causes:
- The replica got stuck replaying a large WAL — grow `--ram-mb` and retry.
- A deadlock in the recovery path — capture
  `cat "$WORKDIR/recovery.log"` and open an issue.

**`FAIL: archerdb verify did not succeed; recovery log follows:`**
The replica booted but reported corrupted or missing data. This is the actual
regression signal. Grab the recovery log plus the `$WORKDIR/data.qcow2` and
reproduce under `archerdb inspect` for a closer look. Preserve the workdir with
`--keep-artifacts`.

**Workload writer inside the VM is idle**
Check `/var/log/workload.log` via `archerdb repl`-from-host. If it is empty,
cloud-init probably did not pick up the binary ISO — verify the base image
supports cloud-init v24+.

## Known limitations

- **Not a CI gate yet.** Running this harness needs a prebuilt cloud image and
  ~2 minutes of QEMU wall-clock per run; the CI workers don't have either
  today. When they do, this runbook will be supplemented by a nightly CI lane.
- **Does not test disk-firmware-level misbehavior.** Real controllers can
  reorder writes across power cuts in ways `cache=none,aio=native` does not
  model. For that, combine this harness with `dm-flakey`-based injection on the
  host — `scripts/dm_flakey_test.sh` exists as a starting point.
- **Single replica.** Multi-replica kernel-crash scenarios (one replica crashes
  while its peers keep serving) need cluster-scale orchestration — that is a
  separate harness.

## See also

- `src/testing/storage.zig` — simulated Storage with optional
  `available_capacity` for modeling disk pressure without a VM.
- `scripts/dm_flakey_test.sh` — block-layer fault injection on the host.
- `scripts/chaos-test.sh` — process-level crash/restart exercise (no VM).
- Production ENOSPC note at `src/io/linux.zig:1660`.
