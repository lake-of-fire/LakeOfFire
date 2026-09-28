#!/usr/bin/env python3
"""Run the full OPDS module's URL-port and retained document tests.

The default matches main's Swift 6 language mode. --language-mode 5 is an
explicit supplemental behavior probe, not qualification of main's build.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--language-mode", choices=("5", "6"), default="6")
    parser.add_argument("--configuration", choices=("debug", "release", "both"), default="both")
    arguments = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    source_directory = root / "Sources/LakeOfFireOPDS"
    test_directory = root / "Tests/LakeOfFireOPDSTests"
    paths = sorted(source_directory.rglob("*.swift"))
    if not paths:
        parser.error(f"No OPDS sources found at {source_directory}")
    paths.extend(test_directory / name for name in (
        "OPDSURLForwardPortTests.swift",
        "readium_opds1_1_test.swift",
        "readium_opds2_0_test.swift",
        "Samples/wiki_1_1.opds",
        "Samples/opds_2_0.json",
    ))
    for path in paths:
        if not path.is_file():
            parser.error(f"Required input is missing: {path}")
    subprocess.run(["swift", "--version"], check=True)
    print(f"Swift language mode {arguments.language_mode}; complete OPDS sources, document tests only", flush=True)
    with tempfile.TemporaryDirectory(prefix="opds-url-port-") as temporary:
        workspace = Path(temporary)
        for path in paths:
            content = path.read_bytes()
            relative = path.relative_to(root)
            destination = workspace / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(content)
            digest = hashlib.sha1(b"blob " + str(len(content)).encode() + b"\0" + content).hexdigest()
            print(f"{digest}  {relative}", flush=True)
        (workspace / "Package.swift").write_text(
            "// swift-tools-version: 6.2\n"
            "import PackageDescription\n"
            "let package = Package(name: \"OPDSURLForwardPort\", targets: [\n"
            "    .target(name: \"LakeOfFireOPDS\"),\n"
            "    .testTarget(name: \"LakeOfFireOPDSTests\", dependencies: [\"LakeOfFireOPDS\"], "
            "resources: [.copy(\"Samples\")])\n"
            f"], swiftLanguageModes: [.v{arguments.language_mode}])\n",
            encoding="utf-8",
        )
        configurations = ("debug", "release") if arguments.configuration == "both" else (arguments.configuration,)
        for configuration in configurations:
            subprocess.run([
                "swift", "test", "--package-path", str(workspace),
                "-c", configuration, "-Xswiftc", "-warnings-as-errors",
            ], check=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
