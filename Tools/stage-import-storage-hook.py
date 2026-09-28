#!/usr/bin/env python3
"""Temporary, hash-checked main adapter staging. Never changes refs or source files."""
import hashlib
import json
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
destination = Path(sys.argv[1])
destination.mkdir(parents=True, exist_ok=True)
source = root / 'Sources/LakeOfFireContent/Files/ReaderFileManager.swift'
raw = source.read_bytes()
def blob(data):
    return hashlib.sha1(f'blob {len(data)}\0'.encode() + data).hexdigest()
if blob(raw) != '5048fb845893f5194e2a3bd3153330cabf7fc431':
    raise SystemExit('Refusing to adapt a different ReaderFileManager baseline')
text = raw.decode('utf-8')
start = '        var targetFilePath = targetDirectory.appending(fileURL.lastPathComponent)'
end = '        do {\n            _ = try await refreshFilesMetadata('
if text.count(start) != 1 or text.count(end) != 1:
    raise SystemExit('Import block anchors are ambiguous')
replacement = '''        let shouldStopAccessingFile = fileURL.startAccessingSecurityScopedResource()
        defer {
            if shouldStopAccessingFile {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        try await drive.createDirectory(at: targetDirectory)
        let targetFilePath = try await ReaderFileImportStorage.install(
            fileURL: fileURL,
            targetDirectory: targetDirectory,
            drive: drive,
            pathExtension: fileURL.lakePathExtension,
            collisionTag: { String(format: "%02X", stableHash(data: $0)).prefix(6).uppercased() }
        )

'''
first, last = text.index(start), text.index(end)
if last <= first:
    raise SystemExit('Import block anchors are reversed')
result = (text[:first] + replacement + text[last:]).encode('utf-8')
if blob(result) != '42d07384c9909a2ea9f2582f9a687337aa924750':
    raise SystemExit('Adapted source differs from the reviewed candidate')
(destination / 'ReaderFileManager.swift').write_bytes(result)
(destination / 'fm-blob.json').write_text(json.dumps({'content': result.decode('utf-8'), 'encoding': 'utf-8'}))
print(blob(result))
