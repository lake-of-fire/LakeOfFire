import Foundation
import SwiftCloudDrive

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
        let relativePath = Self.rootRelativePath(forFileName: fileName)
        try await drive.createDirectory(at: relativePath)
        try await drive.upload(from: fileURL, to: relativePath)
        return try relativePath.fileURL(forRoot: drive.rootDirectory)
    }
}
    
private extension ReaderFileManager {
    static func rootRelativePath(forFileName fileName: String) -> RootRelativePath {
        switch fileName.pathExtension.lowercased() {
        case "epub": return .ebooks
        default: return RootRelativePath(path: "")
        }
    }
    
    static func getDocumentsDirectory() -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}

public extension RootRelativePath {
    static let ebooks = Self(path: "Books")
}
