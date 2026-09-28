#!/usr/bin/env python3
"""Hash-check the narrow #51 installation block against the frozen #50 input."""
from pathlib import Path
import hashlib
import urllib.request
import subprocess

root = Path(__file__).resolve().parents[1]
relative = 'Sources/LakeOfFireContent/Files/ReaderFileManager.swift'
path = root / relative

def blob(data):
    return hashlib.sha1(f'blob {len(data)}\0'.encode() + data).hexdigest()

before = path.read_bytes()
assert blob(before) == 'e9541548aef69722f7018f2dacb336597eb1ef1e', 'The composed manager changed; re-review instead of replacing it'
url = 'https://raw.githubusercontent.com/lake-of-fire/LakeOfFire/db04ad527a7f915e99fba6abb3747aa7583fe69f/' + relative
with urllib.request.urlopen(url, timeout=30) as response:
    source = response.read()
assert blob(source) == '42d07384c9909a2ea9f2582f9a687337aa924750'
start = b'        let targetDirectory = try await Self.rootRelativePath(forImportedURL: downloadURL ?? fileURL, drive: drive)\n'
end = b'        do {\n            _ = try await refreshFilesMetadata('
assert before.count(start) == source.count(start) == 1
b0, s0 = before.index(start), source.index(start)
b1, s1 = before.index(end, b0), source.index(end, s0)
after = before[:b0] + source[s0:s1] + before[b1:]
assert blob(after) == '5a1bfc4b14ee4afb8265b432ea88c2e40237905f'
assert after.count(b'resolveAlreadyReadableEBookURL') == before.count(b'resolveAlreadyReadableEBookURL') == 1
path.write_bytes(after)
subprocess.run(['swiftc', '-frontend', '-parse', str(path)], check=True)
print(blob(after), relative, flush=True)
