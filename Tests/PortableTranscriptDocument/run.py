"""Run actual parser tests with the selected real SwiftSoup dependency.

The fresh package compiles unmodified production parser bytes, not a model.
Realm/network/native-host integration are outside this component receipt.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--swift-soup', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
source = root / 'Sources/LakeOfFireContent/Reader/ReaderTranscriptDocument.swift'
tests = root / 'Tests/LakeOfFireTests/ReaderTranscriptDocumentTests.swift'
directory = Path(tempfile.mkdtemp(prefix='transcript-document-tests-')).resolve(strict=True)
print('Component package retained:', directory, flush=True)
(directory / 'Sources/LakeOfFireContent').mkdir(parents=True)
(directory / 'Tests/TranscriptTests').mkdir(parents=True)
(directory / 'Sources/LakeOfFireContent/ReaderTranscriptDocument.swift').write_bytes(source.read_bytes())
(directory / 'Tests/TranscriptTests/ReaderTranscriptDocumentTests.swift').write_bytes(tests.read_bytes())
soup = json.dumps(str(args.swift_soup.resolve(strict=True)))
(directory / 'Package.swift').write_text("""// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "TranscriptDocumentComponent", platforms: [.macOS(.v15)],
    products: [.library(name: "LakeOfFireContent", targets: ["LakeOfFireContent"])],
    dependencies: [.package(path: __SOUP_PATH__)],
    targets: [.target(name: "LakeOfFireContent", dependencies: [.product(name: "SwiftSoup", package: "SwiftSoup")]),
              .testTarget(name: "TranscriptTests", dependencies: ["LakeOfFireContent"])])
""".replace('__SOUP_PATH__', soup))
subprocess.run(['xcrun', 'swift', 'test', '--package-path', str(directory),
                '--scratch-path', str(directory / 'build'), '--filter', 'ReaderTranscriptDocumentTests'], check=True)
