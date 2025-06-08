import SwiftUI
import AVFoundation
import SwiftCloudDrive
import SwiftUtilities
import SwiftUIDownloads
import RealmSwift
import RealmSwiftGaps
import LakeKit
import ZIPFoundation

@globalActor
private actor ReaderFileManagerActor {
    static let shared = ReaderFileManagerActor()
}

public enum ReaderFileManagerError: Swift.Error {
    case invalidFileURL
    case driveMissing
}

//public extension RootRelativePath {
//    static let documents = Self(path: "Documents")
//}

class CloudDriveSyncStatusModel: ObservableObject {
    @Published var status: CloudDriveSyncStatus = .loadingStatus
    private var refreshTask: Task<Void, Never>? = nil
    
    @MainActor
    func refreshAsync(item: ContentFile) async {
        refreshTask?.cancel() // Cancel any existing task
        refreshTask = Task { [weak self] in
            // Continuously refresh status in the background
            await self?.periodicStatusRefresh(item: item)
        }
        await refreshTask?.value
    }
    
    private func periodicStatusRefresh(item: ContentFile) async {
        while !Task.isCancelled {
            do {
                let newStatus = try await item.cloudDriveSyncStatus()
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
    // TODO: Migrate to a 'plugin registry' architecture instead of all these callbacks
    public static var fileDestinationProcessors = [(URL) async throws -> RootRelativePath?]()
    public static var readerFileURLProcessors = [@RealmBackgroundActor (URL, String) async throws -> URL?]()
    public static var fileProcessors = [@RealmBackgroundActor ([ContentFile]) async throws -> Void]()
    
    public static var shared = ReaderFileManager()
    
    // TODO: Pull these from callbacks per above
    public var readerContentMimeTypes: [UTType] = [.plainText, .html, .zip]
    
    @MainActor @Published public var files: [ContentFile]?
    
    @MainActor public var readerContentFiles: [ContentFile]? {
        return files?.filter { readerContentMimeTypes.compactMap { $0.preferredMIMEType } .contains($0.mimeType) && !$0.isDeleted }
    }
    
    private var hasInitializedUbiquityContainerIdentifier = false
    
    /*@MainActor*/ @Published public var cloudDrive: CloudDrive?
    //    /*@MainActor*/ @Published public var legacyCloudDrive: CloudDrive?
    /*@MainActor*/ @Published public var localDrive: CloudDrive?
    public var ubiquityContainerIdentifier: String? = nil {
        didSet {
            if hasInitializedUbiquityContainerIdentifier, oldValue != ubiquityContainerIdentifier {
                Task { [weak self] in
                    try await self?.refreshAllFilesMetadata()
                }
            }
        }
    }
    
    private var refreshAllFilesMetadataTask: Task<Void, Never>?
    
    public init() { }
    
    @MainActor
    public func initialize(ubiquityContainerIdentifier: String) async throws {
        self.ubiquityContainerIdentifier = ubiquityContainerIdentifier
        hasInitializedUbiquityContainerIdentifier = true
        cloudDrive = try? await CloudDrive(ubiquityContainerIdentifier: ubiquityContainerIdentifier, relativePathToRootInContainer: "Documents")
        //        legacyCloudDrive = try? await CloudDrive(ubiquityContainerIdentifier: ubiquityContainerIdentifier, relativePathToRootInContainer: "")
        localDrive = try? await CloudDrive(storage: .localDirectory(rootURL: Self.getDocumentsDirectory()))
        Task { [weak self] in
            try await self?.refreshAllFilesMetadata()
        }
    }
    
    @MainActor
    public func appSuspendedDidChange(isSuspended: Bool) {
        if isSuspended {
            refreshAllFilesMetadataTask?.cancel()
        } else {
            Task { @MainActor in
                try? await refreshAllFilesMetadata()
            }
        }
    }
    
    @MainActor public func files(ofTypes types: [UTType]) -> [ContentFile]? {
        return files?.filter { types.compactMap { $0.preferredMIMEType } .contains($0.mimeType) && !$0.isDeleted }
    }
    
    @MainActor
    public func cloudDriveSyncStatus(readerFileURL: URL) async throws -> CloudDriveSyncStatus {
        //        try Self.validate(readerFileURL: readerFileURL)
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
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.historyRealmConfiguration)
        //        try ReaderFileManager.validate(readerFileURL: readerFileURL)
        if let existing = realm.objects(ContentFile.self).filter(NSPredicate(format: "isDeleted == %@ AND url == %@", NSNumber(booleanLiteral: false), readerFileURL.absoluteString as CVarArg)).first {
            await realm.asyncRefresh()
            try await realm.asyncWrite {
                existing.isDeleted = true
                existing.refreshChangeMetadata(explicitlyModified: true)
            }
        }
        let (drive, relativePath) = try extractCloudDrivePath(fromReaderFileURL: readerFileURL)
        try await drive.removeFile(at: relativePath)
        Task.detached { [weak self] in
            try await self?.refreshAllFilesMetadata()
        }
    }
    
    @MainActor
    public static func get(fileURL: URL) async throws -> ContentFile? {
        let realm = try await Realm(configuration: ReaderContentLoader.historyRealmConfiguration, actor: MainActor.shared)
        //        try validate(readerFileURL: fileURL)
        let existing = realm.objects(ContentFile.self).filter(NSPredicate(format: "isDeleted == %@ AND url == %@", NSNumber(booleanLiteral: false), fileURL.absoluteString as CVarArg)).first
        return existing
    }
    
    //    private static func validate(readerFileURL: URL) throws {
    //        guard (readerFileURL.scheme == "reader-file" && readerFileURL.host == "file") || (readerFileURL.scheme == "ebook" && readerFileURL.host == "ebook") else {
    //            throw ReaderFileManagerError.invalidFileURL
    //        }
    //    }
    
    //    @MainActor
    private func extractCloudDrivePath(fromReaderFileURL fileURL: URL) throws -> (CloudDrive, RootRelativePath) {
        let relativePath = try Self.extractRelativePath(fileURL: fileURL)
        // Assumes /<host>/load/<local/icloud>/...
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
        let (drive, relativePath) = try extractCloudDrivePath(fromReaderFileURL: fileURL)
        return try await drive.fileExists(at: relativePath)
    }
    
    public func directoryExists(directoryURL: URL) async throws -> Bool {
        let (drive, relativePath) = try extractCloudDrivePath(fromReaderFileURL: directoryURL)
        return try await drive.directoryExists(at: relativePath)
    }
    
    public func read(fileURL: URL) async throws -> Data? {
        let (drive, relativePath) = try extractCloudDrivePath(fromReaderFileURL: fileURL)
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
            guard let relativePathStr = Self.relativePath(for: fileURL, relativeTo: drive.rootDirectory) else {
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
                for readerFileURLProcessor in Self.readerFileURLProcessors {
                    if let url = try await readerFileURLProcessor(fileURL, encodedPath) {
                        return url
                    }
                }
                return URL(string: "reader-file://file/load/" + encodedPath)
            }
        }
        return nil
    }
    
    @MainActor
    public func importFile(fileURL: URL, fromDownloadURL downloadURL: URL?) async throws -> URL? {
        guard let drive = ((cloudDrive?.isConnected ?? false) ? cloudDrive : nil) ?? localDrive else { return nil }
        
        let targetDirectory = try await Self.rootRelativePath(forImportedURL: downloadURL ?? fileURL, drive: drive)
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
        
        do {
            guard let contentRef = try await refreshFilesMetadata(
                drive: drive,
                relativePath: targetDirectory
            )?.first else {
                debugPrint("Warning: No file metadata returned for import")
                return nil
            }
            let realm = try await Realm(configuration: ReaderContentLoader.historyRealmConfiguration, actor: MainActor.shared)
            guard let content = realm.resolve(contentRef) else { return nil }
            Task.detached { [weak self] in
                try await self?.refreshAllFilesMetadata()
            }
            return content.url
        } catch {
            debugPrint("Error importing file:", error)
            throw error
        }
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
                    if let discovered = try await refreshFilesMetadata(drive: drive) {
                        files.append(contentsOf: discovered)
                    }
                }
                
                let discoveredFiles = files
                try await { @MainActor [weak self] in
                    try Task.checkCancellation()
                    guard let self = self else { return }
                    let realm = try await Realm(configuration: ReaderContentLoader.historyRealmConfiguration, actor: MainActor.shared)
                    let files = try discoveredFiles.compactMap {
                        try Task.checkCancellation()
                        return realm.resolve($0)
                    }
                    self.files = try files.map {
                        try Task.checkCancellation()
                        return $0.freeze()
                    }
                    objectWillChange.send()
                    let discoveredURLs = try files.map {
                        try Task.checkCancellation()
                        return $0.url
                    }
                    
                    // Delete orphans (objects with no corresponding file on disk)
                    try await { @RealmBackgroundActor in
                        try Task.checkCancellation()
                        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.historyRealmConfiguration)
                        let existingURLs = try discoveredURLs.map {
                            try Task.checkCancellation()
                            return $0.absoluteString
                        }
                        let orphans = realm.objects(ContentFile.self).filter(NSPredicate(format: "isDeleted == %@ AND NOT (url IN %@)", NSNumber(booleanLiteral: false), existingURLs))
                        //await realm.asyncRefresh()
                        try await realm.asyncWrite {
                            for orphan in orphans {
                                try Task.checkCancellation()
                                orphan.isDeleted = true
                                orphan.refreshChangeMetadata(explicitlyModified: true)
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
    
    static let additionalFilePackageSuffixesToAvoidDescendingInto = [
        ".epub",
    ]
    
    @MainActor
    func refreshFilesMetadata(drive: CloudDrive, relativePath: RootRelativePath? = nil) async throws -> [ThreadSafeReference<ContentFile>]? {
        var files: [ThreadSafeReference<ContentFile>]? = try await { @ReaderFileManagerActor [weak self] in
            guard let self else { return nil }
            var files = [ThreadSafeReference<ContentFile>]()
            var filesToUpdate: [(readerFileURL: URL, relativePath: RootRelativePath, drive: CloudDrive)] = []
            do {
                for url in try await drive.contentsOfDirectory(at: relativePath ?? .root, options: [.skipsHiddenFiles, .producesRelativePathURLs]) {
                    try Task.checkCancellation()
                    var tryRelativePath = RootRelativePath(path: url.relativePath)
                    if let relativePath, !relativePath.path.isEmpty {
                        tryRelativePath.path = relativePath.path + "/" + tryRelativePath.path
                    }
                    let lastPathComponent = url.lastPathComponent.lowercased()
                    if lastPathComponent.hasSuffix(".realm") || lastPathComponent.hasSuffix(".realm.lock") || lastPathComponent.hasSuffix(".realm.management") || lastPathComponent.hasSuffix(".realm.note") || lastPathComponent == "manabireaderlogs.zip" {
                        continue
                    }
                    if !url.isFilePackage(), !Self.additionalFilePackageSuffixesToAvoidDescendingInto.contains(where: { lastPathComponent.hasSuffix($0) }), try await drive.directoryExists(at: tryRelativePath) {
                        let discoveredFiles = try await refreshFilesMetadata(drive: drive, relativePath: tryRelativePath)
                        files.append(contentsOf: discoveredFiles ?? [])
                    } else {
                        let absoluteFileURL = try tryRelativePath.fileURL(forRoot: drive.rootDirectory)
                        if let readerFileURL = try await readerFileURL(for: absoluteFileURL, drive: drive) {
                            filesToUpdate.append((readerFileURL, tryRelativePath, drive))
                        }
                    }
                }
            } catch {
                if !(error is CancellationError) {
                    debugPrint("refreshFilesMetadata error:", error)
                }
                throw error
            }
            
            if !filesToUpdate.isEmpty {
                let updatedFiles = try await { @RealmBackgroundActor in
                    var updatedFiles = [ContentFile]()
                    var allFileRefs = [ThreadSafeReference<ContentFile>]()
                    var allFiles = [ContentFile]()
                    let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.historyRealmConfiguration)
                    
                    //await realm.asyncRefresh()
                    try await realm.asyncWrite {
                        for (readerFileURL, _, drive) in filesToUpdate {
                            try Task.checkCancellation()
                            
                            // TODO: Return pks instead of threadsafereferences (faster)
                            if let existing = realm.objects(ContentFile.self).filter(NSPredicate(format: "url == %@", readerFileURL.absoluteString as CVarArg)).first {
                                try Task.checkCancellation()
                                if setMetadata(fileURL: readerFileURL, contentFile: existing, drive: drive) {
                                    updatedFiles.append(existing)
                                }
                                allFileRefs.append(ThreadSafeReference(to: existing))
                                allFiles.append(existing)
                            } else {
                                let contentFile = ContentFile()
                                contentFile.url = readerFileURL
                                try Task.checkCancellation()
                                if setMetadata(fileURL: readerFileURL, contentFile: contentFile, drive: drive) {
                                    contentFile.updateCompoundKey()
                                    contentFile.isReaderModeByDefault = contentFile.mimeType == "text/plain" || ["htm", "html", "txt"].contains(readerFileURL.pathExtension.lowercased())
                                    realm.add(contentFile, update: .modified)
                                    updatedFiles.append(contentFile)
                                }
                                allFileRefs.append(ThreadSafeReference(to: contentFile))
                                allFiles.append(contentFile)
                            }
                        }
                    }
                    for fileProcessor in Self.fileProcessors {
                        try Task.checkCancellation()
                        try await fileProcessor(updatedFiles)
                    }
                    return allFileRefs
                }()
                files.append(contentsOf: updatedFiles)
            }
            return files
        }()
        
        return files
    }
    
    /// Note that ReaderContentMetadataSynchronizer keeps associated records in sync
    @RealmBackgroundActor
    private func setMetadata(fileURL: URL, contentFile: ContentFile, drive: CloudDrive) -> Bool {
        var metadataUpdated = false
        let fileModifiedAt = Self.fileModificationDate(url: fileURL, drive: drive)

        if !contentFile.isPhysicalMedia, contentFile.publicationDate != fileModifiedAt ?? Date() {
            contentFile.publicationDate = fileModifiedAt ?? Date()
            metadataUpdated = true
        }
        
        if contentFile.isDeleted {
            contentFile.isDeleted = false
            metadataUpdated = true
        }
        
        if metadataUpdated || contentFile.fileMetadataRefreshedAt ?? .distantPast <= fileModifiedAt ?? .distantPast {
            if contentFile.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                contentFile.title = fileURL.deletingPathExtension().lastPathComponent
            }
            contentFile.mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            
            // contentFile.url replace with on-disk url (make a new computed var for that?)
            if fileURL.pathExtension.lowercased() == "zip", let systemFileURL = try? localFileURL(forReaderFileURL: fileURL), let archive = try? Archive(url: systemFileURL, accessMode: .read) {
                let filePaths = RealmSwift.MutableSet<String>()
                filePaths.insert(objectsIn: archive.map { $0.path })
                contentFile.packageFilePaths = filePaths
            }
            
            contentFile.fileMetadataRefreshedAt = Date()
            contentFile.refreshChangeMetadata(explicitlyModified: true)
            return true
        }
        return false
    }
    
    public func localFileURL(forReaderFileURL readerFileURL: URL) throws -> URL {
        let (drive, relativePath) = try extractCloudDrivePath(fromReaderFileURL: readerFileURL)
        return try relativePath.fileURL(forRoot: drive.rootDirectory)
    }
    
    public func localDirectoryURL(forReaderFileURL readerFileURL: URL) throws -> URL {
        let (drive, relativePath) = try extractCloudDrivePath(fromReaderFileURL: readerFileURL)
        return try relativePath.directoryURL(forRoot: drive.rootDirectory)
    }
    
    private static func extractRelativePath(fileURL: URL) throws -> RootRelativePath {
        //        try ReaderFileManager.validate(readerFileURL: fileURL)
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
    
    public static func relativePath(for fileURL: URL, relativeTo rootDirectory: URL) -> String? {
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
}

public extension ReaderFileManager {
    // Downloadables
    
    @MainActor
    func downloadable(url: URL, name: String) async throws -> Downloadable? {
        guard let drive = ((cloudDrive?.isConnected ?? false) ? cloudDrive : nil) ?? localDrive else { return nil }
        
        let targetDirectory = try await Self.rootRelativePath(forImportedURL: url, drive: drive)
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
    static func rootRelativePath(forImportedURL url: URL, drive: CloudDrive) async throws -> RootRelativePath {
        switch url.pathExtension.lowercased() {
        default:
            for fileDestinationProcessor in fileDestinationProcessors {
                if let destination = try await fileDestinationProcessor(url) {
                    return destination
                }
            }
            return .root
        }
    }
    
    static func getDocumentsDirectory() -> URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
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
