#!/usr/bin/env python3
"""Run exact Foundation-only inventory production sources and XCTest files.

This does not compile ReaderFileManager, Realm, SwiftUI, CloudDrive or the native
ReaderFileLibraryBoundaryTests. Run those separately in the assembled Mac graph.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

SOURCES = ("ReaderFileRefreshQueue.swift", "ReaderFileStoragePaths.swift")
TESTS = ("ReaderFileRefreshQueueTests.swift", "ReaderFileStoragePathsTests.swift")
PACKAGE = '''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "ReaderFileBoundaryChecks", targets: [
    .target(name: "LakeOfFireContent"),
    .testTarget(name: "ReaderFileTests", dependencies: ["LakeOfFireContent"])
])
'''


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=("debug", "release", "both"), default="both")
    parser.add_argument("--swift", default="swift", help="Swift 6.2 or newer executable")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    configurations = ("debug", "release") if args.configuration == "both" else (args.configuration,)
    try:
        subprocess.run([args.swift, "--version"], check=True, timeout=30)
        with tempfile.TemporaryDirectory(prefix="reader-file-boundaries-") as temporary:
            package = Path(temporary)
            (package / "Package.swift").write_text(PACKAGE, encoding="utf-8")
            groups = (
                (SOURCES, root / "Sources/LakeOfFireContent/Files", package / "Sources/LakeOfFireContent"),
                (TESTS, root / "Tests/LakeOfFireTests", package / "Tests/ReaderFileTests"),
            )
            for names, source_directory, destination in groups:
                destination.mkdir(parents=True)
                for name in names:
                    source = source_directory / name
                    # Copy the whole committed file without extraction, rewriting,
                    # replacement declarations, stubs or platform-condition edits.
                    shutil.copyfile(source, destination / name)
                    digest = hashlib.sha256(source.read_bytes()).hexdigest()
                    print(f"input {source.relative_to(root)} sha256={digest}", flush=True)
            for configuration in configurations:
                print(f"\n=== {configuration} ===", flush=True)
                subprocess.run(
                    [args.swift, "test", "--package-path", str(package),
                     "--configuration", configuration, "-Xswiftc", "-warnings-as-errors"],
                    check=True, timeout=300,
                )
        print("Foundation-only behavior checks passed; native integration is not qualified.", flush=True)
        return 0
    except (OSError, subprocess.SubprocessError) as error:
        print(f"Reader file boundary checks failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
