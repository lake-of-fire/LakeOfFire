import SwiftUI
import AVFoundation
import SwiftCloudDrive
import SwiftUtilities
import SwiftUIDownloads
import RealmSwift
import RealmSwiftGaps
import LakeKit

public enum ReaderFileManagerError: Swift.Error {
    case invalidFileURL
    case driveMissing
}

class CloudDriveSyncStatusModel: ObservableObject {
    @Published var status: CloudDriveSyncStatus = .loadingStatus
    private var refreshTask: Task<Void, Never>? = nil
    
    @MainActor
    func refreshAsync(item: ContentFile, readerFileManager: ReaderFileManager) async {
        refreshTask?.cancel() // Cancel any existing task
        refreshTask = Task { [weak self] in
            // Continuously refresh status in the background
            await self?.periodicStatusRefresh(item: item, readerFileManager: readerFileManager)
        }
        await refreshTask?.value
    }
    
    private func periodicStatusRefresh(item: ContentFile, readerFileManager: ReaderFileManager) async {
        while !Task.isCancelled {
            do {
                let newStatus = try await item.cloudDriveSyncStatus(readerFileManager: readerFileManager)
                await MainActor.run {
                    self.status = newStatus
                }
                
                // Check if we should continue refreshing
                if newStatus != .downloading && newStatus != .uploading {
                    break // Stop refreshing if status is not downloading or uploading
                }
                
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                await MainActor.run {
                    print(error)
                }
                break // Exit on error
            }
        }
    }
    
    deinit {
        refreshTask?.cancel() // Ensure task is cancelled if the model is deinitialized
    }
}

public enum CloudDriveSyncStatus {
    case fileMissing
    case notInUbiquityContainer
    case downloading
    case uploading
    case synced
    case notSynced
    case loadingStatus
}

public class ReaderFileManager: ObservableObject {
    @MainActor @Published public var files: [ContentFile]?
    
    private let readerContentMimeTypes: [UTType] = [.plainText, .html, .epub, .epubZip]
    @MainActor public var readerContentFiles: [ContentFile]? {
        return files?.filter { readerContentMimeTypes.compactMap { $0.preferredMIMEType } .contains($0.mimeType) && !$0.isDeleted }
    }
    @MainActor public var ebookFiles: [ContentFile]? {
        return files?.filter { [UTType.epub, UTType.epubZip].compactMap { $0.preferredMIMEType } .contains($0.mimeType) && !$0.isDeleted }
    }
    
    @MainActor @Published private var cloudDrive: CloudDrive?
    @MainActor @Published private var localDrive: CloudDrive?
    public var ubiquityContainerIdentifier: String? = nil
    
    private var refreshAllFilesMetadataTask: Task<Void, Never>?
    
    public init() { }
    
    @MainActor
    public func initialize(ubiquityContainerIdentifier: String) async throws {
        self.ubiquityContainerIdentifier = ubiquityContainerIdentifier
        cloudDrive = try? await CloudDrive(ubiquityContainerIdentifier: ubiquityContainerIdentifier)
        localDrive = try? await CloudDrive(storage: .localDirectory(rootURL: Self.getDocumentsDirectory()))
        Task { [weak self] in
            try await self?.refreshAllFilesMetadata()
        }
    }
    
    @MainActor
    public func cloudDriveSyncStatus(readerFileURL: URL) async throws -> CloudDriveSyncStatus {
        try Self.validate(readerFileURL: readerFileURL)
        let relativePath = try Self.extractRelativePath(fileURL: readerFileURL)
        guard try await cloudDrive?.fileExists(at: relativePath) ?? false else {
            guard try await localDrive?.fileExists(at: relativePath) ?? false else {
                return .notInUbiquityContainer
            }
            return .notInUbiquityContainer
        }
        
        let localFileURL = try await localFileURL(forReaderFileURL: readerFileURL)
        let values = try localFileURL.resourceValues(forKeys: [.ubiquitousItemIsUploadingKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsDownloadingKey, .ubiquitousItemDownloadingStatusKey])
        if let isDownloading = values.ubiquitousItemIsDownloading, isDownloading {
            return .downloading
        } else if let isUploading = values.ubiquitousItemIsUploading, isUploading {
            return .uploading
        } else if let isUploaded = values.ubiquitousItemIsUploaded, isUploaded, let downloadingStatus = values.ubiquitousItemDownloadingStatus, downloadingStatus == .current {
            return .synced
        } else {
            return .notSynced
        }
    }
    
    @RealmBackgroundActor
    public func delete(readerFileURL: URL) async throws {
        let realm = try await Realm(configuration: ReaderContentLoader.historyRealmConfiguration, actor: RealmBackgroundActor.shared)
        try ReaderFileManager.validate(readerFileURL: readerFileURL)
        if let existing = realm.objects(ContentFile.self).filter(NSPredicate(format: "isDeleted == false AND url == %@", readerFileURL.absoluteString as CVarArg)).first {
            try await realm.asyncWrite {
                existing.isDeleted = true
            }
        }
        let (drive, relativePath) = try await extract(fileURL: readerFileURL)
        try await drive.removeFile(at: relativePath)
        Task.detached { [weak self] in
            try await self?.refreshAllFilesMetadata()
        }
    }
    
    @MainActor
    public static func get(fileURL: URL) async throws -> ContentFile? {
        let realm = try await Realm(configuration: ReaderContentLoader.historyRealmConfiguration, actor: MainActor.shared)
        try validate(readerFileURL: fileURL)
        let existing = realm.objects(ContentFile.self).filter(NSPredicate(format: "isDeleted == false AND url == %@", fileURL.absoluteString as CVarArg)).first
        return existing
    }
    
    private static func validate(readerFileURL: URL) throws {
        guard (readerFileURL.scheme == "reader-file" && readerFileURL.host == "local") || (readerFileURL.scheme == "ebook" && readerFileURL.host == "ebook") else {
            throw ReaderFileManagerError.invalidFileURL
        }
    }
    
    @MainActor
    private func extract(fileURL: URL) async throws -> (CloudDrive, RootRelativePath) {
        let relativePath = try Self.extractRelativePath(fileURL: fileURL)
        guard let driveLocation = fileURL.pathComponents.dropFirst(2).first else { throw ReaderFileManagerError.invalidFileURL }
        switch driveLocation {
        case "local":
            guard let localDrive = localDrive else {
                throw ReaderFileManagerError.driveMissing
            }
            return (localDrive, relativePath)
        case "icloud":
            guard let cloudDrive = cloudDrive else {
                throw ReaderFileManagerError.driveMissing
            }
            return (cloudDrive, relativePath)
        default:
            throw ReaderFileManagerError.invalidFileURL
        }
    }
    
    public func fileExists(fileURL: URL) async throws -> Bool {
        let (drive, relativePath) = try await extract(fileURL: fileURL)
        return try await drive.fileExists(at: relativePath)
    }
    
    public func directoryExists(directoryURL: URL) async throws -> Bool {
        let (drive, relativePath) = try await extract(fileURL: directoryURL)
        return try await drive.directoryExists(at: relativePath)
    }
    
    public func read(fileURL: URL) async throws -> Data? {
        let (drive, relativePath) = try await extract(fileURL: fileURL)
        return try await drive.readFile(at: relativePath)
    }
    
    @MainActor
    public func readerFileURL(for downloadable: Downloadable) async throws -> URL? {
        let fileURL = downloadable.localDestination
        let readerFileURL = try await readerFileURL(for: fileURL)
        return readerFileURL
    }
    
    @MainActor
    public func readerFileURL(for fileURL: URL, drive: CloudDrive? = nil) async throws -> URL? {
        let drives: [CloudDrive] = (drive == nil ? [cloudDrive, localDrive] : [drive]).filter({ $0?.isConnected ?? false }).compactMap({ $0 })
        for drive in drives {
            // This relativePath stuff is funky/fragile
            guard let relativePathStr = relativePath(for: fileURL, relativeTo: drive.rootDirectory) else {
                continue
            }
            let relativePath = RootRelativePath(path: relativePathStr)
            let matchFileURL = try relativePath.fileURL(forRoot: drive.rootDirectory)
            if matchFileURL.absoluteURL != fileURL.absoluteURL {
                continue
            }
            var normalizedPath = relativePath.path
            if normalizedPath.hasPrefix("./") {
                normalizedPath = String(normalizedPath.dropFirst(2))
            }
            if let encodedPath = "\(drive.ubiquityContainerIdentifier == nil ? "local" : "icloud")/\(normalizedPath)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                if fileURL.isEBookURL {
                    return URL(string: "ebook://ebook/load/\(encodedPath)")
                } else {
                    return URL(string: "reader-file://local/\(encodedPath)")
                }
            }
        }
        return nil
    }

    @MainActor
    public func importFile(fileURL: URL, fromDownloadURL downloadURL: URL?, restrictToReaderContentMimeTypes: Bool) async throws -> URL? {
        guard let drive = ((cloudDrive?.isConnected ?? false) ? cloudDrive : nil) ?? localDrive else { return nil }
        if restrictToReaderContentMimeTypes {
            let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            guard readerContentMimeTypes.compactMap({ $0.preferredMIMEType }).contains(mimeType) else {
                print("Invalid MIME type: \(mimeType) for path extension \(fileURL.pathExtension)")
                return nil
            }
        }
        
        let targetDirectory = Self.rootRelativePath(forURLExtension: downloadURL ?? fileURL)
        var targetFilePath = targetDirectory.appending(fileURL.lastPathComponent)
        let targetURL = try targetFilePath.directoryURL(forRoot: drive.rootDirectory)
        
        let shouldStopAccessingFile = fileURL.startAccessingSecurityScopedResource()
        defer {
            if shouldStopAccessingFile {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        
        try await drive.createDirectory(at: targetDirectory)
        
        var targetExists = false
        var distinctTargetExists = false
        var originData: Data?
        if targetURL.isFilePackage() {
            targetExists = true
            if fileURL.isFilePackage() {
                originData = try fileURL.concatenateDataInDirectory()
                distinctTargetExists = try targetURL != fileURL && targetURL.concatenateDataInDirectory() != originData
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
            if try await drive.readFile(at: targetFilePath) != originData {
                // Make a unique filename
                var ext = fileURL.pathExtension
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
        
        let contentRef = try await refreshFileMetadata(drive: drive, relativePath: targetFilePath)
        let realm = try await Realm(configuration: ReaderContentLoader.historyRealmConfiguration, actor: MainActor.shared)
        guard let content = realm.resolve(contentRef) else { return nil }
        Task.detached { [weak self] in
            try await self?.refreshAllFilesMetadata()
        }
        return content.url
    }
    
    @MainActor
    public func refreshAllFilesMetadata() async throws {
        refreshAllFilesMetadataTask?.cancel()
        refreshAllFilesMetadataTask = Task { @MainActor in
            do {
                guard localDrive != nil || cloudDrive != nil else { return }
                var files = [ThreadSafeReference<ContentFile>]()
                for drive in [localDrive, cloudDrive].compactMap({ $0 }) {
                    try Task.checkCancellation()
                    let discovered = try await refreshFilesMetadata(drive: drive)
                    files.append(contentsOf: discovered)
                }
                
                let discoveredFiles = files
                try await { @MainActor [weak self] in
                    try Task.checkCancellation()
                    guard let self = self else { return }
                    let realm = try await Realm(configuration: ReaderContentLoader.historyRealmConfiguration, actor: MainActor.shared)
                    let files = discoveredFiles.compactMap { realm.resolve($0) }
                    self.files = files.map { $0.freeze() }
                    objectWillChange.send()
                    let discoveredURLs = files.map { $0.url }

                    // Delete orphans
                    try await { @RealmBackgroundActor in
                        try Task.checkCancellation()
                        let realm = try await Realm(configuration: ReaderContentLoader.historyRealmConfiguration, actor: RealmBackgroundActor.shared)
                        let existingURLs = discoveredURLs.map { $0.absoluteString }
                        let orphans = realm.objects(ContentFile.self).filter(NSPredicate(format: "isDeleted == false AND NOT (url IN %@)", existingURLs))
                        try await realm.asyncWrite {
                            for orphan in orphans {
                                orphan.isDeleted = true
                            }
                        }
                    }()
                }()
            } catch {
                if !(error is CancellationError) {
                    Logger.shared.logger.error("\(error)")
                }
            }
        }
        await refreshAllFilesMetadataTask?.value
    }
    
    @MainActor
    func refreshFilesMetadata(drive: CloudDrive, relativePath: RootRelativePath? = nil) async throws -> [ThreadSafeReference<ContentFile>] {
        var files = [ThreadSafeReference<ContentFile>]()
        for url in try await drive.contentsOfDirectory(at: relativePath ?? .root, options: [.skipsHiddenFiles, .producesRelativePathURLs]) {
            try Task.checkCancellation()
            var tryRelativePath = RootRelativePath(path: url.relativePath)
            if let relativePath = relativePath {
                tryRelativePath.path = relativePath.path + "/" + tryRelativePath.path
            }
            if url.lastPathComponent.hasSuffix(".realm") || url.lastPathComponent.hasSuffix(".realm.lock") || url.lastPathComponent.hasSuffix(".realm.management") || url.lastPathComponent.hasSuffix(".realm.note") {
                continue
            }
            if !url.isFilePackage(), try await drive.directoryExists(at: tryRelativePath) {
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
        let absoluteFileURL = try relativePath.fileURL(forRoot: drive.rootDirectory)
        guard let readerFileURL = try await readerFileURL(for: absoluteFileURL, drive: drive) else {
            throw ReaderFileManagerError.invalidFileURL
        }
        let existing = realm.objects(ContentFile.self).filter(NSPredicate(format: "url == %@", readerFileURL.absoluteString as CVarArg)).first
        
        if let existing = existing {
            try await realm.asyncWrite {
                setMetadata(fileURL: readerFileURL, contentFile: existing, drive: drive)
            }
            return ThreadSafeReference(to: existing)
        } else {
            let contentFile = ContentFile()
            setMetadata(fileURL: readerFileURL, contentFile: contentFile, drive: drive)
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
        if contentFile.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contentFile.title = fileURL.deletingPathExtension().lastPathComponent
        }
        contentFile.isDeleted = false
        contentFile.mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        contentFile.isReaderModeByDefault = contentFile.mimeType == "text/plain"
        contentFile.publicationDate = Self.fileModificationDate(url: fileURL, drive: drive) ?? Date()
    }
    
    public func localFileURL(forReaderFileURL readerFileURL: URL) async throws -> URL {
        let (drive, relativePath) = try await extract(fileURL: readerFileURL)
        return try relativePath.fileURL(forRoot: drive.rootDirectory)
    }
    
    public func localDirectoryURL(forReaderFileURL readerFileURL: URL) async throws -> URL {
        let (drive, relativePath) = try await extract(fileURL: readerFileURL)
        return try relativePath.directoryURL(forRoot: drive.rootDirectory)
    }
    
    private static func extractRelativePath(fileURL: URL) throws -> RootRelativePath {
        try ReaderFileManager.validate(readerFileURL: fileURL)
        let relativePath = RootRelativePath(path: String(fileURL.pathComponents.dropFirst(3).joined(separator: "/")))
        return relativePath
    }
    
    private static func fileModificationDate(url: URL, drive: CloudDrive) -> Date? {
        guard let relativePath = try? Self.extractRelativePath(fileURL: url), let localURL = try? relativePath.fileURL(forRoot: drive.rootDirectory) else { return nil }
        do {
            let attr = try FileManager.default.attributesOfItem(atPath: localURL.path)
            return attr[FileAttributeKey.modificationDate] as? Date
        } catch {
            print(error)
            return nil
        }
    }
}

public extension ReaderFileManager {
    // Downloadables
    
    @MainActor
    func downloadable(url: URL, name: String) async throws -> Downloadable? {
        guard let drive = ((cloudDrive?.isConnected ?? false) ? cloudDrive : nil) ?? localDrive else { return nil }
        
        let targetDirectory = Self.rootRelativePath(forURLExtension: url)
        let targetFilePath = targetDirectory.appending(url.lastPathComponent)
        let targetURL = try targetFilePath.fileURL(forRoot: drive.rootDirectory)
        
        return Downloadable(
            url: url,
            name: name,
            localDestination: targetURL
        )
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
    static func rootRelativePath(forURLExtension url: URL) -> RootRelativePath {
        switch url.pathExtension.lowercased() {
        case "epub": return .ebooks.appending(url.host ?? "")
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

extension URL {
    func isFilePackage() -> Bool {
#if os(macOS)
        return NSWorkspace.shared.isFilePackage(atPath: path)
#else
        return false
#endif
    }
    
    func concatenateDataInDirectory(_ directoryURL: URL? = nil) throws -> Data {
        let fileManager = FileManager.default
        let sortedContents = try fileManager.contentsOfDirectory(at: (directoryURL ?? self), includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path })
        
        return try sortedContents.reduce(Data()) { result, fileURL in
            if fileManager.isDirectory(atPath: fileURL.path) {
                return try result + concatenateDataInDirectory(fileURL)
            } else {
                return try result + Data(contentsOf: fileURL)
            }
        }
    }
}

fileprivate extension FileManager {
    func isDirectory(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

fileprivate func relativePath(for fileURL: URL, relativeTo rootDirectory: URL) -> String? {
    let filePath = fileURL.path
    let rootPath = rootDirectory.path
    
    // Check if the file path is within the root directory
    guard filePath.hasPrefix(rootPath) else {
        print("File is not within the root directory.")
        return nil
    }
    
    // Extract the relative path
    let relativePath = String(filePath.dropFirst(rootPath.count))
    
    // Ensure the relative path does not start with a "/" to make it a true relative path
    let trimmedRelativePath = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    
    return trimmedRelativePath
}
