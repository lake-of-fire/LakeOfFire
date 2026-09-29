#!/usr/bin/env python3
"""Compile the complete OPDS module and run all its XCTest methods/resources.

Copies whole committed files, without source extraction, rewriting or framework
stubs. URLSession tests use explicit protocol-backed sessions, not real servers.
This does not build LakeOfFireReader, SwiftUI, Realm, or the assembled Reader app.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

PACKAGE = '''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "OPDSBoundaryChecks", targets: [
    .target(name: "LakeOfFireOPDS"),
    .testTarget(name: "LakeOfFireOPDSTests", dependencies: ["LakeOfFireOPDS"],
                resources: [.copy("Samples")])
], swiftLanguageModes: [.v5])
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
        with tempfile.TemporaryDirectory(prefix="opds-boundaries-") as temporary:
            package = Path(temporary)
            (package / "Package.swift").write_text(PACKAGE, encoding="utf-8")
            for directory in ("Sources/LakeOfFireOPDS", "Tests/LakeOfFireOPDSTests"):
                shutil.copytree(root / directory, package / directory)
                for source in sorted((root / directory).rglob("*")):
                    if source.is_file():
                        digest = hashlib.sha256(source.read_bytes()).hexdigest()
                        print(f"input {source.relative_to(root)} sha256={digest}", flush=True)
            for configuration in configurations:
                print(f"\n=== {configuration} ===", flush=True)
                subprocess.run(
                    [args.swift, "test", "--package-path", str(package),
                     "--configuration", configuration, "-Xswiftc", "-warnings-as-errors"],
                    check=True, timeout=300,
                )
        print("Complete OPDS module passed; native Reader integration is not qualified.", flush=True)
        return 0
    except (OSError, subprocess.SubprocessError) as error:
        print(f"OPDS checks failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
