#!/usr/bin/env python3
"""Run complete import-storage declarations, with the real drive on macOS."""
from pathlib import Path
import argparse
import hashlib
import os
import platform
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
parser.add_argument('--native', action='store_true')
args = parser.parse_args()
if args.native and platform.system() != 'Darwin':
    parser.error('--native requires Apple CryptoKit and the actual SwiftCloudDrive package')
root = Path(__file__).resolve().parents[1]
source_paths = ['Sources/LakeOfFireContent/Files/ReaderFileImportCollisionResolver.swift']
test_paths = ['Tests/LakeOfFireTests/ReaderFileImportCollisionResolverTests.swift']
if args.native:
    source_paths += ['Sources/LakeOfFireContent/Files/ReaderFileImportStorage.swift',
                     'Sources/LakeOfFireContent/Files/ReaderFileImportPackageManifest.swift']
    test_paths += ['Tests/LakeOfFireTests/ReaderFileImportStorageNativeTests.swift']
with tempfile.TemporaryDirectory(prefix='reader-import-port-') as directory:
    work = Path(directory)
    for folder, paths in [('Sources/LakeOfFireContent', source_paths), ('Tests/ImportStorageTests', test_paths)]:
        (work / folder).mkdir(parents=True)
        for relative in paths:
            source = root / relative
            data = source.read_bytes()
            digest = hashlib.sha1(f'blob {len(data)}\0'.encode() + data).hexdigest()
            print(f'{digest} {relative}', flush=True)
            shutil.copyfile(source, work / folder / source.name)
    dependency = '.package(url: "https://github.com/lake-of-fire/SwiftCloudDrive.git", revision: "0a84ea27d394fe0ed92e9b7809d84cfaa1942442")' if args.native else ''
    product = '.product(name: "SwiftCloudDrive", package: "SwiftCloudDrive")' if args.native else ''
    (work / 'Package.swift').write_text(f'''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "ReaderImportStoragePort", platforms: [.macOS(.v15), .iOS(.v15)],
    dependencies: [{dependency}], targets: [
        .target(name: "LakeOfFireContent", dependencies: [{product}]),
        .testTarget(name: "ImportStorageTests", dependencies: ["LakeOfFireContent"{', ' + product if product else ''}])
    ], swiftLanguageModes: [.v6])
''')
    subprocess.run(['swift', '--version'], check=True)
    try:
        subprocess.run(['swift', 'test', '--package-path', str(work), '-c', args.configuration,
                        '-Xswiftc', '-warnings-as-errors'], check=True)
    finally:
        destination = os.environ.get('IMPORT_STORAGE_EVIDENCE_DIRECTORY')
        if destination:
            evidence = Path(destination) / args.configuration
            evidence.mkdir(parents=True, exist_ok=True)
            for name in ['Package.swift', 'Package.resolved']:
                if (work / name).exists():
                    shutil.copyfile(work / name, evidence / name)
            for name in ['Sources', 'Tests']:
                shutil.copytree(work / name, evidence / name, dirs_exist_ok=True)
