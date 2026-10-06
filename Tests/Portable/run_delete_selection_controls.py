#!/usr/bin/env python3
"""Compile the real delete executor and selection validators with explicit SDK doubles.

The file remove is real Foundation I/O. Realm writes, drive coordination and UI
publication are doubles, so this cannot qualify actual Realm/Apple behavior.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def declaration(text, marker):
    start = text.index(marker)
    brace = text.index('{', start)
    depth = 1
    at = brace + 1
    while depth:
        if at >= len(text):
            raise ValueError('unterminated declaration: ' + marker)
        if text[at] == '{': depth += 1
        elif text[at] == '}': depth -= 1
        at += 1
    return text[start:at]


PREAMBLE = r'''
import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

@globalActor actor RealmBackgroundActor {
    static let shared = RealmBackgroundActor()
}
enum Realm {
    struct Configuration: Sendable {
        var inMemoryIdentifier: String?
        var fileURL: URL?
    }
}
struct RootRelativePath: Sendable { let path: String }
enum CloudDriveSyncStatus: Sendable { case localOnly, fileMissing, cloudOnly, loadingStatus }
enum ReaderFileManagerError: Error { case driveMissing }
enum ReaderFileDeleteError: Error {
    case blockedCloudOnly, blockedLoadingStatus
    case removeFailed(underlyingDescription: String? = nil)
}
final class CloudDrive: @unchecked Sendable {
    let root: URL
    var beforeDirectory: (@Sendable () async -> Void)?
    var removes = 0
    init(root: URL) { self.root = root }
    func directoryExists(at path: RootRelativePath) async throws -> Bool {
        await beforeDirectory?()
        var directory = ObjCBool(false)
        _ = FileManager.default.fileExists(atPath: root.appendingPathComponent(path.path).path, isDirectory: &directory)
        return directory.boolValue
    }
    func removeDirectory(at path: RootRelativePath) async throws { try remove(path) }
    func removeFile(at path: RootRelativePath) async throws { try remove(path) }
    private func remove(_ path: RootRelativePath) throws {
        removes += 1
        try FileManager.default.removeItem(at: root.appendingPathComponent(path.path))
    }
}
struct DiagnosticLog: Sendable { func error(_ message: String) {} }
struct Logger: Sendable {
    static let shared = Logger()
    let logger = DiagnosticLog()
}
final class ReaderFileManager: @unchecked Sendable {
    var localDrive: CloudDrive?
    var cloudDrive: CloudDrive?
    var initializationID: UUID? = UUID()
    var configuration = Realm.Configuration(inMemoryIdentifier: "original", fileURL: nil)
    var resolvedHistoryRealmConfiguration: Realm.Configuration { configuration }
    var beforeIndex: (@Sendable () async -> Void)?
    var afterIndex: (@Sendable () async -> Void)?
    var indexWrites = 0
    var publications = 0
    init(_ drive: CloudDrive) { localDrive = drive }
    private func canonicalReaderBackingURL(for url: URL) -> URL? { url }
    private func readerBackingPathContext(for url: URL) throws -> ReaderBackingPathContext {
        let path = RootRelativePath(path: "delete.txt")
        let local = localDrive!.root.appendingPathComponent(path.path)
        return ReaderBackingPathContext(readerBackingURL: url, relativePath: path,
            storageLocation: .local, canonicalURL: url, localRootURL: local,
            cloudRootURL: nil, activeRootURL: local,
            localRootExists: FileManager.default.fileExists(atPath: local.path), cloudRootExists: false)
    }
'''

POST = r'''
    @MainActor
    private func refreshAllFilesMetadata(force: Bool, realmConfiguration: Realm.Configuration) async throws {}
    @MainActor
    private func refreshAllFilesMetadata(force: Bool, selection: MetadataRefreshSelection) async throws {}
}

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}
@main struct DeleteControls {
    @MainActor static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(description: message) }
    }
    @MainActor static func history(stage: String, change: String, missing: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("delete-control-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = root.appendingPathComponent("delete.txt")
        if !missing { try Data("original payload".utf8).write(to: payload) }
        let drive = CloudDrive(root: root)
        let manager = ReaderFileManager(drive)
        let changeOwner: @Sendable () async -> Void = {
            await MainActor.run {
                switch change {
                case "realm": manager.configuration.inMemoryIdentifier = "successor"
                case "initialization": manager.initializationID = UUID()
                case "drive": manager.localDrive = CloudDrive(root: root)
                case "unselected": manager.cloudDrive = CloudDrive(root: root)
                default: break
                }
            }
        }
        if stage == "directory" { drive.beforeDirectory = changeOwner }
        if stage == "index" { manager.beforeIndex = changeOwner }
        if stage == "afterCommit" { manager.afterIndex = changeOwner }
        let shouldReject = ["realm", "initialization", "drive"].contains(change) && stage != "afterCommit"
        var rejected = false
        do {
            try await manager.delete(readerFileURL: URL(string: "reader-file://file/load/local/delete.txt")!, statusLoader: { _ in
                if stage == "status" { await changeOwner() }
                return missing ? .fileMissing : .localOnly
            })
        } catch ReaderFileDeleteError.removeFailed {
            rejected = true
        }
        try require(rejected == shouldReject, "rejection differs from original selection ownership")
        let physicallyRemoved = !missing && !(shouldReject && ["status", "directory"].contains(stage))
        try require(drive.removes == (physicallyRemoved ? 1 : 0), "physical removal happened at the wrong phase")
        try require(manager.indexWrites == (shouldReject ? 0 : 1), "obsolete index phase was accepted or committed truth was lost")
        if !missing && !physicallyRemoved {
            try require(try Data(contentsOf: payload) == Data("original payload".utf8), "original file changed")
        }
    }
    @MainActor static func cancellation(atEntry: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("delete-cancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = root.appendingPathComponent("delete.txt")
        try Data("keep".utf8).write(to: payload)
        let drive = CloudDrive(root: root)
        let manager = ReaderFileManager(drive)
        var statusCalls = 0
        let task = Task { @MainActor in
            if atEntry { withUnsafeCurrentTask { $0?.cancel() } }
            try await manager.delete(readerFileURL: URL(string: "reader-file://file/load/local/delete.txt")!, statusLoader: { _ in
                statusCalls += 1
                withUnsafeCurrentTask { $0?.cancel() }
                return .localOnly
            })
        }
        var cancelled = false
        do { try await task.value } catch is CancellationError { cancelled = true }
        try require(cancelled, "caller cancellation was not returned")
        try require(statusCalls == (atEntry ? 0 : 1), "cancelled admission invoked the wrong callbacks")
        try require(drive.removes == 0 && manager.indexWrites == 0, "cancelled command performed effects")
        try require(try Data(contentsOf: payload) == Data("keep".utf8), "cancelled command removed payload")
    }
    @MainActor static func main() async {
        var records: [[String: Any]] = []
        for missing in [false, true] {
            for stage in missing ? ["status", "index", "afterCommit"] : ["status", "directory", "index", "afterCommit"] {
                for change in ["realm", "initialization"] {
                    let name = "\(missing ? "missing" : "file")/\(stage)/\(change)"
                    do {
                        try await history(stage: stage, change: change, missing: missing)
                        records.append(["name": name, "passed": true])
                    } catch { records.append(["name": name, "passed": false, "error": String(describing: error)]) }
                }
            }
        }
        for change in ["none", "drive", "unselected"] {
            let name = "file/status/\(change)"
            do {
                try await history(stage: "status", change: change, missing: false)
                records.append(["name": name, "passed": true])
            } catch { records.append(["name": name, "passed": false, "error": String(describing: error)]) }
        }
        for entry in [false, true] {
            let name = "cancellation/\(entry ? "entry" : "status")"
            do {
                try await cancellation(atEntry: entry)
                records.append(["name": name, "passed": true])
            } catch { records.append(["name": name, "passed": false, "error": String(describing: error)]) }
        }
        let data = try! JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(records.allSatisfy { $0["passed"] as? Bool == true } ? 0 : 1)
    }
}
'''


def fixture(source, repaired):
    pieces = [declaration(source, marker) for marker in (
        '    private enum ReaderBackingStorageLocation:',
        '    private struct ReaderBackingPathContext',
        '    private struct MetadataRefreshSelection',
    )]
    pieces.append('    typealias DeleteStatusLoader = @MainActor (URL) async throws -> CloudDriveSyncStatus')
    pieces.append('    @RealmBackgroundActor\n' + declaration(source, '    func delete(readerFileURL contentURL: URL, statusLoader:'))
    pieces.append(declaration(source, '    private func deletionDriveIsCurrent('))
    if repaired: pieces.append(declaration(source, '    private func deletionSelectionIsCurrent('))
    pieces.append(declaration(source, '    private func validateDeletionSelection('))
    pieces.append(declaration(source, '    private static func sameHistoryRealm('))
    if repaired:
        pieces.append(r'''
    @RealmBackgroundActor private func markDeleted(contentURL: URL, pathContext: ReaderBackingPathContext,
        drive: CloudDrive?, selection: MetadataRefreshSelection) async throws {
        await beforeIndex?()
        try validateDeletionSelection(pathContext, drive: drive, selection: selection)
        indexWrites += 1
        await afterIndex?()
    }
    @MainActor private func removeDeletedFileFromPublishedFiles(matching url: URL,
        pathContext: ReaderBackingPathContext, drive: CloudDrive?, selection: MetadataRefreshSelection) {
        if deletionSelectionIsCurrent(pathContext, drive: drive, selection: selection) { publications += 1 }
    }
''')
    else:
        pieces.append(r'''
    @RealmBackgroundActor private func markDeleted(contentURL: URL, realmConfiguration: Realm.Configuration,
        pathContext: ReaderBackingPathContext, drive: CloudDrive?) async throws {
        await beforeIndex?()
        try validateDeletionSelection(pathContext, drive: drive)
        indexWrites += 1
        await afterIndex?()
    }
    @MainActor private func removeDeletedFileFromPublishedFiles(matching url: URL, realmConfiguration: Realm.Configuration,
        pathContext: ReaderBackingPathContext, drive: CloudDrive?) {
        if deletionDriveIsCurrent(pathContext, drive: drive), Self.sameHistoryRealm(configuration, realmConfiguration) { publications += 1 }
    }
''')
    return PREAMBLE + '\n'.join(pieces) + POST


def run(source_path, output, repaired, optimized):
    output.mkdir(parents=True, exist_ok=False)
    source = source_path.read_text()
    program = output / 'Controls.swift'
    program.write_text(fixture(source, repaired))
    binary = output / 'controls'
    command = ['swiftc', '-swift-version', '6', '-strict-concurrency=complete',
               '-parse-as-library', '-O' if optimized else '-Onone', str(program), '-o', str(binary)]
    # Keep predecessor code unchanged despite its ignored-Task warning.
    if repaired: command.append('-warnings-as-errors')
    build = subprocess.run(command, text=True, capture_output=True, timeout=120)
    (output / 'build.log').write_text(build.stdout + build.stderr)
    receipt = {'source_sha256': hashlib.sha256(source_path.read_bytes()).hexdigest(),
               'fixture_sha256': hashlib.sha256(program.read_bytes()).hexdigest(),
               'repaired': repaired, 'optimized': optimized, 'warnings_as_errors': repaired,
               'build_status': build.returncode}
    if build.returncode == 0:
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
        (output / 'run.json').write_text(result.stdout)
        (output / 'stderr.log').write_text(result.stderr)
        cases = json.loads(result.stdout)
        assert len(cases) == 19 and len({c['name'] for c in cases}) == 19
        receipt.update(run_status=result.returncode, cases=19,
                       passed=sum(c['passed'] for c in cases), failed=sum(not c['passed'] for c in cases))
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt), flush=True)
    if build.returncode: raise RuntimeError(build.stderr)
    if repaired and receipt['run_status']: raise RuntimeError('repaired controls failed')
    if not repaired and receipt['failed'] == 0: raise RuntimeError('negative control did not reproduce')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--original', action='store_true')
    parser.add_argument('--optimized', action='store_true')
    args = parser.parse_args()
    run(args.source, args.output, not args.original, args.optimized)
