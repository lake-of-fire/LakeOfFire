import SwiftUI
import AVFoundation
@preconcurrency import SwiftCloudDrive
import SwiftUtilities
import SwiftUIDownloads
import RealmSwift
import RealmSwiftGaps
import LakeKit
import ZIPFoundation
import UniformTypeIdentifiers
import LakeOfFireCore
import LakeOfFireAdblock

public enum ReaderFileManagerError: Swift.Error {
    case invalidFileURL
    case driveMissing
}

//public extension RootRelativePath {
//    static let documents = Self(path: "Documents")
//}

public enum CloudDriveSyncStatus: Sendable {
    case fileMissing
    case localOnly
    case cloudOnly
    case downloading
    case uploading
    case availableLocally
    case loadingStatus
}

public class ReaderFileManager: ObservableObject, @unchecked Sendable {
    public static let readerBackingStatusRefreshRequestedNotification = Notification.Name("ReaderFileManager.readerBackingStatusRefreshRequested")

    private enum ReaderBackingStorageLocation: String {
        case local
        case icloud
    }

    private struct ReaderBackingPathContext {
        let relativePath: RootRelativePath
        let storageLocation: ReaderBackingStorageLocation
        let canonicalURL: URL
        let localRootURL: URL?
        let cloudRootURL: URL?
        let activeRootURL: URL?
        let localRootExists: Bool
        let cloudRootExists: Bool
    }

    private struct ReaderBackingAvailability {
        let status: CloudDriveSyncStatus
        let localURL: URL?
        let requestedDownload: Bool
    }

    private enum ContentFileIndexDecision {
        case skipArtifact
        case skipUnsupported(mimeType: String?)
        case index(reason: String, mimeType: String?)
    }

    // TODO: Migrate to a 'plugin registry' architecture instead of all these callbacks
    nonisolated(unsafe) public static var fileDestinationProcessors = [(URL) async throws -> RootRelativePath?]()
    nonisolated(unsafe) public static var readerFileURLProcessors = [@RealmBackgroundActor (URL, String) async throws -> URL?]()
    nonisolated(unsafe) public static var fileProcessors = [@RealmBackgroundActor ([ContentFile]) async throws -> Void]()
    
    nonisolated(unsafe) public static var shared = ReaderFileManager()

    private let defaultLocalRootURLProvider: @Sendable () -> URL

    public init() {
        defaultLocalRootURLProvider = { Self.getDocumentsDirectory() }
    }

    init(defaultLocalRootURLProvider: @escaping @Sendable () -> URL) {
        self.defaultLocalRootURLProvider = defaultLocalRootURLProvider
    }
    
    // TODO: Pull these from callbacks per above
    public var readerContentMimeTypes: [UTType] = [.plainText, .html, UTType(filenameExtension: "md") ?? UTType(importedAs: "net.daringfireball.markdown"), .zip]
    
    @MainActor @Published public var files: [ContentFile]?
    
    @MainActor public var readerContentFiles: [ContentFile]? {
        let ebookMimeTypes = Set([UTType.epub, .epubZip].compactMap { $0.preferredMIMEType?.lowercased() })

        return files?.filter { content in
            guard !content.isDeleted else { return false }

            let mimeType = content.mimeType.lowercased()
            if ebookMimeTypes.contains(mimeType) || content.url.lakePathExtension.lowercased() == "epub" {
                return false
            }

            return ReaderContentLoader.supportsReaderContent(mimeType: content.mimeType, pathExtension: content.url.lakePathExtension)
        }
    }
    
    private var hasInitializedUbiquityContainerIdentifier = false
    
    /*@MainActor*/ public var cloudDrive: CloudDrive? {
        didSet {
            Task { @MainActor in
                objectWillChange.send()
            }
        }
    }
    //    /*@MainActor*/ @Published public var legacyCloudDrive: CloudDrive?
    /*@MainActor*/ public var localDrive: CloudDrive? {
        didSet {
            Task { @MainActor in
                objectWillChange.send()
            }
        }
    }
    
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

    private static let internalStorageRootPrefixes: Set<String> = [
        "manabi-caches",
        "manabi-dictionaries",
        "manabi-dictionary-assets",
        "manabi-fonts",
    ]
    private static let transientRootPrefixes: Set<String> = [
        "ReaderFileDeletion.",
    ]
    
    public func canonicalReaderBackingURL(for contentURL: URL) -> URL? {
        guard var components = URLComponents(url: contentURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.query = nil
        components.fragment = nil
        guard let strippedURL = components.url else {
            return nil
        }
        if strippedURL.isReaderFileURL {
            return strippedURL
        }
        let absoluteString = strippedURL.absoluteString
        if absoluteString.hasPrefix("ebook://ebook/load/") {
            return URL(string: absoluteString.replacingOccurrences(of: "ebook://ebook/load/", with: "reader-file://file/load/"))
        }
        if absoluteString.hasPrefix("mokuro://mokuro/load/") {
            return URL(string: absoluteString.replacingOccurrences(of: "mokuro://mokuro/load/", with: "reader-file://file/load/"))
        }
        return nil
    }

    public func resolveReadableLocalURL(forReaderBackingURL readerBackingURL: URL) async throws -> URL {
        let availability = try await evaluateAvailability(
            forReaderBackingURL: readerBackingURL,
            requestDownloadIfNeeded: true
        )
        switch availability.status {
        case .localOnly, .availableLocally:
            guard let localURL = availability.localURL else {
                throw ReaderFileAccessError.notAvailableOffline
            }
            return localURL
        case .downloading:
            throw ReaderFileAccessError.downloadInProgress
        case .cloudOnly, .fileMissing, .loadingStatus, .uploading:
            throw ReaderFileAccessError.notAvailableOffline
        }
    }
    
    @MainActor
    public func initialize(ubiquityContainerIdentifier: String) async throws {
        self.ubiquityContainerIdentifier = ubiquityContainerIdentifier
        hasInitializedUbiquityContainerIdentifier = true
        cloudDrive = try? await CloudDrive(ubiquityContainerIdentifier: ubiquityContainerIdentifier, relativePathToRootInContainer: "Documents")
        cloudDrive?.observer = self
        //        legacyCloudDrive = try? await CloudDrive(ubiquityContainerIdentifier: ubiquityContainerIdentifier, relativePathToRootInContainer: "")
        localDrive = try? await CloudDrive(storage: .localDirectory(rootURL: defaultLocalRootURLProvider()))
        localDrive?.observer = self
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
        let allowedMimeTypes = Set(types.compactMap { $0.preferredMIMEType?.lowercased() })
        return files?.filter {
            !$0.isDeleted && (
                allowedMimeTypes.contains($0.mimeType.lowercased())
                || (allowedMimeTypes.contains("text/markdown") && ReaderContentLoader.detectFileFormat(mimeType: $0.mimeType, pathExtension: $0.url.lakePathExtension) == .markdown)
            )
        }
    }
    
    @MainActor
    public func cloudDriveSyncStatus(forReaderBackingURL readerBackingURL: URL) async throws -> CloudDriveSyncStatus {
        let availability = try await evaluateAvailability(
            forReaderBackingURL: readerBackingURL,
            requestDownloadIfNeeded: false
        )
        return availability.status
    }

    @MainActor
    public func cloudDriveSyncStatus(readerFileURL: URL) async throws -> CloudDriveSyncStatus {
        guard let readerBackingURL = canonicalReaderBackingURL(for: readerFileURL) else {
            return .fileMissing
        }
        return try await cloudDriveSyncStatus(forReaderBackingURL: readerBackingURL)
    }

    @MainActor
    public func deleteEligibility(forReaderBackingURL readerBackingURL: URL) async -> ReaderFileDeleteEligibility {
        guard let canonicalURL = canonicalReaderBackingURL(for: readerBackingURL) else {
            return .blockedLoadingStatus
        }
        let status = (try? await cloudDriveSyncStatus(forReaderBackingURL: canonicalURL)) ?? .loadingStatus
        switch status {
        case .cloudOnly:
            return .blockedCloudOnly
        case .loadingStatus:
            return .blockedLoadingStatus
        default:
            return .allowed
        }
    }
    
    @RealmBackgroundActor
    public func delete(readerFileURL contentURL: URL) async throws {
        guard let readerBackingURL = canonicalReaderBackingURL(for: contentURL) else {
            throw ReaderFileDeleteError.removeFailed()
        }
        let pathContext = try readerBackingPathContext(for: readerBackingURL)
        let eligibility = await deleteEligibility(forReaderBackingURL: readerBackingURL)
        switch eligibility {
        case .blockedCloudOnly:
            throw ReaderFileDeleteError.blockedCloudOnly
        case .blockedLoadingStatus:
            throw ReaderFileDeleteError.blockedLoadingStatus
        case .allowed:
            break
        }

        let status = try await cloudDriveSyncStatus(forReaderBackingURL: readerBackingURL)
        if status == .fileMissing {
            try await markDeleted(contentURL: contentURL)
            await removeDeletedFileFromPublishedFiles(matching: readerBackingURL)
            Task { @MainActor [weak self] in
                try await self?.refreshAllFilesMetadata()
            }
            return
        }

        let drive: CloudDrive
        if status == .localOnly, let localDrive {
            drive = localDrive
        } else {
            drive = try extractCloudDrivePath(fromReaderFileURL: pathContext.canonicalURL).0
        }
        do {
            if try await drive.directoryExists(at: pathContext.relativePath) {
                try await drive.removeDirectory(at: pathContext.relativePath)
            } else {
                try await drive.removeFile(at: pathContext.relativePath)
            }
        } catch {
            throw ReaderFileDeleteError.removeFailed(underlyingDescription: error.localizedDescription)
        }
        try await markDeleted(contentURL: contentURL)
        await removeDeletedFileFromPublishedFiles(matching: readerBackingURL)
        Task { @MainActor [weak self] in
            try await self?.refreshAllFilesMetadata()
        }
    }
    
    @RealmBackgroundActor
    public static func contentFilePrimaryKey(for fileURL: URL) async throws -> String? {
        if isInternalStorageReaderFileURL(fileURL) {
            return nil
        }
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.historyRealmConfiguration)
        return realm.objects(ContentFile.self)
            .filter(NSPredicate(format: "isDeleted == %@ AND url == %@", NSNumber(booleanLiteral: false), fileURL.absoluteString as CVarArg))
            .first?
            .compoundKey
    }

    @RealmBackgroundActor
    public static func mimeType(forContentFilePrimaryKey primaryKey: String) async throws -> String? {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.historyRealmConfiguration)
        return realm.object(ofType: ContentFile.self, forPrimaryKey: primaryKey)?.mimeType
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
        let readerBackingURL = canonicalReaderBackingURL(for: fileURL) ?? fileURL
        let readableURL = try await resolveReadableLocalURL(forReaderBackingURL: readerBackingURL)
        if readableURL.isFileURL, FileManager.default.fileExists(atPath: readableURL.path) {
            let coordinatedFileManager = CoordinatedFileManager()
            return try await coordinatedFileManager.contentsOfFile(coordinatingAccessAt: readableURL)
        }
        let (drive, relativePath) = try extractCloudDrivePath(fromReaderFileURL: readerBackingURL)
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
    public func ensureImported(downloadable: Downloadable) async throws -> URL? {
        guard await downloadable.existsLocally() else { return nil }
        if let existingReaderURL = try await readerFileURL(for: downloadable) {
            try await refreshMetadataForExistingLibraryFile(downloadable.localDestination)
            return existingReaderURL
        }
        return try await importFile(
            fileURL: downloadable.localDestination,
            fromDownloadURL: downloadable.url
        )
    }

    @MainActor
    private func refreshMetadataForExistingLibraryFile(_ fileURL: URL) async throws {
        let drives = [cloudDrive, localDrive].compactMap { drive in
            drive?.isConnected == true ? drive : nil
        }
        for drive in drives {
            guard let relativePath = Self.relativePath(for: fileURL, relativeTo: drive.rootDirectory) else { continue }
            let parentPath = URL(fileURLWithPath: relativePath).deletingLastPathComponent().relativePath
            let parent = RootRelativePath(path: parentPath == "." ? "" : parentPath)
            let discoveredReferences = try await refreshFilesMetadata(drive: drive, relativePath: parent) ?? []
            try await publishDiscoveredFiles(discoveredReferences)
            return
        }
    }

    @MainActor
    private func publishDiscoveredFiles(_ references: [ThreadSafeReference<ContentFile>]) async throws {
        guard !references.isEmpty else { return }
        let realm = try await Realm.open(configuration: ReaderContentLoader.historyRealmConfiguration)
        var mergedFiles = files ?? []
        for reference in references {
            guard let discoveredFile = realm.resolve(reference), !discoveredFile.isDeleted else { continue }
            if let index = mergedFiles.firstIndex(where: { $0.url == discoveredFile.url }) {
                mergedFiles[index] = discoveredFile
            } else {
                mergedFiles.append(discoveredFile)
            }
        }
        files = mergedFiles.filter { !$0.isDeleted }
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
        
        do {
            _ = try await refreshFilesMetadata(
                drive: drive,
                relativePath: targetDirectory
            )
            let realm = try await Realm.open(configuration: ReaderContentLoader.historyRealmConfiguration)
            let importedFileURL = try targetFilePath.fileURL(forRoot: drive.rootDirectory)
            guard let importedReaderFileURL = try await readerFileURL(for: importedFileURL, drive: drive) else {
                debugPrint("Warning: Unable to resolve reader file URL for imported file", importedFileURL)
                return nil
            }
            guard let content = realm.objects(ContentFile.self)
                .filter(NSPredicate(format: "isDeleted == %@ AND url == %@", NSNumber(booleanLiteral: false), importedReaderFileURL.absoluteString as CVarArg))
                .first else {
                debugPrint("Warning: No matching content metadata returned for imported file", importedReaderFileURL)
                return nil
            }
            Task { @MainActor [weak self] in
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
                    let realm = try await Realm.open(configuration: ReaderContentLoader.historyRealmConfiguration)
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
        var files = [ThreadSafeReference<ContentFile>]()
        var filesToUpdate: [(readerFileURL: URL, absoluteFileURL: URL)] = []
        do {
            for url in try await drive.contentsOfDirectory(
                at: relativePath ?? .root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .producesRelativePathURLs]
            ) {
                try Task.checkCancellation()
                var tryRelativePath = RootRelativePath(path: url.relativePath)
                if let relativePath, !relativePath.path.isEmpty {
                    tryRelativePath.path = relativePath.path + "/" + tryRelativePath.path
                }
                if Self.shouldSkipDiscoveredRelativePath(tryRelativePath.path) {
                    Self.logContentFileDecision(
                        stage: "discovery.skipInternalRoot",
                        path: tryRelativePath.path,
                        reason: "managedRoot"
                    )
                    continue
                }
                let lastPathComponent = url.lastPathComponent.lowercased()
                let absoluteFileURL = try tryRelativePath.fileURL(forRoot: drive.rootDirectory)
                let isDirectory: Bool
                do {
                    isDirectory = try await Self.isDiscoveredDirectory(
                        url,
                        absoluteFileURL: absoluteFileURL,
                        drive: drive,
                        relativePath: tryRelativePath
                    )
                } catch {
                    if Self.isMissingFileError(error) {
                        Self.logContentFileDecision(
                            stage: "discovery.skipMissing",
                            path: tryRelativePath.path,
                            reason: "disappearedDuringRefresh"
                        )
                        continue
                    }
                    throw error
                }
                if !url.isFilePackage(),
                   !Self.additionalFilePackageSuffixesToAvoidDescendingInto.contains(where: { lastPathComponent.hasSuffix($0) }),
                   isDirectory {
                    let discoveredFiles = try await refreshFilesMetadata(drive: drive, relativePath: tryRelativePath)
                    files.append(contentsOf: discoveredFiles ?? [])
                } else {
                    let indexDecision = Self.contentFileIndexDecision(at: absoluteFileURL)
                    switch indexDecision {
                    case .skipArtifact:
                        Self.logContentFileDecision(
                            stage: "discovery.skipArtifact",
                            path: tryRelativePath.path,
                            reason: "managedArtifact"
                        )
                        continue
                    case .skipUnsupported(let mimeType):
                        Self.logContentFileDecision(
                            stage: "discovery.skipUnsupported",
                            path: tryRelativePath.path,
                            pathExtension: absoluteFileURL.lakePathExtension,
                            mimeType: mimeType,
                            reason: "unsupportedType"
                        )
                        continue
                    case .index(let reason, let mimeType):
                        Self.logContentFileDecision(
                            stage: "discovery.index",
                            path: tryRelativePath.path,
                            pathExtension: absoluteFileURL.lakePathExtension,
                            mimeType: mimeType,
                            reason: reason
                        )
                    }
                    if let readerFileURL = try await readerFileURL(for: absoluteFileURL, drive: drive) {
                        filesToUpdate.append((readerFileURL, absoluteFileURL))
                    }
                }
            }
        } catch {
            if Self.isMissingFileError(error) {
                Self.logContentFileDecision(
                    stage: "discovery.skipMissingDirectory",
                    path: relativePath?.path ?? "",
                    reason: "disappearedDuringRefresh"
                )
                return files
            }
            if !(error is CancellationError) {
                debugPrint("refreshFilesMetadata error:", error)
            }
            throw error
        }

        if !filesToUpdate.isEmpty {
            let pendingFilesToUpdate = filesToUpdate
            let updatedFiles = try await { @RealmBackgroundActor in
                var updatedFiles = [ContentFile]()
                var allFileRefs = [ThreadSafeReference<ContentFile>]()
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.historyRealmConfiguration)

                try await realm.asyncWrite {
                    for (readerFileURL, absoluteFileURL) in pendingFilesToUpdate {
                        try Task.checkCancellation()

                        if let existing = realm.objects(ContentFile.self).filter(NSPredicate(format: "url == %@", readerFileURL.absoluteString as CVarArg)).first {
                            try Task.checkCancellation()
                            if try setMetadata(readerFileURL: readerFileURL, absoluteFileURL: absoluteFileURL, contentFile: existing) {
                                updatedFiles.append(existing)
                            }
                            allFileRefs.append(ThreadSafeReference(to: existing))
                        } else {
                            let contentFile = ContentFile()
                            contentFile.url = readerFileURL
                            try Task.checkCancellation()
                            if try setMetadata(readerFileURL: readerFileURL, absoluteFileURL: absoluteFileURL, contentFile: contentFile) {
                                contentFile.updateCompoundKey()
                                contentFile.isReaderModeByDefault = ReaderContentLoader.supportsReaderContent(
                                    mimeType: contentFile.mimeType,
                                    pathExtension: readerFileURL.lakePathExtension
                                )
                                realm.add(contentFile, update: .modified)
                                updatedFiles.append(contentFile)
                            }
                            allFileRefs.append(ThreadSafeReference(to: contentFile))
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
    }

    private static func isDiscoveredDirectory(
        _ url: URL,
        absoluteFileURL: URL,
        drive: CloudDrive,
        relativePath: RootRelativePath
    ) async throws -> Bool {
        if let isDirectory = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory {
            return isDirectory == true
        }
        if let isDirectory = try? absoluteFileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory {
            return isDirectory == true
        }
        return try await drive.directoryExists(at: relativePath)
    }
    
    /// Note that ReaderContentMetadataSynchronizer keeps associated records in sync
    @RealmBackgroundActor
    private func setMetadata(readerFileURL fileURL: URL, absoluteFileURL: URL, contentFile: ContentFile) throws -> Bool {
        try Task.checkCancellation()
        var metadataUpdated = false
        let fileModifiedAt = Self.fileModificationDate(absoluteFileURL: absoluteFileURL)
        
        if contentFile.isDeleted {
            contentFile.isDeleted = false
            metadataUpdated = true
        }

        let payloadAvailableLocally = try isPayloadReadableLocallyForMetadata(readerBackingURL: fileURL)
        try Task.checkCancellation()
        
        if metadataUpdated || contentFile.fileMetadataRefreshedAt ?? .distantPast <= fileModifiedAt ?? .distantPast {
            if contentFile.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                contentFile.title = fileURL.deletingPathExtension().lastPathComponent
            }
            let pathExtension = fileURL.lakePathExtension
            let typeIdentifier = UTType(filenameExtension: pathExtension)?.identifier
            contentFile.mimeType = ReaderContentLoader.canonicalMimeType(
                mimeType: UTType(filenameExtension: pathExtension)?.preferredMIMEType,
                typeIdentifier: typeIdentifier,
                pathExtension: pathExtension
            )
            
            if payloadAvailableLocally {
                if !contentFile.isPhysicalMedia, contentFile.publicationDate != fileModifiedAt ?? Date() {
                    contentFile.publicationDate = fileModifiedAt ?? Date()
                    metadataUpdated = true
                }

                if pathExtension.lowercased() == "zip",
                   let archive = try? Archive(url: absoluteFileURL, accessMode: .read) {
                    let filePaths = RealmSwift.MutableSet<String>()
                    filePaths.insert(objectsIn: archive.map { $0.path })
                    contentFile.packageFilePaths = filePaths
                }
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

    @MainActor
    private func removeDeletedFileFromPublishedFiles(matching readerBackingURL: URL) {
        guard let canonicalDeletedURL = canonicalReaderBackingURL(for: readerBackingURL),
              let files else {
            return
        }
        let remainingFiles = files.filter { contentFile in
            guard let fileBackingURL = canonicalReaderBackingURL(for: contentFile.url) else {
                return true
            }
            return fileBackingURL != canonicalDeletedURL
        }
        guard remainingFiles.count != files.count else {
            return
        }
        self.files = remainingFiles
    }

    @RealmBackgroundActor
    private func markDeleted(contentURL: URL) async throws {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.historyRealmConfiguration)
        let canonicalContentURL = canonicalReaderBackingURL(for: contentURL)
        let contentFiles = Array(
            realm.objects(ContentFile.self)
                .where { !$0.isDeleted }
                .filter { contentFile in
                    if contentFile.url == contentURL {
                        return true
                    }
                    guard let canonicalContentURL,
                          let fileBackingURL = self.canonicalReaderBackingURL(for: contentFile.url) else {
                        return false
                    }
                    return fileBackingURL == canonicalContentURL
                }
        )
        try await realm.asyncWrite {
            for existing in contentFiles {
                existing.isDeleted = true
                existing.refreshChangeMetadata(explicitlyModified: true)
                let packageContentFiles = realm.objects(ContentPackageFile.self)
                    .where { $0.packageContentFileID == existing.compoundKey && !$0.isDeleted }
                for packageContentFile in packageContentFiles {
                    packageContentFile.isDeleted = true
                    packageContentFile.refreshChangeMetadata(explicitlyModified: true)
                }
            }
        }
    }
    
    private static func extractRelativePath(fileURL: URL) throws -> RootRelativePath {
        let relativePathComponents = Array(fileURL.pathComponents.dropFirst(3))
        guard !relativePathComponents.isEmpty,
              relativePathComponents.allSatisfy({ component in
                  !component.isEmpty
                      && component != "."
                      && component != ".."
                      && !component.contains("/")
                      && !component.contains("\\")
              }) else {
            throw ReaderFileManagerError.invalidFileURL
        }
        let relativePath = RootRelativePath(path: relativePathComponents.joined(separator: "/"))
        return relativePath
    }

    private func readerBackingPathContext(for readerBackingURL: URL) throws -> ReaderBackingPathContext {
        guard let canonicalURL = canonicalReaderBackingURL(for: readerBackingURL) else {
            throw ReaderFileManagerError.invalidFileURL
        }
        let relativePath = try Self.extractRelativePath(fileURL: canonicalURL)
        guard let driveLocation = canonicalURL.pathComponents.dropFirst(2).first,
              let storageLocation = ReaderBackingStorageLocation(rawValue: driveLocation) else {
            throw ReaderFileManagerError.invalidFileURL
        }

        let localStorageRootURL = localDrive?.rootDirectory ?? defaultLocalRootURLProvider()
        let localRootURL = try relativePath.fileURL(forRoot: localStorageRootURL)
        let cloudRootURL = try cloudDrive.map { try relativePath.fileURL(forRoot: $0.rootDirectory) }
        let activeRootURL: URL?
        switch storageLocation {
        case .local:
            activeRootURL = localRootURL
        case .icloud:
            activeRootURL = cloudRootURL
        }

        return ReaderBackingPathContext(
            relativePath: relativePath,
            storageLocation: storageLocation,
            canonicalURL: canonicalURL,
            localRootURL: localRootURL,
            cloudRootURL: cloudRootURL,
            activeRootURL: activeRootURL,
            localRootExists: Self.fileSystemEntryExists(at: localRootURL),
            cloudRootExists: cloudRootURL.map(Self.fileSystemEntryExists(at:)) ?? false
        )
    }

    private func evaluateAvailability(
        forReaderBackingURL readerBackingURL: URL,
        requestDownloadIfNeeded: Bool
    ) async throws -> ReaderBackingAvailability {
        let context = try readerBackingPathContext(for: readerBackingURL)

        switch context.storageLocation {
        case .local:
            if context.localRootExists {
                return ReaderBackingAvailability(status: .localOnly, localURL: context.localRootURL, requestedDownload: false)
            }
            return ReaderBackingAvailability(status: .fileMissing, localURL: nil, requestedDownload: false)
        case .icloud:
            guard cloudDrive != nil else {
                return ReaderBackingAvailability(status: .loadingStatus, localURL: nil, requestedDownload: false)
            }
            if !context.cloudRootExists {
                if context.localRootExists {
                    return ReaderBackingAvailability(status: .localOnly, localURL: context.localRootURL, requestedDownload: false)
                }
                return ReaderBackingAvailability(status: .fileMissing, localURL: nil, requestedDownload: false)
            }
        }

        guard let activeRootURL = context.activeRootURL else {
            return ReaderBackingAvailability(status: .loadingStatus, localURL: nil, requestedDownload: false)
        }

        let requiredPayloadURLs = try Self.requiredPayloadURLs(at: activeRootURL)
        let payloadURLs = requiredPayloadURLs.isEmpty ? [activeRootURL] : requiredPayloadURLs
        var hasUploadingPayload = false
        var hasDownloadingPayload = false
        var missingPayloadURLs = [URL]()

        for payloadURL in payloadURLs {
            try Task.checkCancellation()
            switch try Self.payloadState(at: payloadURL) {
            case .current:
                continue
            case .downloading:
                hasDownloadingPayload = true
            case .uploading:
                hasUploadingPayload = true
            case .notLocal:
                missingPayloadURLs.append(payloadURL)
            }
        }

        if hasUploadingPayload {
            return ReaderBackingAvailability(status: .uploading, localURL: activeRootURL, requestedDownload: false)
        }
        if hasDownloadingPayload {
            return ReaderBackingAvailability(status: .downloading, localURL: activeRootURL, requestedDownload: false)
        }

        var requestedDownload = false
        if requestDownloadIfNeeded, !missingPayloadURLs.isEmpty {
            for payloadURL in missingPayloadURLs {
                do {
                    try FileManager.default.startDownloadingUbiquitousItem(at: payloadURL)
                    requestedDownload = true
                } catch {
                    continue
                }
            }
        }

        if requestedDownload {
            Self.postReaderBackingStatusRefresh(for: context.canonicalURL)
            return ReaderBackingAvailability(status: .downloading, localURL: activeRootURL, requestedDownload: true)
        }

        if !missingPayloadURLs.isEmpty {
            return ReaderBackingAvailability(status: .cloudOnly, localURL: activeRootURL, requestedDownload: false)
        }

        guard try await Self.canCoordinateRead(rootURL: activeRootURL) else {
            return ReaderBackingAvailability(status: .cloudOnly, localURL: activeRootURL, requestedDownload: false)
        }

        return ReaderBackingAvailability(status: .availableLocally, localURL: activeRootURL, requestedDownload: false)
    }

    private enum PayloadState: Equatable {
        case current
        case downloading
        case uploading
        case notLocal
    }

    private static func payloadState(at url: URL) throws -> PayloadState {
        try Task.checkCancellation()
        guard fileSystemEntryExists(at: url) else {
            return .notLocal
        }
        try Task.checkCancellation()
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemIsUploadingKey,
            .ubiquitousItemDownloadingStatusKey,
        ])
        if values?.isUbiquitousItem == true {
            if values?.ubiquitousItemIsUploading == true {
                return .uploading
            }
            if values?.ubiquitousItemIsDownloading == true {
                return .downloading
            }
            if values?.ubiquitousItemDownloadingStatus == .current {
                return .current
            }
            return .notLocal
        }
        return .current
    }

    private static func requiredPayloadURLs(at rootURL: URL) throws -> [URL] {
        try Task.checkCancellation()
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else {
            return [rootURL]
        }
        var payloadURLs = [URL]()
        if let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                try Task.checkCancellation()
                if (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    payloadURLs.append(fileURL)
                }
            }
        }
        return payloadURLs
    }

    private static func canCoordinateRead(rootURL: URL) async throws -> Bool {
        let coordinatedFileManager = CoordinatedFileManager()
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            return false
        }
        if isDirectory.boolValue {
            _ = try await coordinatedFileManager.contentsOfDirectory(
                coordinatingAccessAt: rootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            return true
        }
        _ = try await coordinatedFileManager.contentsOfFile(coordinatingAccessAt: rootURL)
        return true
    }

    private func isPayloadReadableLocallyForMetadata(readerBackingURL: URL) throws -> Bool {
        guard let canonicalURL = canonicalReaderBackingURL(for: readerBackingURL),
              let context = try? readerBackingPathContext(for: canonicalURL),
              let activeRootURL = context.activeRootURL else {
            return false
        }

        switch context.storageLocation {
        case .local:
            return context.localRootExists
        case .icloud:
            guard context.cloudRootExists else {
                return false
            }
            let requiredPayloadURLs = try Self.requiredPayloadURLs(at: activeRootURL)
            let payloadURLs = requiredPayloadURLs.isEmpty ? [activeRootURL] : requiredPayloadURLs
            for payloadURL in payloadURLs {
                try Task.checkCancellation()
                guard try Self.payloadState(at: payloadURL) == .current else {
                    return false
                }
            }
            return true
        }
    }

    private static func fileSystemEntryExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private static func postReaderBackingStatusRefresh(for readerBackingURL: URL) {
        NotificationCenter.default.post(
            name: readerBackingStatusRefreshRequestedNotification,
            object: readerBackingURL.absoluteString
        )
    }
    
    private static func fileModificationDate(absoluteFileURL: URL) -> Date? {
        do {
            let attr = try FileManager.default.attributesOfItem(atPath: absoluteFileURL.path)
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

    private static func contentFileIndexDecision(at absoluteFileURL: URL) -> ContentFileIndexDecision {
        if shouldSkipDiscoveredFile(at: absoluteFileURL) {
            return .skipArtifact
        }

        let pathExtension = absoluteFileURL.lakePathExtension.lowercased()
        let mimeType = UTType(filenameExtension: pathExtension)?.preferredMIMEType

        if ReaderContentLoader.supportsReaderContent(mimeType: mimeType, pathExtension: pathExtension) {
            return .index(reason: "readerContent", mimeType: mimeType)
        }

        guard let fileType = UTType(filenameExtension: pathExtension) else {
            return .skipUnsupported(mimeType: mimeType)
        }

        if ReaderFileManager.shared.readerContentMimeTypes.contains(where: { fileType.conforms(to: $0) }) {
            return .index(reason: "libraryType", mimeType: mimeType)
        }

        return .skipUnsupported(mimeType: mimeType)
    }

    private static func shouldSkipDiscoveredFile(at absoluteFileURL: URL) -> Bool {
        let lastPathComponent = absoluteFileURL.lastPathComponent.lowercased()
        if lastPathComponent.hasSuffix(".realm")
            || lastPathComponent.hasSuffix(".realm.lock")
            || lastPathComponent.hasSuffix(".realm.management")
            || lastPathComponent.hasSuffix(".realm.note")
            || lastPathComponent == "manabireaderlogs.zip" {
            return true
        }
        return false
    }

    static func shouldSkipDiscoveredRelativePath(_ path: String) -> Bool {
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let rootComponent = normalizedPath.split(separator: "/", maxSplits: 1).first.map(String.init),
              !rootComponent.isEmpty else {
            return false
        }
        return internalStorageRootPrefixes.contains(rootComponent)
            || transientRootPrefixes.contains(where: { rootComponent.hasPrefix($0) })
    }

    private static func isMissingFileError(_ error: any Swift.Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOENT {
            return true
        }
        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlyingError.domain == NSPOSIXErrorDomain,
           underlyingError.code == ENOENT {
            return true
        }
        return false
    }

    public static func isInternalStorageReaderFileURL(_ fileURL: URL) -> Bool {
        guard let relativePath = try? extractRelativePath(fileURL: fileURL) else {
            return false
        }
        return shouldSkipDiscoveredRelativePath(relativePath.path)
    }

    private static func logContentFileDecision(
        stage: String,
        path: String,
        pathExtension: String? = nil,
        mimeType: String? = nil,
        reason: String? = nil
    ) {
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
        Task { @MainActor [weak self] in
            try await self?.refreshAllFilesMetadata()
        }
    }
}

private extension ReaderFileManager {
    @MainActor
    static func rootRelativePath(forImportedURL url: URL, drive: CloudDrive) async throws -> RootRelativePath {
        switch url.lakePathExtension.lowercased() {
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
