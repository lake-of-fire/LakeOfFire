#!/usr/bin/env python3
"""Prepare only the reviewed immutable source blob; never update Git refs."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import urllib.request

SOURCE = Path('Sources/LakeOfFireContent/Files/ReaderFileManager.swift')
TEST = Path('Tests/LakeOfFireTests/ReaderFileInventoryAdmissionTests.swift')
BEFORE = '0f50121aa93b4ff2c958f37bbcd28ac5e4b41481'
AFTER = 'a796b227c4688d40243ccd424370d4677a7f65e8'
TEST_BLOB = 'ce54ec6235c39c9ca64cbf91f7a567f6ee606701'

def blob(data):
    return hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()

original = SOURCE.read_bytes()
assert blob(original) == BEFORE
assert blob(TEST.read_bytes()) == TEST_BLOB
text = original.decode()
replacements = [
    ('''            let updatedContentFileIDs = try await { @RealmBackgroundActor in
                var updatedFiles = [ContentFile]()
                var allContentFileIDs = [String]()''',
     '''            let metadataScan = try await { @RealmBackgroundActor in
                var updatedFiles = [ContentFile]()
                var metadataScan = MetadataScanResult()'''),
    ('''                    for (readerFileURL, _, drive) in filesToUpdate {
                        try self.validateMetadataRefreshSelection(selection)
                        if let existing = realm.objects(ContentFile.self).filter(''',
     '''                    for (readerFileURL, relativePath, drive) in filesToUpdate {
                        try self.validateMetadataRefreshSelection(selection)
                        // Enumeration and URL mapping can suspend before this
                        // independent write. An old path is not evidence that
                        // a deleted payload still exists: do not create/revive
                        // its index or replace its deletion journal generation.
                        let payloadURL = try relativePath.fileURL(forRoot: drive.rootDirectory)
                        guard try Self.fileSystemEntryExists(at: payloadURL) else {
                            metadataScan.isComplete = false
                            continue
                        }
                        if let existing = realm.objects(ContentFile.self).filter('''),
    ('''                return allContentFileIDs
            }()
            scan.contentFileIDs.append(contentsOf: updatedContentFileIDs)''',
     '''                return metadataScan
            }()
            scan.contentFileIDs.append(contentsOf: metadataScan.contentFileIDs)
            scan.isComplete = scan.isComplete && metadataScan.isComplete'''),
]
for before, after in replacements:
    assert text.count(before) == 1
    text = text.replace(before, after)
assert text.count('allContentFileIDs.append(') == 2
text = text.replace('allContentFileIDs.append(', 'metadataScan.contentFileIDs.append(')
changed = text.encode()
assert blob(changed) == AFTER
output = Path(os.environ['REVIEW_EVIDENCE'])
output.mkdir(parents=True, exist_ok=True)
(output / 'ReaderFileManager.before.swift').write_bytes(original)
(output / 'ReaderFileManager.after.swift').write_bytes(changed)
(output / TEST.name).write_bytes(TEST.read_bytes())
SOURCE.write_bytes(changed)
# Parsing does not import or typecheck the native dependency graph. It executes
# zero test methods. Keep these statuses explicitly separate from native tests.
statuses = {}
for name, source in [('manager-before', output / 'ReaderFileManager.before.swift'),
                     ('manager-after', SOURCE), ('native-tests', TEST)]:
    result = subprocess.run(['swiftc', '-frontend', '-parse', str(source)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    (output / (name + '.log')).write_bytes(result.stdout)
    statuses[name] = result.returncode
(output / 'syntax-status.json').write_text(json.dumps(statuses, indent=2) + '\n')
assert not any(statuses.values()), statuses
subprocess.run(['git', 'diff', '--check'], check=True)
# This authenticated endpoint stores only the exact reviewed immutable blob in
# its original repository. Branches, PRs, policies and other repositories are
# not written by this workflow. Final source selection is a separate tool call.
request = urllib.request.Request(
    'https://api.github.com/repos/lake-of-fire/LakeOfFire/git/blobs',
    data=json.dumps({'content': text, 'encoding': 'utf-8'}).encode(),
    headers={'Authorization': 'Bearer ' + os.environ['GITHUB_TOKEN'],
             'Accept': 'application/vnd.github+json', 'Content-Type': 'application/json'},
    method='POST')
with urllib.request.urlopen(request, timeout=60) as response:
    published = json.load(response)
assert published['sha'] == AFTER
receipt = {'before': BEFORE, 'after': AFTER, 'native_test_blob': TEST_BLOB,
           'syntax_statuses': statuses, 'native_methods_executed': 0,
           'git_refs_written': False}
(output / 'source-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt))
