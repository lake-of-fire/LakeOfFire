import Foundation
import SwiftCloudDrive
import SwiftUtilities
import LakeOfFireCore

/// Installs without overwriting an existing item. Content identity, not URL inequality,
/// decides whether an existing destination can be reused.
@MainActor
enum ReaderFileImportStorage {
    static func install(fileURL: URL, targetDirectory: RootRelativePath, drive: CloudDrive) async throws -> RootRelativePath {
        let isPackage = fileURL.isFilePackage()
        var originData: Data?
        var collisionHash: String?
        var collision = 0
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.lakePathExtension.isEmpty ? "" : "." + fileURL.lakePathExtension
        var candidate = targetDirectory.appending(fileURL.lastPathComponent)

        func sourceIdentity() async throws -> Data {
            if let originData { return originData }
            let data: Data
            if isPackage {
                let work = Task.detached(priority: .utility) { try fileURL.packageManifestDigest() }
                data = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            } else {
                data = try await CoordinatedFileManager().contentsOfFile(coordinatingAccessAt: fileURL)
            }
            try Task.checkCancellation()
            originData = data
            return data
        }

        func existingMatches(_ path: RootRelativePath, at destination: URL) async throws -> Bool {
            if destination.standardizedFileURL == fileURL.standardizedFileURL { return true }
            guard destination.isFilePackage() == isPackage else { return false }
            let source = try await sourceIdentity()
            if isPackage {
                let work = Task.detached(priority: .utility) { try destination.packageManifestDigest() }
                let digest = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                return digest == source
            }
            return try await drive.readFile(at: path) == source
        }

        while true {
            try Task.checkCancellation()
            let destination = try candidate.fileURL(forRoot: drive.rootDirectory)
            let exists: Bool
            if destination.isFilePackage() {
                exists = true
            } else {
                exists = try await drive.fileExists(at: candidate)
            }
            if exists {
                if try await existingMatches(candidate, at: destination) { return candidate }
            } else {
                do {
                    try await drive.upload(from: fileURL, to: candidate)
                    return candidate
                } catch {
                    // A concurrent import may have installed the same name after our check.
                    // Only an existing-destination error is retried; never swallow I/O failure.
                    let nsError = error as NSError
                    guard nsError.domain == NSCocoaErrorDomain,
                          nsError.code == CocoaError.fileWriteFileExists.rawValue else { throw error }
                    if try await existingMatches(candidate, at: destination) { return candidate }
                }
            }
            if collisionHash == nil {
                let identity = try await sourceIdentity()
                collisionHash = String(format: "%02X", stableHash(data: identity)).prefix(6).uppercased()
            }
            guard collision < Int.max else { throw CocoaError(.fileWriteFileExists) }
            collision += 1
            let suffix = collision == 1 ? "" : "-\(collision)"
            candidate = targetDirectory.appending(baseName + " (" + (collisionHash ?? "") + suffix + ")" + ext)
        }
    }
}
