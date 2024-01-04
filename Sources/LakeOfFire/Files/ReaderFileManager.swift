import SwiftUI
import AVFoundation
import SwiftCloudDrive
import SwiftUtilities
import RealmSwift
import RealmSwiftGaps

public enum ReaderFileManagerError: Swift.Error {
    case invalidFileURL
}

@MainActor
public class ReaderFileManager: ObservableObject {
    @Published public var files: [ContentFile]?
    
    private let readerContentMimeTypes: [UTType] = [.plainText, .html]
    public var readerContentFiles: [ContentFile]? {
        return files?.filter { readerContentMimeTypes.compactMap { $0.preferredMIMEType } .contains($0.mimeType) }
    }
    
    private var cloudDrive: CloudDrive?
    private var localDrive: CloudDrive?
    public var ubiquityContainerIdentifier: String? = nil
    
    public init() { }
    
    public init(ubiquityContainerIdentifier: String) async throws {
        self.ubiquityContainerIdentifier = ubiquityContainerIdentifier
        cloudDrive = try? await CloudDrive(ubiquityContainerIdentifier: ubiquityContainerIdentifier)
        localDrive = try? await CloudDrive(storage: .localDirectory(rootURL: Self.getDocumentsDirectory()))
        Task.detached { [weak self] in
            try await self?.refreshAllFilesMetadata()
        }
    }
    
    @RealmBackgroundActor
    public func delete(readerFileURL: URL) async throws {
        let realm = try await Realm(configuration: ReaderContentLoader.historyRealmConfiguration, actor: RealmBackgroundActor.shared)
        guard readerFileURL.scheme == "reader-file" else {
            throw ReaderFileManagerError.invalidFileURL
        }
        if let existing = realm.objects(ContentFile.self).filter(NSPredicate(format: "isDeleted == false AND url == %@", readerFileURL.absoluteString as CVarArg)).first {
            try await realm.asyncWrite {
                existing.isDeleted = true
            }
        }
        let relativePath = RootRelativePath(path: String(readerFileURL.path.dropFirst()))
        switch readerFileURL.host {
        case "local":
            try await localDrive?.removeFile(at: relativePath)
        case "icloud":
            try await cloudDrive?.removeFile(at: relativePath)
        default:
            throw ReaderFileManagerError.invalidFileURL
        }
        Task.detached { [weak self] in
            try await self?.refreshAllFilesMetadata()
        }
    }
    
    @MainActor
    public static func get(fileURL: URL) async throws -> ContentFile? {
        let realm = try await Realm(configuration: ReaderContentLoader.historyRealmConfiguration, actor: MainActor.shared)
        guard fileURL.scheme == "reader-file" else {
            throw ReaderFileManagerError.invalidFileURL
        }
        let existing = realm.objects(ContentFile.self).filter(NSPredicate(format: "isDeleted == false AND url == %@", fileURL.absoluteString as CVarArg)).first
        return existing
    }
    
    public func read(fileURL: URL) async throws -> Data? {
        guard fileURL.scheme == "reader-file" else {
            throw ReaderFileManagerError.invalidFileURL
        }
        let relativePath = RootRelativePath(path: String(fileURL.path.dropFirst()))
        var data: Data?
        switch fileURL.host {
        case "local":
            data = try await localDrive?.readFile(at: relativePath)
        case "icloud":
            data = try await cloudDrive?.readFile(at: relativePath)
        default:
            throw ReaderFileManagerError.invalidFileURL
        }
        return data
    }
    
    public func importFile(fileURL: URL, restrictToReaderContentMimeTypes: Bool) async throws -> URL? {
        guard let drive = ((cloudDrive?.isConnected ?? false) ? cloudDrive : nil) ?? localDrive else { return nil }
        if restrictToReaderContentMimeTypes {
            let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            guard readerContentMimeTypes.compactMap({ $0.preferredMIMEType }).contains(mimeType) else { return nil }
        }

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
        let contentRef = try await refreshFileMetadata(drive: drive, relativePath: targetFilePath)
        let realm = try await Realm(configuration: ReaderContentLoader.historyRealmConfiguration, actor: MainActor.shared)
        guard let content = realm.resolve(contentRef) else { return nil }
        Task.detached { [weak self] in
            try await self?.refreshAllFilesMetadata()
        }
        return content.url
    }
    
    public func refreshAllFilesMetadata() async throws {
        guard localDrive != nil || cloudDrive != nil else { return }
        var files = [ThreadSafeReference<ContentFile>]()
        for drive in [cloudDrive, localDrive].compactMap({ $0 }) {
            let discovered = try await refreshFilesMetadata(drive: drive)
            files.append(contentsOf: discovered)
        }
        
        let discoveredFiles = files
        try await Task { @MainActor [weak self] in
            guard let self = self else { return }
            let realm = try await Realm(configuration: ReaderContentLoader.historyRealmConfiguration, actor: MainActor.shared)
            let files = discoveredFiles.compactMap { realm.resolve($0) }
            self.files = files.map { $0.freeze() }
            objectWillChange.send()
            let discoveredURLs = files.map { $0.url }
            
            // Delete orphans
            try await Task.detached { @RealmBackgroundActor in
                let realm = try await Realm(configuration: ReaderContentLoader.historyRealmConfiguration, actor: RealmBackgroundActor.shared)
                let existingURLs = discoveredURLs.map { $0.absoluteString }
                let orphans = realm.objects(ContentFile.self).filter(NSPredicate(format: "isDeleted == false AND NOT (url IN %@)", existingURLs))
                try await realm.asyncWrite {
                    for orphan in orphans {
                        orphan.isDeleted = true
                    }
                }
            }.value
        }.value
    }
    
    func refreshFilesMetadata(drive: CloudDrive, relativePath: RootRelativePath? = nil) async throws -> [ThreadSafeReference<ContentFile>] {
        var files = [ThreadSafeReference<ContentFile>]()
        for url in try await drive.contentsOfDirectory(at: relativePath ?? .root, options: [.skipsHiddenFiles, .producesRelativePathURLs]) {
            var tryRelativePath = RootRelativePath(path: url.relativePath)
            if let relativePath = relativePath {
                tryRelativePath.path = relativePath.path + "/" + tryRelativePath.path
            }
            if try await drive.directoryExists(at: tryRelativePath) {
                let discoveredFiles = try await refreshFilesMetadata(drive: drive, relativePath: tryRelativePath)
                files.append(contentsOf: discoveredFiles)
            } else {
                let discoveredFile = try await refreshFileMetadata(drive: drive, relativePath: tryRelativePath)
                files.append(discoveredFile)
            }
        }
        return files
    }
    
    @RealmBackgroundActor
    private func refreshFileMetadata(drive: CloudDrive, relativePath: RootRelativePath) async throws -> ThreadSafeReference<ContentFile> {
        let realm = try await Realm(configuration: ReaderContentLoader.historyRealmConfiguration, actor: RealmBackgroundActor.shared)
        guard let fileURL = URL(string: "reader-file://\(drive.ubiquityContainerIdentifier == nil ? "local" : "icloud")/\(relativePath.path)") else {
            throw ReaderFileManagerError.invalidFileURL
        }
        let existing = realm.objects(ContentFile.self).filter(NSPredicate(format: "url == %@", fileURL.absoluteString as CVarArg)).first
        
        if let existing = existing {
            try await realm.asyncWrite {
                setMetadata(fileURL: fileURL, contentFile: existing, drive: drive)
            }
            return ThreadSafeReference(to: existing)
        } else {
            let contentFile = ContentFile()
            setMetadata(fileURL: fileURL, contentFile: contentFile, drive: drive)
            contentFile.updateCompoundKey()
            try await realm.asyncWrite {
                realm.add(contentFile, update: .modified)
            }
            return ThreadSafeReference(to: contentFile)
        }
    }
    
    @RealmBackgroundActor
    private func setMetadata(fileURL: URL, contentFile: ContentFile, drive: CloudDrive) {
        contentFile.url = fileURL
        contentFile.title = fileURL.lastPathComponent
        contentFile.isDeleted = false
        contentFile.mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        contentFile.isReaderModeByDefault = contentFile.mimeType == "text/plain"
        contentFile.publicationDate = fileModificationDate(url: fileURL, drive: drive) ?? Date()
    }
}

fileprivate func fileModificationDate(url: URL, drive: CloudDrive) -> Date? {
    let relativePath = RootRelativePath(path: String(url.path.dropFirst()))
    guard let localURL = try? relativePath.fileURL(forRoot: drive.rootDirectory) else { return nil }
    do {
        let attr = try FileManager.default.attributesOfItem(atPath: localURL.path)
        return attr[FileAttributeKey.modificationDate] as? Date
    } catch {
        print(error)
        return nil
    }
}

extension ReaderFileManager: CloudDriveObserver {
    nonisolated public func cloudDriveDidChange(_ drive: CloudDrive, rootRelativePaths: [RootRelativePath]) {
        Task {
            try await refreshAllFilesMetadata()
        }
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
