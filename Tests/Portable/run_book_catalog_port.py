#!/usr/bin/env python3
"""Compile the production catalog loader, refresh owner, model and native detail view.

Copies complete unchanged files to a focused graph, not the entire Reader module.
On macOS the actual SwiftUI detail view is compiled; Linux omits that Apple-only file.
All OPDS production files are included, without stubs or source extraction.
"""
from __future__ import annotations
import argparse
import hashlib
from pathlib import Path
import platform
import subprocess
import tempfile


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=("debug", "release", "both"), default="both")
    parser.add_argument("--keep-workspace", type=Path)
    parser.add_argument("--typecheck-ios", action="store_true")
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    books = root / "Sources/LakeOfFireReader/Reader/Books"
    sources = sorted((root / "Sources/LakeOfFireOPDS").glob("*.swift"))
    sources += [books / name for name in ("Publication.swift", "BookCatalogLoading.swift", "BookCatalogRefresh.swift")]
    if platform.system() == "Darwin":
        sources.append(books / "OPDS/OPDSCatalogDetailView.swift")
    sources += [root / "Tests/LakeOfFireTests" / name for name in ("BookCatalogLoadingTests.swift", "BookCatalogRefreshTests.swift")]
    temporary = tempfile.TemporaryDirectory(prefix="book-catalog-port-")
    workspace = options.keep_workspace or Path(temporary.name)
    workspace.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swift", "--version"], check=True)
    print("Complete catalog component files; Swift 6 language mode; no full Reader graph claim", flush=True)
    for source in sources:
        content = source.read_bytes()
        relative = source.relative_to(root)
        destination = workspace / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(content)
        digest = hashlib.sha1(b"blob " + str(len(content)).encode() + b"\0" + content).hexdigest()
        print(f"{digest}  {relative}", flush=True)
    (workspace / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "BookCatalogPort", platforms: [.macOS(.v15), .iOS(.v15)], targets: [
    .target(name: "LakeOfFireOPDS"),
    .target(name: "LakeOfFireReader", dependencies: ["LakeOfFireOPDS"]),
    .testTarget(name: "LakeOfFireTests", dependencies: ["LakeOfFireReader"])
], swiftLanguageModes: [.v6])
''', encoding="utf-8")
    configurations = ("debug", "release") if options.configuration == "both" else (options.configuration,)
    for configuration in configurations:
        subprocess.run(["swift", "test", "--package-path", str(workspace), "-c", configuration,
                        "-Xswiftc", "-warnings-as-errors"], check=True, timeout=180)
    if options.typecheck_ios:
        if platform.system() != "Darwin":
            parser.error("--typecheck-ios requires an Apple SDK host")
        sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
        modules = workspace / "ios-modules"
        modules.mkdir(exist_ok=True)
        flags = ["swiftc", "-emit-module", "-parse-as-library", "-swift-version", "6", "-warnings-as-errors",
                 "-sdk", sdk, "-target", "arm64-apple-ios15.0-simulator", "-I", str(modules)]
        for module in ("LakeOfFireOPDS", "LakeOfFireReader"):
            inputs = sorted((workspace / "Sources" / module).rglob("*.swift"))
            subprocess.run(flags + ["-module-name", module, "-emit-module-path", str(modules / f"{module}.swiftmodule")]
                           + [str(path) for path in inputs], check=True, timeout=180)
        print("Actual OPDS and catalog component modules typechecked for iOS 15 simulator", flush=True)
    temporary.cleanup()
    return 0

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error)) from error
