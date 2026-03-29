#!/usr/bin/env python3
"""
Compute transitive dependency closure for Debian packages.
Uses apt-cache to get dependencies and performs BFS to find all transitive deps.
"""

import sys
import subprocess
import argparse
from collections import deque


def get_direct_dependencies(package):
    """Get direct dependencies of a package using apt-cache."""
    try:
        result = subprocess.run(
            [
                "apt-cache",
                "depends",
                package,
                "--no-recommends",
                "--no-suggests",
                "--no-conflicts",
                "--no-breaks",
                "--no-replaces",
                "--no-enhances",
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode != 0:
            return []

        deps = []
        for line in result.stdout.split("\n"):
            line = line.strip()
            if line and line[0].isalnum():  # Package names start with alphanumeric
                if not line.startswith("<"):  # Skip virtual packages
                    deps.append(line)
        return deps
    except Exception:
        return []


def compute_closure(seeds, skip_set):
    """Compute transitive closure using BFS."""
    visited = set()
    queue = deque()
    result = []

    # Initialize with all seeds
    for seed in seeds:
        queue.append(seed)

    # BFS: process packages until queue is empty
    while queue:
        pkg = queue.popleft()

        # Skip if already visited
        if pkg in visited:
            continue

        visited.add(pkg)

        # Skip if in skip list
        if pkg not in skip_set:
            result.append(pkg)

        # Add direct dependencies to queue
        for dep in get_direct_dependencies(pkg):
            if dep not in visited:
                queue.append(dep)

    return sorted(result)


def load_file_lines(path):
    """Load non-comment, non-empty lines from a file."""
    try:
        with open(path) as f:
            return [
                line.strip()
                for line in f
                if line.strip() and not line.strip().startswith("#")
            ]
    except FileNotFoundError:
        return []


def verify_real_packages(packages):
    """Filter to only packages that actually exist in apt-cache."""
    real_packages = []
    for pkg in packages:
        result = subprocess.run(
            ["apt-cache", "show", pkg],
            capture_output=True,
            timeout=5,
        )
        if result.returncode == 0:
            real_packages.append(pkg)
    return real_packages


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Compute Debian package closure")
    parser.add_argument("--seeds", default="config/seeds.list", help="Seeds file")
    parser.add_argument("--skip", default="config/skip.list", help="Skip file")
    args = parser.parse_args()

    seeds = load_file_lines(args.seeds)
    skip_set = set(load_file_lines(args.skip))

    closure = compute_closure(seeds, skip_set)
    real_packages = verify_real_packages(closure)

    for pkg in real_packages:
        print(pkg)
