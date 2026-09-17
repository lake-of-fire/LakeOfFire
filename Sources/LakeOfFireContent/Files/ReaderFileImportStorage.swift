import Foundation
import SwiftCloudDrive
import SwiftUtilities
import LakeOfFireCore

/// The actual installation step used by ReaderFileManager, separated from metadata indexing.
@MainActor
enum ReaderFileImportStorage {
    static func install(fileURL: URL, targetDirectory: RootRelativePath, drive: CloudDrive) async throws -> RootRelativePath {
        var targetFilePath = targetDirectory.appending(fileURL.lastPathComponent)
        let targetURL = try targetFilePath.directoryURL(forRoot: drive.rootDirectory)

        var targetExists = false
        var distinctTargetExists = false
        var originData: Data?
        let targetIsFilePackage = targetURL.isFilePackage()
        if targetIsFilePackage {
            targetExists = true
            if fileURL.isFilePackage() {
                // Package comparison can involve thousands of files. Keep the
                // main actor free while a deterministic manifest is streamed
                // and hashed (path + type + size + bytes), and never follow a
                // symlink outside the package root.
                originData = try await Task.detached(priority: .utility) {
                    try fileURL.packageManifestDigest()
                }.value
                if targetURL != fileURL {
                    let targetDigest = try await Task.detached(priority: .utility) {
                        try targetURL.packageManifestDigest()
                    }.value
                    distinctTargetExists = targetDigest != originData
                }
            } else {
                distinctTargetExists = true
            }
        } else if try await drive.fileExists(at: targetFilePath) {
            let coordinatedFileManager = CoordinatedFileManager()
            originData = try await coordinatedFileManager.contentsOfFile(coordinatingAccessAt: fileURL)
            targetExists = true
            distinctTargetExists = targetURL != fileURL
            if !distinctTargetExists {
                distinctTargetExists = try await drive.readFile(at: targetFilePath) != originData
            }
        }
        if distinctTargetExists, let originData = originData {
            var needsUniqueName = targetIsFilePackage
            if !needsUniqueName {
                needsUniqueName = try await drive.readFile(at: targetFilePath) != originData
            }
            if needsUniqueName {
                // Make a unique filename
                var ext = fileURL.lakePathExtension
                if !ext.isEmpty {
                    ext = "." + ext
                }
                let hash = String(format: "%02X", stableHash(data: originData)).prefix(6).uppercased()
                let newFileName = fileURL.deletingPathExtension().lastPathComponent + " (\(hash))" + ext
                targetFilePath = targetDirectory.appending(newFileName)
            }
        }
        // Don't overwrite
        if distinctTargetExists || !targetExists {
            try await drive.upload(from: fileURL, to: targetFilePath)
        }
        return targetFilePath
    }
}
