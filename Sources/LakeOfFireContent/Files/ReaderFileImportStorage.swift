import Foundation
@preconcurrency import SwiftCloudDrive

/// Installs through the real drive's exclusive-copy operation. Neither an
/// identical item nor an occupied hash suffix is ever overwritten.
@MainActor
enum ReaderFileImportStorage {
    static func install(
        fileURL: URL,
        targetDirectory: RootRelativePath,
        drive: CloudDrive,
        pathExtension: String,
        collisionTag: (Data) -> String
    ) async throws -> RootRelativePath {
        try Task.checkCancellation()
        let sourceType = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.type] as? FileAttributeType
        guard sourceType == .typeRegular || sourceType == .typeDirectory else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let isDirectory = sourceType == .typeDirectory
        var originData: Data?
        var tag: String?
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let ext = pathExtension.isEmpty ? "" : "." + pathExtension

        func packageIdentity(at url: URL) async throws -> Data {
            let task = Task.detached(priority: .utility) {
                try ReaderFileImportPackageManifest.digest(at: url)
            }
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            return result
        }

        func sourceIdentity() async throws -> Data {
            if let originData { return originData }
            let data: Data
            if isDirectory {
                data = try await packageIdentity(at: fileURL)
            } else {
                data = try await CoordinatedFileManager().contentsOfFile(coordinatingAccessAt: fileURL)
            }
            try Task.checkCancellation()
            originData = data
            return data
        }

        let installedName = try await ReaderFileImportCollisionResolver.install(
            originalName: fileURL.lastPathComponent,
            collisionName: { number in
                if tag == nil { tag = collisionTag(try await sourceIdentity()) }
                let suffix = number == 1 ? "" : "-\(number)"
                return baseName + " (" + (tag ?? "") + suffix + ")" + ext
            },
            inspect: { name in
                let path = targetDirectory.appending(name)
                let destination = try path.fileURL(forRoot: drive.rootDirectory)
                // Do not compare through links, including dangling links. Their
                // names are occupied even when fileExists follows a missing target.
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) != nil {
                    return .different
                }
                let destinationIsDirectory = try await drive.directoryExists(at: path)
                let exists: Bool
                if destinationIsDirectory { exists = true }
                else { exists = try await drive.fileExists(at: path) }
                guard exists else { return .missing }
                guard destinationIsDirectory == isDirectory else { return .different }
                if destination.standardizedFileURL == fileURL.standardizedFileURL { return .identical }
                let source = try await sourceIdentity()
                let existing: Data
                if isDirectory { existing = try await packageIdentity(at: destination) }
                else { existing = try await drive.readFile(at: path) }
                return existing == source ? .identical : .different
            },
            copyExclusively: { name in
                try await drive.upload(from: fileURL, to: targetDirectory.appending(name))
            }
        )
        return targetDirectory.appending(installedName)
    }
}
