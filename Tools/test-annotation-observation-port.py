#!/usr/bin/env python3
from pathlib import Path
import shutil, subprocess, tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="annotation-observation-port-") as d:
    work = Path(d)
    (work / "Sources/LakeOfFireContentUI").mkdir(parents=True)
    (work / "Tests/LakeOfFireContentUITests").mkdir(parents=True)
    shutil.copyfile(
        root / "Sources/LakeOfFireContentUI/Reader Content/ReaderContentCellAnnotationObservation.swift",
        work / "Sources/LakeOfFireContentUI/ReaderContentCellAnnotationObservation.swift"
    )
    shutil.copyfile(
        root / "Tests/LakeOfFireTests/ReaderContentCellAnnotationObservationTests.swift",
        work / "Tests/LakeOfFireContentUITests/ReaderContentCellAnnotationObservationTests.swift"
    )
    (work / "Package.swift").write_text("""// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "AnnotationObservationPort",
    targets: [
        .target(name: "LakeOfFireContentUI"),
        .testTarget(name: "LakeOfFireContentUITests", dependencies: ["LakeOfFireContentUI"])
    ],
    swiftLanguageModes: [.v6]
)
""")
    subprocess.run(["swift", "--version"], check=True)
    for configuration in ["debug", "release"]:
        subprocess.run([
            "swift", "test", "--package-path", str(work), "-c", configuration,
            "-Xswiftc", "-warnings-as-errors"
        ], check=True)
