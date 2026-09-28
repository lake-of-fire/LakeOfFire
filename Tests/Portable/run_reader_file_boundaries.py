#!/usr/bin/env python3
"""Run exact Foundation inventory and shared download-staging sources/tests.

Requires the companion SwiftUIDownloads checkout containing DownloadStagingPaths.
Does not compile ReaderFileManager, DownloadController, CryptoKit, Realm, SwiftUI,
CloudDrive, or native integration tests. Those require the assembled Mac graph.
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
    .target(name: "SwiftUIDownloads"),
    .target(name: "LakeOfFireContent", dependencies: ["SwiftUIDownloads"]),
    .testTarget(name: "ReaderFileTests", dependencies: ["LakeOfFireContent"]),
    .testTarget(name: "DownloadStagingTests", dependencies: ["SwiftUIDownloads"])
])
'''


def run_tests(command: list[str]) -> None:
    if not shutil.which("xcsift"):
        subprocess.run(command, check=True, timeout=300)
        return
    producer = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    consumer = subprocess.Popen(["xcsift"], stdin=producer.stdout)
    producer.stdout.close()
    consumer_status = consumer.wait()
    producer_status = producer.wait()
    if producer_status or consumer_status:
        raise subprocess.CalledProcessError(producer_status or consumer_status, command)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=("debug", "release", "both"), default="both")
    parser.add_argument("--swift", default="swift", help="Swift 6.2 or newer executable")
    parser.add_argument("--downloads-root", type=Path, help="Companion SwiftUIDownloads checkout; defaults to the sibling directory")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    downloads = (args.downloads_root or root.parent / "SwiftUIDownloads").resolve()
    configurations = ("debug", "release") if args.configuration == "both" else (args.configuration,)
    try:
        subprocess.run([args.swift, "--version"], check=True, timeout=30)
        with tempfile.TemporaryDirectory(prefix="reader-file-boundaries-") as temporary:
            package = Path(temporary)
            (package / "Package.swift").write_text(PACKAGE, encoding="utf-8")
            groups = (
                (SOURCES, root / "Sources/LakeOfFireContent/Files", package / "Sources/LakeOfFireContent"),
                (TESTS, root / "Tests/LakeOfFireTests", package / "Tests/ReaderFileTests"),
                (("DownloadStagingPaths.swift",), downloads / "Sources/SwiftUIDownloads", package / "Sources/SwiftUIDownloads"),
                (("DownloadStagingPathsTests.swift",), downloads / "Tests/SwiftUIDownloadsTests", package / "Tests/DownloadStagingTests"),
            )
            for names, source_directory, destination in groups:
                destination.mkdir(parents=True)
                for name in names:
                    source = source_directory / name
                    # Copy whole production/test files, never extract or rewrite
                    # implementations or substitute framework declarations.
                    shutil.copyfile(source, destination / name)
                    digest = hashlib.sha256(source.read_bytes()).hexdigest()
                    print(f"input {source} sha256={digest}", flush=True)
            for configuration in configurations:
                print(f"\n=== {configuration} ===", flush=True)
                run_tests([args.swift, "test", "--package-path", str(package),
                           "--configuration", configuration, "--jobs", "2",
                           "-Xswiftc", "-warnings-as-errors"])
        print("Foundation-only behavior checks passed; native integration is not qualified.", flush=True)
        return 0
    except (OSError, subprocess.SubprocessError) as error:
        print(f"Reader file boundary checks failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
