import Foundation
import SwiftCloudDrive
import SwiftUtilities

public actor ReaderFileManager: ObservableObject {
    var cloudDrive: CloudDrive?
    var localDrive: CloudDrive?
    
    public init() {
    }
    
    public init(ubiquityContainerIdentifier: String) async throws {
        cloudDrive = try? await CloudDrive(ubiquityContainerIdentifier: ubiquityContainerIdentifier)
        localDrive = try? await CloudDrive(storage: .localDirectory(rootURL: Self.getDocumentsDirectory()))
    }
    
    public func importFile(fileURL: URL) async throws -> URL? {
        guard let drive = ((cloudDrive?.isConnected ?? false) ? cloudDrive : nil) ?? localDrive else { return nil }
        let fileName = fileURL.lastPathComponent
        let targetDirectory = Self.rootRelativePath(forFileName: fileName)
        var targetFilePath = targetDirectory.appending(fileName)
        try await drive.createDirectory(at: targetDirectory)
        let originData = try await FileManager.default.contentsOfFile(coordinatingAccessAt: fileURL)
        if try await drive.fileExists(at: targetFilePath) {
            if try await drive.readFile(at: targetFilePath) != originData {
                var ext = fileURL.pathExtension
                if !ext.isEmpty {
                    ext = "." + ext
                }
                let hash = String(format: "%02X", stableHash(data: originData)).prefix(6).uppercased()
                let newFileName = fileURL.deletingPathExtension().lastPathComponent + " (\(hash))" + ext
                targetFilePath = targetDirectory.appending(newFileName)
                try await drive.upload(from: fileURL, to: targetFilePath)
            }
        } else {
            try await drive.upload(from: fileURL, to: targetFilePath)
        }
        return try targetFilePath.fileURL(forRoot: drive.rootDirectory)
    }
}
    
private extension ReaderFileManager {
    static func rootRelativePath(forFileName fileName: String) -> RootRelativePath {
        switch fileName.pathExtension.lowercased() {
        case "epub": return .ebooks
        default: return .root
        }
    }
    
    static func getDocumentsDirectory() -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}

public extension RootRelativePath {
    static let ebooks = Self(path: "Books")
}
