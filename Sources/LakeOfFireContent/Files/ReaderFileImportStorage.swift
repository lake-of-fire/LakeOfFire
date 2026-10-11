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

        // SwiftCloudDrive's pinned resolver appends paths without validating
        // their components. Own parent admission here; occupied leaf symlinks
        // remain collisions and must never be followed for comparison.
        let validatedTargetDirectory = try validatedImportDirectory(
            targetDirectory, root: drive.rootDirectory
        )

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
                // Reject any parent replacement observed after an asynchronous
                // comparison/retry before using this candidate.
                guard try validatedImportDirectory(targetDirectory, root: drive.rootDirectory)
                    == validatedTargetDirectory else {
                    throw CocoaError(.fileWriteInvalidFileName)
                }
                let lexicalDestination = validatedTargetDirectory
                    .appendingPathComponent(name)

                // Do not invoke the strict resolver on an occupied leaf symlink:
                // that would reject the collision before the resolver can choose
                // the next suffix. Preserve the link and treat its name as busy.
                if (try? FileManager.default.destinationOfSymbolicLink(
                    atPath: lexicalDestination.path
                )) != nil {
                    return .different
                }

                let destination = try path.fileURL(forRoot: drive.rootDirectory)
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
                guard try validatedImportDirectory(targetDirectory, root: drive.rootDirectory)
                    == validatedTargetDirectory else {
                    throw CocoaError(.fileWriteInvalidFileName)
                }
                try await drive.upload(from: fileURL, to: targetDirectory.appending(name))
            }
        )
        return targetDirectory.appending(installedName)
    }

    private static func validatedImportDirectory(
        _ directory: RootRelativePath, root: URL
    ) throws -> URL {
        guard root.isFileURL, root.hasDirectoryPath,
              !directory.path.hasPrefix("/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        var components = directory.path.split(separator: "/", omittingEmptySubsequences: false)
        if components.last == "" { components.removeLast() }
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        // Resolve the selected root itself (e.g. macOS /var -> /private/var),
        // then reject links in every relative parent component.
        var current = root.resolvingSymlinksInPath().standardizedFileURL
        guard try FileManager.default.attributesOfItem(atPath: current.path)[.type]
            as? FileAttributeType == .typeDirectory else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        for component in components {
            current.appendPathComponent(String(component), isDirectory: true)
            guard try FileManager.default.attributesOfItem(atPath: current.path)[.type]
                as? FileAttributeType == .typeDirectory else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        }
        return current
    }

}
