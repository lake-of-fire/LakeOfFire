#!/usr/bin/env python3
"""Run the exact production XML decoder and XCTest file, without Apple graph stubs.

This does NOT compile EPubParser, EbookFileManager, ZIPFoundation, Realm or the
native integration tests. Those still require the assembled macOS/iOS graph.
"""
from pathlib import Path
import hashlib
import shutil
import subprocess
import tempfile


def main() -> None:
    root = Path(__file__).resolve().parents[2]
    inputs = {
        "Sources/LakeOfFireReader/EPubMetadataDocument.swift": root / "Sources/LakeOfFireReader/Reader/Books/EPubMetadataDocument.swift",
        "Tests/MetadataTests/EPubMetadataDocumentTests.swift": root / "Tests/LakeOfFireTests/EPubMetadataDocumentTests.swift",
    }
    swift = shutil.which("swift")
    if swift is None:
        raise SystemExit("Swift is required; no tests executed")
    subprocess.run([swift, "--version"], check=True)
    with tempfile.TemporaryDirectory(prefix="epub-metadata-") as directory:
        package = Path(directory)
        for destination, source in inputs.items():
            data = source.read_bytes()
            print(f"SHA256 {hashlib.sha256(data).hexdigest()} {source.relative_to(root)}", flush=True)
            target = package / destination
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        (package / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "EPubMetadataPortable", targets: [
    .target(name: "LakeOfFireReader"),
    .testTarget(name: "MetadataTests", dependencies: ["LakeOfFireReader"])
], swiftLanguageModes: [.v5])
''', encoding="utf-8")
        for configuration in ("debug", "release"):
            subprocess.run([
                swift, "test", "--package-path", str(package),
                "--configuration", configuration, "-Xswiftc", "-warnings-as-errors",
            ], check=True)
    print("Exact XML decoder tests passed; native package/enrichment gates not executed.")


if __name__ == "__main__":
    main()
