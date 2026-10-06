from pathlib import Path
import hashlib
import json
import subprocess

SOURCE = Path('Sources/LakeOfFireContent/Files/ReaderFileManager.swift')
TEST = Path('Tests/LakeOfFireTests/ReaderFileLibraryBoundaryTests.swift')
EXPECTED_SOURCE = '1bc5217c7130b083bcea76ccf96f1475362890ac'
EXPECTED_TEST = '1e947f1c689d3cf303c6a09ba7945389161b9bd5'

def blob(data):
    return hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()

def replace_once(text, before, after):
    if text.count(before) != 1:
        raise ValueError('ambiguous patch boundary: ' + before[:100])
    return text.replace(before, after, 1)

def apply(source, tests, additions):
    assert blob(source.encode()) == EXPECTED_SOURCE, 'source moved; review before retry'
    assert blob(tests.encode()) == EXPECTED_TEST, 'tests moved; review before retry'
    source = replace_once(source, '''        let realmConfiguration = resolvedHistoryRealmConfiguration
        guard let readerBackingURL = canonicalReaderBackingURL(for: contentURL) else {''', '''        // Capture before the first availability/actor handoff. Keeping only
        // the drive permits a replaced Realm or a newer failed initialization
        // to authorize physical removal before the later index phase rejects.
        let selection = MetadataRefreshSelection(
            localDrive: localDrive, cloudDrive: cloudDrive,
            initializationIdentifier: initializationID,
            realmConfiguration: resolvedHistoryRealmConfiguration
        )
        guard let readerBackingURL = canonicalReaderBackingURL(for: contentURL) else {''')
    source = replace_once(source, '''        let drive = pathContext.storageLocation == .local ? localDrive : cloudDrive
        let status: CloudDriveSyncStatus''', '''        let drive = pathContext.storageLocation == .local
            ? selection.localDrive : selection.cloudDrive
        try validateDeletionSelection(pathContext, drive: drive, selection: selection)
        let status: CloudDriveSyncStatus''')
    old = 'try validateDeletionSelection(pathContext, drive: drive)'
    assert source.count(old) == 4, 'unexpected number of deletion fences'
    source = source.replace(old, 'try validateDeletionSelection(pathContext, drive: drive, selection: selection)')
    source = replace_once(source, '''        try await markDeleted(contentURL: contentURL, realmConfiguration: realmConfiguration,
                              pathContext: pathContext, drive: drive)
        await removeDeletedFileFromPublishedFiles(matching: readerBackingURL,
            realmConfiguration: realmConfiguration, pathContext: pathContext, drive: drive)
        Task { @MainActor [weak self] in
            guard let self, self.deletionDriveIsCurrent(pathContext, drive: drive),
                  Self.sameHistoryRealm(self.resolvedHistoryRealmConfiguration, realmConfiguration) else { return }
            try await self.refreshAllFilesMetadata(force: true, realmConfiguration: realmConfiguration)
        }''', '''        try await markDeleted(contentURL: contentURL, pathContext: pathContext,
                              drive: drive, selection: selection)
        await removeDeletedFileFromPublishedFiles(matching: readerBackingURL,
            pathContext: pathContext, drive: drive, selection: selection)
        Task { @MainActor [weak self] in
            guard let self,
                  self.deletionSelectionIsCurrent(pathContext, drive: drive, selection: selection) else { return }
            // Optional refresh cannot acquire a new selection for this command.
            try await self.refreshAllFilesMetadata(force: true, selection: selection)
        }''')
    source = replace_once(source, '''    private func validateDeletionSelection(_ context: ReaderBackingPathContext, drive: CloudDrive?) throws {
        try Task.checkCancellation()
        guard deletionDriveIsCurrent(context, drive: drive) else {''', '''    private func deletionSelectionIsCurrent(
        _ context: ReaderBackingPathContext, drive: CloudDrive?,
        selection: MetadataRefreshSelection
    ) -> Bool {
        // Only the selected drive participates in deletion. An unrelated
        // drive replacement does not revoke a current local/cloud command.
        deletionDriveIsCurrent(context, drive: drive)
            && initializationID == selection.initializationIdentifier
            && Self.sameHistoryRealm(resolvedHistoryRealmConfiguration, selection.realmConfiguration)
    }

    private func validateDeletionSelection(
        _ context: ReaderBackingPathContext, drive: CloudDrive?,
        selection: MetadataRefreshSelection
    ) throws {
        try Task.checkCancellation()
        guard deletionSelectionIsCurrent(context, drive: drive, selection: selection) else {''')
    source = replace_once(source, '''        matching readerBackingURL: URL, realmConfiguration: Realm.Configuration,
        pathContext: ReaderBackingPathContext, drive: CloudDrive?
    ) {
        guard deletionDriveIsCurrent(pathContext, drive: drive),
              Self.sameHistoryRealm(resolvedHistoryRealmConfiguration, realmConfiguration) else { return }''', '''        matching readerBackingURL: URL, pathContext: ReaderBackingPathContext,
        drive: CloudDrive?, selection: MetadataRefreshSelection
    ) {
        // Display can be obsolete after durable success; skip it without
        // changing the command's already-committed physical/index outcome.
        guard deletionSelectionIsCurrent(pathContext, drive: drive, selection: selection) else { return }''')
    source = replace_once(source, '''        contentURL: URL, realmConfiguration: Realm.Configuration,
        pathContext: ReaderBackingPathContext, drive: CloudDrive?
    ) async throws {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)''', '''        contentURL: URL, pathContext: ReaderBackingPathContext,
        drive: CloudDrive?, selection: MetadataRefreshSelection
    ) async throws {
        try validateDeletionSelection(pathContext, drive: drive, selection: selection)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: selection.realmConfiguration)''')
    return source, tests + additions

if __name__ == '__main__':
    source = SOURCE.read_text()
    tests = TEST.read_text()
    additions = Path('Tools/Review20261006/native-delete-additions.swift').read_text()
    source, tests = apply(source, tests, additions)
    SOURCE.write_text(source)
    TEST.write_text(tests)
    for path in (SOURCE, TEST):
        subprocess.run(['swiftc', '-frontend', '-parse', str(path)], check=True)
    subprocess.run(['git', 'diff', '--check'], check=True)
    print(json.dumps({str(p): blob(p.read_bytes()) for p in (SOURCE, TEST)}, indent=2))
