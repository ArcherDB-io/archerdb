#!/usr/bin/env python3
import argparse
import os
import re
import signal
import subprocess
import sys
import time


def load_modules(repo_root, include_stdx):
    unit_tests_path = os.path.join(repo_root, "src", "unit_tests.zig")
    pattern = re.compile(r'@import\("([^"]+\.zig)"\)')
    modules = []
    try:
        with open(unit_tests_path, "r", encoding="utf-8") as handle:
            for line in handle:
                match = pattern.search(line)
                if not match:
                    continue
                import_path = match.group(1)
                module = import_path[:-4].replace("/", ".")
                modules.append(module)
    except OSError as exc:
        raise SystemExit(f"Failed to read {unit_tests_path}: {exc}") from exc

    seen = set()
    unique = []
    for module in modules:
        if module in seen:
            continue
        seen.add(module)
        unique.append(module)

    if include_stdx and "stdx" not in seen:
        unique.insert(0, "stdx")

    return unique


def run_subset(repo_root, modules, timeout_s):
    if not modules:
        return {
            "status": "ok",
            "duration": 0.0,
            "output": "",
            "cmd": [],
        }

    cmd = ["./zig/zig", "build", "test:unit", "--"] + modules
    start = time.monotonic()
    proc = subprocess.Popen(
        cmd,
        cwd=repo_root,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        start_new_session=True,
    )
    try:
        output, _ = proc.communicate(timeout=timeout_s)
        duration = time.monotonic() - start
        status = "ok" if proc.returncode == 0 else "fail"
        return {
            "status": status,
            "duration": duration,
            "output": output or "",
            "cmd": cmd,
        }
    except subprocess.TimeoutExpired:
        duration = time.monotonic() - start
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        output, _ = proc.communicate()
        return {
            "status": "timeout",
            "duration": duration,
            "output": output or "",
            "cmd": cmd,
        }


def find_bad_module(repo_root, modules, timeout_s, cache):
    if not modules:
        return None
    if len(modules) == 1:
        result = cached_run(repo_root, modules, timeout_s, cache)
        return modules[0] if result["status"] != "ok" else None

    mid = len(modules) // 2
    left = modules[:mid]
    right = modules[mid:]

    left_result = cached_run(repo_root, left, timeout_s, cache)
    if left_result["status"] != "ok":
        return find_bad_module(repo_root, left, timeout_s, cache)

    right_result = cached_run(repo_root, right, timeout_s, cache)
    if right_result["status"] != "ok":
        return find_bad_module(repo_root, right, timeout_s, cache)

    return None


def cached_run(repo_root, modules, timeout_s, cache):
    key = tuple(modules)
    if key in cache:
        return cache[key]
    result = run_subset(repo_root, modules, timeout_s)
    cache[key] = result
    status = result["status"]
    duration = result["duration"]
    print(f"[{status:7}] {duration:7.1f}s  {len(modules):3d} modules", flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(
        description="Bisect ArcherDB unit tests to find slow or failing modules.",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=300,
        help="Timeout per test run (seconds).",
    )
    parser.add_argument(
        "--max-bad",
        type=int,
        default=5,
        help="Maximum number of failing modules to report.",
    )
    parser.add_argument(
        "--include-stdx",
        action="store_true",
        help="Include stdx tests in the bisect.",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="List discovered modules and exit.",
    )
    args = parser.parse_args()

    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    modules = load_modules(repo_root, include_stdx=args.include_stdx)

    if args.list:
        for module in modules:
            print(module)
        return 0

    cache = {}
    remaining = list(modules)
    bad_modules = []

    print(f"Modules: {len(modules)}", flush=True)
    print(f"Timeout: {args.timeout}s", flush=True)

    # Attempt to find up to max-bad problematic modules.
    for _ in range(args.max_bad):
        bad = find_bad_module(repo_root, remaining, args.timeout, cache)
        if bad is None:
            break
        bad_modules.append(bad)
        remaining = [module for module in remaining if module != bad]

    if bad_modules:
        print("\nProblematic modules:", flush=True)
        for module in bad_modules:
            print(f"- {module}", flush=True)
        return 1

    print("\nNo failing or timeout modules detected.", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
