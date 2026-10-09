import Foundation
import CryptoKit
import SwiftUI
import Combine
import LakeOfFireCore
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
    case incompleteMetadataScan
}

//public extension RootRelativePath {
//    static let documents = Self(path: "Documents")
//}

@MainActor
public class CloudDriveSyncStatusModel: ObservableObject {
    public let objectWillChange = ObservableObjectPublisher()
    
    @Published public var status: CloudDriveSyncStatus = .loadingStatus
    private var refreshTask: Task<Void, Never>? = nil
    private var refreshID: UUID?

    typealias StatusLoader = @MainActor (ContentFile) async throws -> CloudDriveSyncStatus
    private let statusLoader: StatusLoader
    private let pollingDelay: @Sendable () async throws -> Void

    public init() {
        statusLoader = { try await $0.cloudDriveSyncStatus() }
        pollingDelay = { try await Task.sleep(nanoseconds: 2_000_000_000) }
    }

    init(statusLoader: @escaping StatusLoader,
         pollingDelay: @escaping @Sendable () async throws -> Void = {
             try await Task.sleep(nanoseconds: 2_000_000_000)
         }) {
        self.statusLoader = statusLoader
        self.pollingDelay = pollingDelay
    }

    @MainActor
    public func refreshAsync(item: ContentFile) async {
        // A caller cancelled before admission does not own the current producer.
        guard !Task.isCancelled else { return }
        refreshTask?.cancel()
        let identifier = UUID()
        refreshID = identifier
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await periodicStatusRefresh(item: item, identifier: identifier)
        }
        refreshTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            // Capture this invocation's producer, never a subsequently assigned handle.
            task.cancel()
        }
        if refreshID == identifier {
            refreshTask = nil
            refreshID = nil
        }
    }

    private func periodicStatusRefresh(item: ContentFile, identifier: UUID) async {
        while !Task.isCancelled, refreshID == identifier {
            do {
                let newStatus = try await statusLoader(item)
                try Task.checkCancellation()
                guard refreshID == identifier else { return }
                status = newStatus
                guard newStatus == .downloading || newStatus == .uploading else { return }
                try await pollingDelay()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, refreshID == identifier else { return }
                print(error)
                return
            }
        }
    }
    
    deinit {
        refreshTask?.cancel() // Ensure task is cancelled if the model is deinitialized
    }
}

public enum CloudDriveSyncStatus: Sendable {
    case fileMissing
    case localOnly
    case cloudOnly
    case downloading
    case uploading
    case availableLocally
    case loadingStatus
}

public class ReaderFileManager: ObservableObject {
    public let objectWillChange = ObservableObjectPublisher()
    
    public static let readerBackingStatusRefreshRequestedNotification = Notification.Name("ReaderFileManager.readerBackingStatusRefreshRequested")
    public static let driveAvailabilityDidChangeNotification = Notification.Name("ReaderFileManager.driveAvailabilityDidChange")

    private enum ReaderBackingStorageLocation: String {
        case local
        case icloud
    }

    private struct ReaderBackingPathContext {
        let readerBackingURL: URL
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

    /// A queued producer retains the installed tuple which admitted it. The
    /// synchronous predicate is also checked inside each owned Realm write.
    private struct MetadataRefreshSelection {
        let localDrive: CloudDrive?
        let cloudDrive: CloudDrive?
        let initializationIdentifier: UUID?
        let realmConfiguration: Realm.Configuration

        var queueScope: String {
            let realm = realmConfiguration.inMemoryIdentifier.map { "memory:\($0)" }
                ?? "file:\(realmConfiguration.fileURL?.standardizedFileURL.absoluteString ?? "")"
            return "\(realm)|\(localDrive.map { String(describing: ObjectIdentifier($0)) } ?? "nil")"
                + "|\(cloudDrive.map { String(describing: ObjectIdentifier($0)) } ?? "nil")"
                + "|\(initializationIdentifier?.uuidString ?? "nil")"
        }
    }

    private struct MetadataRefreshKey: Hashable {
        let driveIdentifier: ObjectIdentifier
        let selectionScope: String
        let driveRootPath: String
        let driveContainerIdentifier: String?
        let relativePath: String
        let realmFileURL: String?
        let realmInMemoryIdentifier: String?
    }

    private struct MetadataScanResult: Sendable {
        var contentFileIDs: [String] = []
        var isComplete = true
    }

    private struct InventoryCandidate: Sendable {
        let id: String
        let url: URL
        let modifiedAt: Date
    }

    private struct MetadataRefreshEntry {
        let id: UUID
        let task: Task<MetadataScanResult, any Swift.Error>
    }

    private enum ContentFileIndexDecision {
        case skipArtifact
        case skipUnsupported(mimeType: String?)
        case index(reason: String, mimeType: String?)
    }

    // TODO: Migrate to a 'plugin registry' architecture instead of all these callbacks
    public static var fileDestinationProcessors = [(URL) async throws -> RootRelativePath?]()
    public static var readerFileURLProcessors = [@RealmBackgroundActor (URL, String) async throws -> URL?]()
    public static var fileProcessors = [@RealmBackgroundActor ([ContentFile]) async throws -> Void]()
    /// Specialized processors return IDs whose enrichment must be retried. A
    /// generic metadata scan is not proof that an unavailable payload was parsed.
    public static var fileEnrichmentProcessors = [String: @RealmBackgroundActor ([ContentFile]) async throws -> Set<String>]()
    
    public static var shared = ReaderFileManager()

    /// Keeps a manager's asynchronous indexing work in the same content Realm when a
    /// caller supplies an isolated configuration. Production managers continue to use
    /// `ReaderContentLoader.historyRealmConfiguration` at the start of each operation.
    var historyRealmConfigurationOverride: Realm.Configuration?
    
    // TODO: Pull these from callbacks per above
    public var readerContentMimeTypes: [UTType] = [.plainText, .html, UTType(filenameExtension: "md") ?? UTType(importedAs: "net.daringfireball.markdown"), .zip]
    
    @MainActor @Published public var files: [ContentFile]?
    
    @MainActor public var readerContentFiles: [ContentFile]? {
        return files?.filter {
            ReaderContentLoader.supportsReaderContent(mimeType: $0.mimeType, pathExtension: $0.url.lakePathExtension)
            && !$0.isDeleted
            && !$0.url.isEBookURL
        }
    }
    
    private var hasInitializedUbiquityContainerIdentifier = false
    // Like the installed drives/configuration, this selection identity must
    // be visible to synchronous owned-write admission on RealmBackgroundActor.
    private var initializationID: UUID?
    
    /*@MainActor*/ public var cloudDrive: CloudDrive?
    //    /*@MainActor*/ @Published public var legacyCloudDrive: CloudDrive?
    /*@MainActor*/ public var localDrive: CloudDrive?
    
    public var ubiquityContainerIdentifier: String? = nil {
        didSet {
            if hasInitializedUbiquityContainerIdentifier, oldValue != ubiquityContainerIdentifier {
                Task { [weak self] in
                    try await self?.refreshAllFilesMetadata()
                }
            }
        }
    }
    
    @MainActor var inventoryRefreshQueue: ReaderFileRefreshQueue?
    @ReaderFileManagerActor
    private var metadataRefreshEntries = [MetadataRefreshKey: MetadataRefreshEntry]()

    @MainActor
    private func resolvedInventoryRefreshQueue() -> ReaderFileRefreshQueue {
        if let inventoryRefreshQueue { return inventoryRefreshQueue }
        let queue = ReaderFileRefreshQueue()
        inventoryRefreshQueue = queue
        return queue
    }

    private static let internalStorageRootPrefixes: Set<String> = [
        "manabi-caches",
        "manabi-dictionaries",
        "manabi-dictionary-assets",
        "manabi-fonts",
    ]
    private static let transientRootPrefixes: Set<String> = [
        "ReaderFileDeletion.",
    ]
    
    typealias CloudDriveFactory = @MainActor @Sendable (String) async throws -> CloudDrive
    typealias LocalDriveFactory = @MainActor @Sendable () async throws -> CloudDrive

    private let payloadStateProvider: @Sendable (URL) throws -> PayloadState
    private let directoryContentsProvider: (@Sendable (URL) async throws -> [URL])?
    // Instance-scoped scheduling observation for deterministic coalescing tests.
    // It neither supplies scan results nor changes captured-selection validation.
    private let metadataRefreshDidCoalesce: (@Sendable () -> Void)?
    private let cloudDriveFactory: CloudDriveFactory
    private let localDriveFactory: LocalDriveFactory

    public init() {
        payloadStateProvider = { try Self.payloadState(at: $0) }
        directoryContentsProvider = nil
        metadataRefreshDidCoalesce = nil
        cloudDriveFactory = { identifier in
            try await CloudDrive(
                ubiquityContainerIdentifier: identifier,
                relativePathToRootInContainer: "Documents"
            )
        }
        localDriveFactory = {
            try await CloudDrive(
                storage: .localDirectory(
                    rootURL: Self.getDocumentsDirectory()
                )
            )
        }
    }

    // Inject filesystem observations and drive construction for isolated
    // boundary tests. Production identity and mutation decisions remain here.
    init(
        payloadStateProvider: @escaping @Sendable (URL) throws -> PayloadState,
        directoryContentsProvider: (@Sendable (URL) async throws -> [URL])? = nil,
        metadataRefreshDidCoalesce: (@Sendable () -> Void)? = nil,
        cloudDriveFactory: @escaping CloudDriveFactory = { identifier in
            try await CloudDrive(
                ubiquityContainerIdentifier: identifier,
                relativePathToRootInContainer: "Documents"
            )
        },
        localDriveFactory: @escaping LocalDriveFactory = {
            try await CloudDrive(
                storage: .localDirectory(
                    rootURL: ReaderFileManager.getDocumentsDirectory()
                )
            )
        }
    ) {
        self.payloadStateProvider = payloadStateProvider
        self.directoryContentsProvider = directoryContentsProvider
        self.metadataRefreshDidCoalesce = metadataRefreshDidCoalesce
        self.cloudDriveFactory = cloudDriveFactory
        self.localDriveFactory = localDriveFactory
    }

    private var resolvedHistoryRealmConfiguration: Realm.Configuration {
        historyRealmConfigurationOverride ?? ReaderContentLoader.historyRealmConfiguration
    }
    
    @MainActor
    public func initialize(ubiquityContainerIdentifier: String) async throws {
        // A cancelled entrant cannot revoke a healthy initialization or invoke
        // a factory whose preparation may itself create directories/presenters.
        try Task.checkCancellation()
        let identifier = UUID()
        initializationID = identifier
        // Prepare replacement drives without mutating the currently usable
        // manager. A SwiftUI .task(id:) cancellation must not commit a partial
        // identity or launch detached indexing work.
        let nextCloudDrive: CloudDrive?
        do {
            nextCloudDrive = try await cloudDriveFactory(
                ubiquityContainerIdentifier
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // iCloud is optional; the local library remains usable when the
            // account/container is unavailable.
            nextCloudDrive = nil
        }

        try validateInitialization(identifier)
        let nextLocalDrive = try await localDriveFactory()
        try validateInitialization(identifier)

        nextCloudDrive?.observer = self
        nextLocalDrive.observer = self

        // Suppress the identifier observer while committing the prepared
        // drive tuple. The structured refresh below is the single initial scan.
        hasInitializedUbiquityContainerIdentifier = false
        self.ubiquityContainerIdentifier = ubiquityContainerIdentifier
        cloudDrive = nextCloudDrive
        localDrive = nextLocalDrive
        hasInitializedUbiquityContainerIdentifier = true

        NotificationCenter.default.post(
            name: Self.driveAvailabilityDidChangeNotification,
            object: self
        )
        try validateInitialization(identifier)
        try await refreshAllFilesMetadata()
        try validateInitialization(identifier)
    }

    @MainActor
    private func validateInitialization(_ identifier: UUID) throws {
        try Task.checkCancellation()
        guard initializationID == identifier else { throw CancellationError() }
    }
    
    @MainActor
    public func appSuspendedDidChange(isSuspended: Bool) {
        let queue = resolvedInventoryRefreshQueue()
        if isSuspended {
            queue.suspend()
        } else {
            queue.resume()
            Task { @MainActor [weak self] in
                try? await self?.refreshAllFilesMetadata()
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
    
    public func canonicalReaderBackingURL(for contentURL: URL) -> URL? {
        guard var components = URLComponents(url: contentURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.query = nil
        components.fragment = nil
        guard let strippedURL = components.url else {
            return nil
        }

        // Mokuro is retained as a legacy URL mapping. It is not part of the
        // ebook request authorization path and keeps its historical conversion
        // behavior while that feature remains disabled.
        if strippedURL.scheme == "mokuro", strippedURL.host == "mokuro" {
            let absoluteString = strippedURL.absoluteString
            guard absoluteString.hasPrefix("mokuro://mokuro/load/") else { return nil }
            return URL(string: absoluteString.replacingOccurrences(of: "mokuro://mokuro/load/", with: "reader-file://file/load/"))
        }

        guard Self.isValidReaderBackingPath(components: components) else {
            return nil
        }
        if strippedURL.isReaderFileURL {
            return strippedURL
        }
        if strippedURL.scheme == "ebook", strippedURL.host == "ebook" {
            components.scheme = "reader-file"
            components.host = "file"
            return components.url
        }
        return nil
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

    @MainActor
    public func resolveReadableLocalURL(forReaderBackingURL readerBackingURL: URL) async throws -> URL {
        let availability = try await evaluateAvailability(
            forReaderBackingURL: readerBackingURL,
            requestDownloadIfNeeded: true
        )
        switch availability.status {
        case .localOnly, .availableLocally, .uploading:
            guard let localURL = availability.localURL else {
                throw ReaderFileAccessError.notAvailableOffline
            }
            return localURL
        case .downloading:
            throw ReaderFileAccessError.downloadInProgress
        case .cloudOnly, .fileMissing, .loadingStatus:
            throw ReaderFileAccessError.notAvailableOffline
        }
    }
    
    typealias DeleteStatusLoader = @MainActor (URL) async throws -> CloudDriveSyncStatus

    @RealmBackgroundActor
    public func delete(readerFileURL contentURL: URL) async throws {
        try await delete(readerFileURL: contentURL, statusLoader: { [self] url in
            try await cloudDriveSyncStatus(forReaderBackingURL: url)
        })
    }

    /// The public command and native boundary tests share the same executor.
    /// Tests can supply availability and observe final synchronous admission;
    /// neither seam replaces native coordination or the production selection check.
    @RealmBackgroundActor
    func delete(readerFileURL contentURL: URL, statusLoader: DeleteStatusLoader,
                beforeRemovalAdmission: (() throws -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        // Capture before the first availability/actor handoff. Keeping only
        // the drive permits a replaced Realm or a newer failed initialization
        // to authorize physical removal before the later index phase rejects.
        let selection = MetadataRefreshSelection(
            localDrive: localDrive, cloudDrive: cloudDrive,
            initializationIdentifier: initializationID,
            realmConfiguration: resolvedHistoryRealmConfiguration
        )
        guard let readerBackingURL = canonicalReaderBackingURL(for: contentURL) else {
            throw ReaderFileDeleteError.removeFailed()
        }
        let pathContext = try readerBackingPathContext(for: readerBackingURL)
        let drive = pathContext.storageLocation == .local
            ? selection.localDrive : selection.cloudDrive
        try validateDeletionSelection(pathContext, drive: drive, selection: selection)
        let status: CloudDriveSyncStatus
        do {
            status = try await statusLoader(readerBackingURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ReaderFileDeleteError.blockedLoadingStatus
        }
        try validateDeletionSelection(pathContext, drive: drive, selection: selection)
        switch status {
        case .cloudOnly: throw ReaderFileDeleteError.blockedCloudOnly
        case .loadingStatus: throw ReaderFileDeleteError.blockedLoadingStatus
        default: break
        }

        if status != .fileMissing {
            // Resolve once, before availability can suspend. A replacement
            // drive may contain an unrelated file with the same logical URL.
            guard let drive else { throw ReaderFileManagerError.driveMissing }
            do {
                let isDirectory = try await drive.directoryExists(at: pathContext.relativePath)
                try validateDeletionSelection(pathContext, drive: drive, selection: selection)
                // Native coordination can wait after the earlier inspection.
                // Keep the final check and removal synchronous on this caller,
                // rather than sending live selection state to another actor.
                try drive.removeItemSynchronously(
                    at: pathContext.relativePath, isDirectory: isDirectory
                ) {
                    try beforeRemovalAdmission?()
                    try validateDeletionSelection(pathContext, drive: drive, selection: selection)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ReaderFileDeleteError {
                throw error
            } catch {
                throw ReaderFileDeleteError.removeFailed(underlyingDescription: error.localizedDescription)
            }
        }

        // The physical removal, if any, is already committed. This next phase
        // can fail independently; it must never mutate a replacement's index.
        try await markDeleted(contentURL: contentURL, pathContext: pathContext,
                              drive: drive, selection: selection)
        await removeDeletedFileFromPublishedFiles(matching: readerBackingURL,
            pathContext: pathContext, drive: drive, selection: selection)
        Task { @MainActor [weak self] in
            guard let self,
                  self.deletionSelectionIsCurrent(pathContext, drive: drive, selection: selection) else { return }
            // Optional refresh cannot acquire a new selection or change an
            // already-committed deletion into a reported failure.
            do {
                try await self.refreshAllFilesMetadata(force: true, selection: selection)
            } catch is CancellationError {
                // A superseded optional publication has no effects to retry.
            } catch {
                Logger.shared.logger.error("File inventory refresh after deletion failed: \(error)")
            }
        }
    }

    private func deletionDriveIsCurrent(_ context: ReaderBackingPathContext, drive: CloudDrive?) -> Bool {
        let current = context.storageLocation == .local ? localDrive : cloudDrive
        return current === drive
    }

    private func deletionSelectionIsCurrent(
        _ context: ReaderBackingPathContext, drive: CloudDrive?,
        selection: MetadataRefreshSelection
    ) -> Bool {
        // Only the selected drive participates in deletion. An unrelated
        // drive replacement does not revoke a current local/cloud command.
        deletionDriveIsCurrent(context, drive: drive)
            && initializationID == selection.initializationIdentifier
            && Self.sameHistoryRealm(resolvedHistoryRealmConfiguration, selection.realmConfiguration)
    }

    private func validateDeletionSelection(
        _ context: ReaderBackingPathContext, drive: CloudDrive?,
        selection: MetadataRefreshSelection
    ) throws {
        try Task.checkCancellation()
        guard deletionSelectionIsCurrent(context, drive: drive, selection: selection) else {
            throw ReaderFileDeleteError.removeFailed(
                underlyingDescription: "The selected storage changed. Retry from the current library."
            )
        }
    }

    private static func sameHistoryRealm(_ lhs: Realm.Configuration, _ rhs: Realm.Configuration) -> Bool {
        lhs.inMemoryIdentifier == rhs.inMemoryIdentifier
            && lhs.fileURL?.standardizedFileURL == rhs.fileURL?.standardizedFileURL
    }
    
    @MainActor
    public static func get(fileURL: URL) async throws -> ContentFile? {
        let realm = try await Realm.open(configuration: ReaderContentLoader.historyRealmConfiguration)
        //        try validate(readerFileURL: fileURL)
        let existing = realm.objects(ContentFile.self).filter(NSPredicate(format: "isDeleted == %@ AND url == %@", NSNumber(booleanLiteral: false), fileURL.absoluteString as CVarArg)).first
        return existing
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
            try Self.validateContainedPath(relativePath, within: localDrive.rootDirectory)
            return (localDrive, relativePath)
        case "icloud":
            guard let cloudDrive = cloudDrive else {
                throw ReaderFileManagerError.driveMissing
            }
            try Self.validateContainedPath(relativePath, within: cloudDrive.rootDirectory)
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
    
    @MainActor
    public func read(fileURL: URL) async throws -> Data? {
        try await read(fileURL: fileURL, resolveReadableURL: { [self] url in
            try await resolveReadableLocalURL(forReaderBackingURL: url)
        }, readLocalFile: { url in
            let coordinatedFileManager = CoordinatedFileManager()
            return try await coordinatedFileManager.contentsOfFile(coordinatingAccessAt: url)
        })
    }

    /// The normal path and native regression controls share storage admission.
    /// Collaborators provide only asynchronous availability and coordinated I/O.
    @MainActor
    func read(
        fileURL: URL,
        resolveReadableURL: @MainActor (URL) async throws -> URL,
        readLocalFile: @MainActor (URL) async throws -> Data?
    ) async throws -> Data? {
        try Task.checkCancellation()
        let readerBackingURL = canonicalReaderBackingURL(for: fileURL) ?? fileURL
        let context = try readerBackingPathContext(for: readerBackingURL)
        let (drive, relativePath) = try extractCloudDrivePath(fromReaderFileURL: readerBackingURL)
        let initializationIdentifier = initializationID
        let validateSelection = {
            try Task.checkCancellation()
            guard self.initializationID == initializationIdentifier,
                  self.deletionDriveIsCurrent(context, drive: drive) else {
                throw CancellationError()
            }
        }
        let readableURL = try await resolveReadableURL(readerBackingURL)
        try validateSelection()
        let data: Data?
        if readableURL.isFileURL, FileManager.default.fileExists(atPath: readableURL.path) {
            data = try await readLocalFile(readableURL)
        } else {
            // An old availability result cannot acquire a replacement drive.
            data = try await drive.readFile(at: relativePath)
        }
        try validateSelection()
        return data
    }
    
    @MainActor
    public func readerFileURL(for downloadable: Downloadable) async throws -> URL? {
        let fileURL = downloadable.localDestination
        let readerFileURL = try await readerFileURL(for: fileURL)
        return readerFileURL
    }

    @MainActor
    public func ensureImported(downloadable: Downloadable) async throws -> URL? {
        try await ensureImported(downloadable: downloadable, existsLocally: {
            await $0.existsLocally()
        })
    }

    @MainActor
    func ensureImported(
        downloadable: Downloadable,
        existsLocally: @MainActor (Downloadable) async -> Bool
    ) async throws -> URL? {
        let selection = try metadataRefreshSelection(realmConfiguration: resolvedHistoryRealmConfiguration)
        let exists = await existsLocally(downloadable)
        try validateMetadataRefreshSelection(selection)
        guard exists else { return nil }
        let existingReaderURL = try await readerFileURL(for: downloadable)
        try validateMetadataRefreshSelection(selection)
        if let existingReaderURL {
            try await refreshMetadataForExistingLibraryFile(downloadable.localDestination, selection: selection)
            try validateMetadataRefreshSelection(selection)
            return existingReaderURL
        }
        return try await importFile(fileURL: downloadable.localDestination,
            fromDownloadURL: downloadable.url, selection: selection)
    }

    @MainActor
    private func refreshMetadataForExistingLibraryFile(
        _ fileURL: URL,
        selection: MetadataRefreshSelection
    ) async throws {
        try validateMetadataRefreshSelection(selection)
        let drives = [selection.cloudDrive, selection.localDrive].compactMap { $0 }.filter { $0.isConnected }
        for drive in drives {
            guard let relativePathStr = Self.relativePath(for: fileURL, relativeTo: drive.rootDirectory) else {
                continue
            }
            let parentPath = URL(fileURLWithPath: relativePathStr).deletingLastPathComponent().relativePath
            let relativeParentPath = parentPath == "." ? "" : parentPath
            let metadataRefs = try await refreshFilesMetadata(drive: drive,
                relativePath: RootRelativePath(path: relativeParentPath), selection: selection)
            try validateMetadataRefreshSelection(selection)
            try await publishDiscoveredFiles(metadataRefs ?? [], selection: selection)
            try await refreshAllFilesMetadata(force: true, selection: selection)
            try validateMetadataRefreshSelection(selection)
            return
        }
    }

    @MainActor
    func publishDiscoveredFiles(
        _ discoveredFileRefs: [ThreadSafeReference<ContentFile>],
        realmConfiguration: Realm.Configuration = ReaderContentLoader.historyRealmConfiguration,
        openRealm: @MainActor (Realm.Configuration) async throws -> Realm = {
            try await Realm.open(configuration: $0)
        }
    ) async throws {
        let selection = try metadataRefreshSelection(realmConfiguration: realmConfiguration)
        try await publishDiscoveredFiles(discoveredFileRefs, selection: selection, openRealm: openRealm)
    }

    @MainActor
    private func publishDiscoveredFiles(
        _ discoveredFileRefs: [ThreadSafeReference<ContentFile>],
        selection: MetadataRefreshSelection,
        openRealm: @MainActor (Realm.Configuration) async throws -> Realm = {
            try await Realm.open(configuration: $0)
        }
    ) async throws {
        try validateMetadataRefreshSelection(selection)
        guard !discoveredFileRefs.isEmpty else { return }
        let realm = try await openRealm(selection.realmConfiguration)
        try validateMetadataRefreshSelection(selection)
        guard Self.sameHistoryRealm(realm.configuration, selection.realmConfiguration) else {
            throw CancellationError()
        }
        // Partial publication cannot carry invalidated or foreign-Realm rows
        // from an older list forward. This changes no persisted reading facts.
        var mergedFiles = (files ?? []).filter { file in
            guard !file.isInvalidated, let sourceRealm = file.realm else { return false }
            return Self.sameHistoryRealm(sourceRealm.configuration, selection.realmConfiguration)
                && !file.isDeleted
        }
        for discoveredFileRef in discoveredFileRefs {
            guard let discoveredFile = realm.resolve(discoveredFileRef),
                  !discoveredFile.isInvalidated, !discoveredFile.isDeleted else { continue }
            if let existingIndex = mergedFiles.firstIndex(where: { $0.url == discoveredFile.url }) {
                mergedFiles[existingIndex] = discoveredFile
            } else {
                mergedFiles.append(discoveredFile)
            }
        }
        try validateMetadataRefreshSelection(selection)
        files = mergedFiles
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
        let selection = try metadataRefreshSelection(realmConfiguration: resolvedHistoryRealmConfiguration)
        return try await importFile(fileURL: fileURL, fromDownloadURL: downloadURL, selection: selection)
    }

    @MainActor
    private func importFile(
        fileURL: URL,
        fromDownloadURL downloadURL: URL?,
        selection: MetadataRefreshSelection
    ) async throws -> URL? {
        try validateMetadataRefreshSelection(selection)
        guard let drive = ((selection.cloudDrive?.isConnected ?? false)
            ? selection.cloudDrive : nil) ?? selection.localDrive else { return nil }
        let realmConfiguration = selection.realmConfiguration
        let targetDirectory = try await Self.rootRelativePath(forImportedURL: downloadURL ?? fileURL, drive: drive)
        try validateMetadataRefreshSelection(selection)
        let shouldStopAccessingFile = fileURL.startAccessingSecurityScopedResource()
        defer {
            if shouldStopAccessingFile { fileURL.stopAccessingSecurityScopedResource() }
        }
        try await drive.createDirectory(at: targetDirectory)
        try validateMetadataRefreshSelection(selection)
        let targetFilePath = try await ReaderFileImportStorage.install(
            fileURL: fileURL, targetDirectory: targetDirectory, drive: drive)
        // Keep a completed copy in its original root when later work expires;
        // neither a stale result nor error authorizes removing copied bytes.
        do {
            try validateMetadataRefreshSelection(selection)
            _ = try await refreshFilesMetadata(drive: drive, relativePath: targetDirectory, selection: selection)
            try validateMetadataRefreshSelection(selection)
            let realm = try await Realm.open(configuration: realmConfiguration)
            try validateMetadataRefreshSelection(selection)
            let importedFileURL = try targetFilePath.fileURL(forRoot: drive.rootDirectory)
            let importedReaderFileURL = try await readerFileURL(for: importedFileURL, drive: drive)
            try validateMetadataRefreshSelection(selection)
            guard let importedReaderFileURL else {
                debugPrint("Warning: Unable to resolve reader file URL for imported file", importedFileURL)
                return nil
            }
            guard let content = realm.objects(ContentFile.self)
                .filter(NSPredicate(format: "isDeleted == %@ AND url == %@", NSNumber(booleanLiteral: false), importedReaderFileURL.absoluteString as CVarArg))
                .first else {
                debugPrint("Warning: No matching content metadata returned for imported file", importedReaderFileURL)
                return nil
            }
            // A live accessor can be invalidated while the final scan awaits.
            let resultURL = content.url
            try await refreshAllFilesMetadata(force: true, selection: selection)
            try validateMetadataRefreshSelection(selection)
            return resultURL
        } catch {
            debugPrint("Error importing file:", error)
            throw error
        }
    }
    
    @MainActor
    private func metadataRefreshSelection(
        realmConfiguration: Realm.Configuration
    ) throws -> MetadataRefreshSelection {
        let selection = MetadataRefreshSelection(localDrive: localDrive, cloudDrive: cloudDrive,
            initializationIdentifier: initializationID, realmConfiguration: realmConfiguration)
        try self.validateMetadataRefreshSelection(selection)
        return selection
    }

    private func validateMetadataRefreshSelection(_ selection: MetadataRefreshSelection) throws {
        try Task.checkCancellation()
        guard localDrive === selection.localDrive, cloudDrive === selection.cloudDrive,
              initializationID == selection.initializationIdentifier,
              Self.sameHistoryRealm(resolvedHistoryRealmConfiguration, selection.realmConfiguration) else {
            throw CancellationError()
        }
    }

    /// Migration completion requires a complete scan of its captured container.
    /// Ordinary inventory refresh remains best-effort across independent roots.
    @MainActor
    public func refreshMigratedCloudDocumentsMetadata(containerURL: URL) async throws {
        let selection = try metadataRefreshSelection(realmConfiguration: resolvedHistoryRealmConfiguration)
        let expectedRoot = containerURL.appendingPathComponent("Documents", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard containerURL.isFileURL,
              let drive = selection.cloudDrive,
              drive.isConnected,
              drive.rootDirectory.standardizedFileURL.resolvingSymlinksInPath() == expectedRoot else {
            throw ReaderFileManagerError.driveMissing
        }
        // Migration must enumerate after relocation. An ordinary root or
        // descendant scan already in flight may predate those committed moves.
        let scan = try await scanFilesMetadata(
            drive: drive, relativePath: nil,
            realmConfiguration: selection.realmConfiguration, selection: selection,
            coalesceChildScans: false
        )
        try validateMetadataRefreshSelection(selection)
        guard drive.isConnected else { throw ReaderFileManagerError.driveMissing }
        guard scan.isComplete else { throw ReaderFileManagerError.incompleteMetadataScan }
        let references = try await makeContentFileReferences(
            for: scan.contentFileIDs, realmConfiguration: selection.realmConfiguration
        )
        try validateMetadataRefreshSelection(selection)
        try await publishDiscoveredFiles(references, selection: selection)
        try validateMetadataRefreshSelection(selection)
        guard drive.isConnected else { throw ReaderFileManagerError.driveMissing }
    }

    @MainActor
    public func refreshAllFilesMetadata(force: Bool = false) async throws {
        let selection = try metadataRefreshSelection(realmConfiguration: resolvedHistoryRealmConfiguration)
        try await refreshAllFilesMetadata(force: force, selection: selection)
    }

    @MainActor
    private func refreshAllFilesMetadata(
        force: Bool,
        realmConfiguration: Realm.Configuration
    ) async throws {
        let selection = try metadataRefreshSelection(realmConfiguration: realmConfiguration)
        try await refreshAllFilesMetadata(force: force, selection: selection)
    }

    @MainActor
    private func refreshAllFilesMetadata(force: Bool, selection: MetadataRefreshSelection) async throws {
        try validateMetadataRefreshSelection(selection)
        let realmConfiguration = selection.realmConfiguration
        let queue = resolvedInventoryRefreshQueue()
        let completion = queue.enqueue(
            scope: selection.queueScope,
            force: force
        ) { @MainActor [weak self] in
            guard let self else { return }
            try self.validateMetadataRefreshSelection(selection)
            guard selection.localDrive != nil || selection.cloudDrive != nil else { return }

            // Capture candidates before scanning. New imports and edits that
            // occur while enumeration suspends are not orphan candidates.
            let candidates: [InventoryCandidate] = try await {
                @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(
                    for: realmConfiguration
                )
                let results = realm.objects(ContentFile.self).where {
                    !$0.isDeleted
                }
                var snapshot = [InventoryCandidate]()
                snapshot.reserveCapacity(results.count)
                for file in results {
                    snapshot.append(
                        InventoryCandidate(
                            id: file.compoundKey,
                            url: file.url,
                            modifiedAt: file.modifiedAt
                        )
                    )
                }
                return snapshot
            }()

            var discoveredIDs = Set<String>()
            var completeLocations = Set<String>()
            for (location, drive) in [
                ("local", selection.localDrive),
                ("icloud", selection.cloudDrive),
            ] {
                try self.validateMetadataRefreshSelection(selection)
                guard let drive, drive.isConnected else { continue }
                do {
                    let scan = try await coalescedFilesMetadataRefresh(
                        drive: drive,
                        relativePath: nil,
                        realmConfiguration: realmConfiguration,
                        selection: selection
                    )
                    try self.validateMetadataRefreshSelection(selection)
                    discoveredIDs.formUnion(scan.contentFileIDs)
                    if scan.isComplete {
                        completeLocations.insert(location)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // This root is unknown, not empty. Other successful roots
                    // can still refresh without deleting its records.
                    Logger.shared.logger.error(
                        "File inventory unavailable: \(error)"
                    )
                }
            }

            try self.validateMetadataRefreshSelection(selection)
            let completed = completeLocations
            let discovered = discoveredIDs
            let activeIDs: [String] = try await {
                @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(
                    for: realmConfiguration
                )
                try await realm.asyncWritePreservingOwnership {
                    try self.validateMetadataRefreshSelection(selection)
                    let date = Date()
                    for candidate in candidates {
                        guard !discovered.contains(candidate.id),
                              let canonical = self.canonicalReaderBackingURL(
                                for: candidate.url
                              ),
                              let location = canonical.pathComponents
                                .dropFirst(2).first,
                              completed.contains(location),
                              let file = realm.object(
                                ofType: ContentFile.self,
                                forPrimaryKey: candidate.id
                              ),
                              !file.isDeleted,
                              file.url == candidate.url,
                              file.modifiedAt == candidate.modifiedAt
                        else {
                            continue
                        }
                        file.isDeleted = true
                        file.refreshChangeMetadata(
                            explicitlyModified: true,
                            at: date
                        )
                    }
                    try self.validateMetadataRefreshSelection(selection)
                }

                let results = realm.objects(ContentFile.self).where {
                    !$0.isDeleted
                }
                var snapshot = [String]()
                snapshot.reserveCapacity(results.count)
                for file in results {
                    snapshot.append(file.compoundKey)
                }
                return snapshot
            }()

            try Task.checkCancellation()
            let realm = try await Realm.open(configuration: realmConfiguration)
            try Task.checkCancellation()
            try self.validateMetadataRefreshSelection(selection)
            // Retain unknown-root records in the published inventory too.
            self.files = activeIDs.compactMap {
                realm.object(
                    ofType: ContentFile.self,
                    forPrimaryKey: $0
                )
            }.filter { !$0.isDeleted }
        }

        try await completion.wait().get()
        try validateMetadataRefreshSelection(selection)
    }
    
    static let additionalFilePackageSuffixesToAvoidDescendingInto = [
        ".epub",
    ]
    
    @MainActor
    func refreshFilesMetadata(
        drive: CloudDrive,
        relativePath: RootRelativePath? = nil,
        realmConfiguration: Realm.Configuration? = nil
    ) async throws -> [ThreadSafeReference<ContentFile>]? {
        let realmConfiguration = realmConfiguration ?? resolvedHistoryRealmConfiguration
        let selection = try metadataRefreshSelection(realmConfiguration: realmConfiguration)
        return try await refreshFilesMetadata(drive: drive, relativePath: relativePath, selection: selection)
    }

    @MainActor
    private func refreshFilesMetadata(
        drive: CloudDrive,
        relativePath: RootRelativePath?,
        selection: MetadataRefreshSelection
    ) async throws -> [ThreadSafeReference<ContentFile>]? {
        try validateMetadataRefreshSelection(selection)
        let realmConfiguration = selection.realmConfiguration
        guard drive === selection.localDrive || drive === selection.cloudDrive else {
            throw CancellationError()
        }
        let scan = try await coalescedFilesMetadataRefresh(
            drive: drive,
            relativePath: relativePath,
            realmConfiguration: realmConfiguration,
            selection: selection
        )
        try self.validateMetadataRefreshSelection(selection)
        let references = try await makeContentFileReferences(
            for: scan.contentFileIDs,
            realmConfiguration: realmConfiguration
        )
        try self.validateMetadataRefreshSelection(selection)
        return references
    }

    @ReaderFileManagerActor
    private func coalescedFilesMetadataRefresh(
        drive: CloudDrive,
        relativePath: RootRelativePath?,
        realmConfiguration: Realm.Configuration,
        selection: MetadataRefreshSelection
    ) async throws -> MetadataScanResult {
        try self.validateMetadataRefreshSelection(selection)
        let key = MetadataRefreshKey(
            driveIdentifier: ObjectIdentifier(drive),
            selectionScope: selection.queueScope,
            driveRootPath: drive.rootDirectory.standardizedFileURL.path,
            driveContainerIdentifier: drive.ubiquityContainerIdentifier,
            relativePath: relativePath?.path ?? "",
            realmFileURL: realmConfiguration.fileURL?.standardizedFileURL.absoluteString,
            realmInMemoryIdentifier: realmConfiguration.inMemoryIdentifier
        )
        if let existing = metadataRefreshEntries[key] {
            metadataRefreshDidCoalesce?()
            return try await existing.task.value
        }

        let id = UUID()
        let task = Task { @ReaderFileManagerActor [self] in
            try await scanFilesMetadata(
                drive: drive,
                relativePath: relativePath,
                realmConfiguration: realmConfiguration,
                selection: selection
            )
        }
        metadataRefreshEntries[key] = MetadataRefreshEntry(id: id, task: task)
        do {
            let result = try await task.value
            if metadataRefreshEntries[key]?.id == id {
                metadataRefreshEntries.removeValue(forKey: key)
            }
            return result
        } catch {
            if metadataRefreshEntries[key]?.id == id {
                metadataRefreshEntries.removeValue(forKey: key)
            }
            throw error
        }
    }

    @ReaderFileManagerActor
    private func scanFilesMetadata(
        drive: CloudDrive,
        relativePath: RootRelativePath?,
        realmConfiguration: Realm.Configuration,
        selection: MetadataRefreshSelection,
        coalesceChildScans: Bool = true
    ) async throws -> MetadataScanResult {
        try self.validateMetadataRefreshSelection(selection)
        var scan = MetadataScanResult()
        var filesToUpdate: [
            (readerFileURL: URL, relativePath: RootRelativePath, drive: CloudDrive)
        ] = []
        do {
            let urls: [URL]
            if let directoryContentsProvider {
                let directory = try (relativePath ?? .root).directoryURL(forRoot: drive.rootDirectory)
                urls = try await directoryContentsProvider(directory)
            } else {
                urls = try await drive.contentsOfDirectory(
                    at: relativePath ?? .root,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .producesRelativePathURLs]
                )
            }
            try self.validateMetadataRefreshSelection(selection)
            for url in urls {
                try self.validateMetadataRefreshSelection(selection)
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
                let isDirectory: Bool
                do {
                    let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
                    if let value = resourceValues.isDirectory {
                        isDirectory = value
                    } else if case .localDirectory = drive.storage {
                        // The directory enumeration already supplied this URL;
                        // avoid a second coordinated claim for local files.
                        isDirectory = url.hasDirectoryPath
                    } else {
                        isDirectory = try await drive.directoryExists(at: tryRelativePath)
                    }
                } catch {
                    if Self.isMissingFileError(error) {
                        Self.logContentFileDecision(
                            stage: "discovery.skipMissing",
                            path: tryRelativePath.path,
                            reason: "disappearedDuringRefresh"
                        )
                        scan.isComplete = false
                        continue
                    }
                    throw error
                }
                if !url.isFilePackage(),
                   !Self.additionalFilePackageSuffixesToAvoidDescendingInto.contains(
                    where: { lastPathComponent.hasSuffix($0) }
                   ),
                   isDirectory {
                    let discoveredFiles: MetadataScanResult
                    if coalesceChildScans {
                        discoveredFiles = try await coalescedFilesMetadataRefresh(
                            drive: drive,
                            relativePath: tryRelativePath,
                            realmConfiguration: realmConfiguration,
                            selection: selection
                        )
                    } else {
                        discoveredFiles = try await scanFilesMetadata(
                            drive: drive,
                            relativePath: tryRelativePath,
                            realmConfiguration: realmConfiguration,
                            selection: selection,
                            coalesceChildScans: false
                        )
                    }
                    scan.contentFileIDs.append(contentsOf: discoveredFiles.contentFileIDs)
                    scan.isComplete = scan.isComplete && discoveredFiles.isComplete
                } else {
                    let absoluteFileURL = try tryRelativePath.fileURL(forRoot: drive.rootDirectory)
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
                    if let readerFileURL = try await readerFileURL(
                        for: absoluteFileURL,
                        drive: drive
                    ) {
                        filesToUpdate.append((readerFileURL, tryRelativePath, drive))
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
                scan.isComplete = false
                return scan
            }
            if !(error is CancellationError) {
                debugPrint("refreshFilesMetadata error:", error)
            }
            throw error
        }

        if !filesToUpdate.isEmpty {
            let metadataScan = try await { @RealmBackgroundActor in
                var updatedFiles = [ContentFile]()
                var metadataScan = MetadataScanResult()
                let realm = try await RealmBackgroundActor.shared.cachedRealm(
                    for: realmConfiguration
                )

                let processingStartedAt = Date()
                try await realm.asyncWritePreservingOwnership {
                    try self.validateMetadataRefreshSelection(selection)
                    for (readerFileURL, relativePath, drive) in filesToUpdate {
                        try self.validateMetadataRefreshSelection(selection)
                        // Enumeration and URL mapping can suspend before this
                        // independent write. An old path is not evidence that
                        // a deleted payload still exists: do not create/revive
                        // its index or replace its deletion journal generation.
                        let payloadURL = try relativePath.fileURL(forRoot: drive.rootDirectory)
                        guard try Self.fileSystemEntryExists(at: payloadURL) else {
                            metadataScan.isComplete = false
                            continue
                        }
                        if let existing = realm.objects(ContentFile.self).filter(
                            NSPredicate(
                                format: "url == %@",
                                readerFileURL.absoluteString as CVarArg
                            )
                        ).first {
                            try Task.checkCancellation()
                            if try setMetadata(
                                fileURL: readerFileURL,
                                contentFile: existing,
                                drive: drive
                            ) || (existing.url.isEBookURL && !existing.isPhysicalMedia) {
                                updatedFiles.append(existing)
                            }
                            metadataScan.contentFileIDs.append(existing.compoundKey)
                        } else {
                            let contentFile = ContentFile()
                            contentFile.url = readerFileURL
                            try Task.checkCancellation()
                            if try setMetadata(
                                fileURL: readerFileURL,
                                contentFile: contentFile,
                                drive: drive
                            ) {
                                contentFile.updateCompoundKey()
                                contentFile.isReaderModeByDefault =
                                    ReaderContentLoader.supportsReaderContent(
                                        mimeType: contentFile.mimeType,
                                        pathExtension: readerFileURL.lakePathExtension
                                )
                                realm.add(contentFile, update: .modified)
                                contentFile.refreshChangeMetadata(explicitlyModified: true)
                                updatedFiles.append(contentFile)
                                metadataScan.contentFileIDs.append(contentFile.compoundKey)
                            }
                        }
                    }
                    try self.validateMetadataRefreshSelection(selection)
                }
                try self.validateMetadataRefreshSelection(selection)
                let deferredIDs = try await processUpdatedFiles(updatedFiles, selection: selection)
                try await realm.asyncWritePreservingOwnership {
                    try self.validateMetadataRefreshSelection(selection)
                    for file in updatedFiles where !file.isInvalidated && !file.isDeleted {
                        // Use the start, not completion time, so a payload modified
                        // during enrichment is eligible for a subsequent pass.
                        let refreshedAt: Date? = deferredIDs.contains(file.compoundKey)
                            ? nil : processingStartedAt
                        guard file.fileMetadataRefreshedAt != refreshedAt else { continue }
                        file.fileMetadataRefreshedAt = refreshedAt
                        file.refreshChangeMetadata(explicitlyModified: true)
                    }
                    try self.validateMetadataRefreshSelection(selection)
                }
                return metadataScan
            }()
            scan.contentFileIDs.append(contentsOf: metadataScan.contentFileIDs)
            scan.isComplete = scan.isComplete && metadataScan.isComplete
        }
        return scan
    }

    @RealmBackgroundActor
    private func makeContentFileReferences(
        for contentFileIDs: [String]?,
        realmConfiguration: Realm.Configuration
    ) async throws -> [ThreadSafeReference<ContentFile>]? {
        guard let contentFileIDs else { return nil }
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: realmConfiguration
        )
        return contentFileIDs.compactMap {
            realm.object(ofType: ContentFile.self, forPrimaryKey: $0)
        }.map(ThreadSafeReference.init(to:))
    }

    @RealmBackgroundActor
    @discardableResult
    func processUpdatedFiles(_ updatedFiles: [ContentFile]) async throws -> Set<String> {
        try await processUpdatedFiles(updatedFiles, selection: nil)
    }

    @RealmBackgroundActor
    private func processUpdatedFiles(
        _ updatedFiles: [ContentFile], selection: MetadataRefreshSelection?
    ) async throws -> Set<String> {
        if let selection { try self.validateMetadataRefreshSelection(selection) }
        var readyFiles = [ContentFile]()
        var deferredIDs = Set<String>()
        for file in updatedFiles where !file.isInvalidated && !file.isDeleted {
            if try isPayloadReadableLocallyForMetadata(readerBackingURL: file.url) {
                readyFiles.append(file)
            } else {
                deferredIDs.insert(file.compoundKey)
            }
        }
        for fileProcessor in Self.fileProcessors {
            try Task.checkCancellation()
            if let selection { try self.validateMetadataRefreshSelection(selection) }
            try await fileProcessor(readyFiles)
            if let selection { try self.validateMetadataRefreshSelection(selection) }
        }
        for key in Self.fileEnrichmentProcessors.keys.sorted() {
            try Task.checkCancellation()
            guard let processor = Self.fileEnrichmentProcessors[key] else { continue }
            if let selection { try self.validateMetadataRefreshSelection(selection) }
            deferredIDs.formUnion(try await processor(readyFiles))
            if let selection { try self.validateMetadataRefreshSelection(selection) }
        }
        return deferredIDs
    }
    
    /// Note that ReaderContentMetadataSynchronizer keeps associated records in sync
    @RealmBackgroundActor
    private func setMetadata(fileURL: URL, contentFile: ContentFile, drive: CloudDrive) throws -> Bool {
        try Task.checkCancellation()
        var metadataUpdated = false
        let fileModifiedAt = Self.fileModificationDate(url: fileURL, drive: drive)
        
        if contentFile.isDeleted {
            contentFile.isDeleted = false
            metadataUpdated = true
        }

        let payloadAvailableLocally = try isPayloadReadableLocallyForMetadata(readerBackingURL: fileURL)
        try Task.checkCancellation()
        
        if metadataUpdated || contentFile.fileMetadataRefreshedAt ?? .distantPast <= fileModifiedAt ?? .distantPast {
            if contentFile.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let title = fileURL.deletingPathExtension().lastPathComponent
                if contentFile.title != title {
                    contentFile.title = title
                    metadataUpdated = true
                }
            }
            let pathExtension = fileURL.lakePathExtension
            let typeIdentifier = UTType(filenameExtension: pathExtension)?.identifier
            let mimeType = ReaderContentLoader.canonicalMimeType(
                mimeType: UTType(filenameExtension: pathExtension)?.preferredMIMEType,
                typeIdentifier: typeIdentifier,
                pathExtension: pathExtension
            )
            if contentFile.mimeType != mimeType {
                contentFile.mimeType = mimeType
                metadataUpdated = true
            }

            if payloadAvailableLocally {
                if !contentFile.isPhysicalMedia, contentFile.publicationDate != fileModifiedAt ?? Date() {
                    contentFile.publicationDate = fileModifiedAt ?? Date()
                    metadataUpdated = true
                }

                if pathExtension.lowercased() == "zip",
                   let systemFileURL = try? localFileURL(forReaderFileURL: fileURL),
                   let packageSource = try? ReaderPackageEntrySource(
                       localURL: systemFileURL,
                       limits: .metadata
                   ),
                   let packageEntries = try? packageSource.enumerateEntries() {
                    let paths = Set(packageEntries.map(\.path))
                    if Set(contentFile.packageFilePaths) != paths {
                        let filePaths = RealmSwift.MutableSet<String>()
                        filePaths.insert(objectsIn: paths)
                        contentFile.packageFilePaths = filePaths
                        metadataUpdated = true
                    }
                }
            }
            
            // Completion is published only after specialized processors return.
            if contentFile.fileMetadataRefreshedAt != nil {
                contentFile.fileMetadataRefreshedAt = nil
                metadataUpdated = true
            }
            if metadataUpdated {
                contentFile.refreshChangeMetadata(explicitlyModified: true)
            }
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
    private func removeDeletedFileFromPublishedFiles(
        matching readerBackingURL: URL, pathContext: ReaderBackingPathContext,
        drive: CloudDrive?, selection: MetadataRefreshSelection
    ) {
        // Display can be obsolete after durable success; skip it without
        // changing the command's already-committed physical/index outcome.
        guard deletionSelectionIsCurrent(pathContext, drive: drive, selection: selection) else { return }
        guard let canonicalDeletedURL = canonicalReaderBackingURL(for: readerBackingURL),
              let files else {
            return
        }
        let remainingFiles = files.filter { contentFile in
            guard !contentFile.isInvalidated else { return false }
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
    private func markDeleted(
        contentURL: URL, pathContext: ReaderBackingPathContext,
        drive: CloudDrive?, selection: MetadataRefreshSelection
    ) async throws {
        try validateDeletionSelection(pathContext, drive: drive, selection: selection)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: selection.realmConfiguration)
        let canonicalContentURL = pathContext.canonicalURL
        try await realm.asyncWritePreservingOwnership {
            try validateDeletionSelection(pathContext, drive: drive, selection: selection)
            // Missing at the earlier status read is not proof of continued
            // absence. A reimport at the same path must keep its live metadata.
            if let path = pathContext.activeRootURL, try Self.fileSystemEntryExists(at: path) {
                throw ReaderFileDeleteError.removeFailed(
                    underlyingDescription: "A file now exists at the selected path. Refresh the library before retrying."
                )
            }
            // Query only after this independent write is admitted. Managed
            // objects captured before an await can be deleted or replaced by
            // the owner whose transaction this writer is waiting to acquire.
            let contentFiles = Array(realm.objects(ContentFile.self)
                .where { !$0.isDeleted }
                .filter { file in
                    file.url == contentURL
                        || self.canonicalReaderBackingURL(for: file.url) == canonicalContentURL
                })
            let timestamp = Date()
            for existing in contentFiles {
                existing.isDeleted = true
                existing.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                let packageContentFiles = realm.objects(ContentPackageFile.self)
                    .where { $0.packageContentFileID == existing.compoundKey && !$0.isDeleted }
                for packageContentFile in packageContentFiles {
                    packageContentFile.isDeleted = true
                    packageContentFile.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                }
            }
            try validateDeletionSelection(pathContext, drive: drive, selection: selection)
        }
    }
    
    private static func extractRelativePath(fileURL: URL) throws -> RootRelativePath {
        guard let components = URLComponents(url: fileURL, resolvingAgainstBaseURL: false),
              isValidReaderBackingPath(components: components) else {
            throw ReaderFileManagerError.invalidFileURL
        }
        let rawComponents = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: false)
        guard rawComponents.count > 3 else {
            throw ReaderFileManagerError.invalidFileURL
        }
        let decodedComponents = try rawComponents.dropFirst(3).map { rawComponent -> String in
            guard let component = String(rawComponent).removingPercentEncoding,
                  !component.isEmpty else {
                throw ReaderFileManagerError.invalidFileURL
            }
            return component
        }
        return RootRelativePath(path: decodedComponents.joined(separator: "/"))
    }

    /// Validates the URL grammar used by reader backing files.  URL.pathComponents
    /// normalizes away empty components and leaves dot segments in place, so it is
    /// intentionally not sufficient for validating a path received from a web view.
    private static func isValidReaderBackingPath(components: URLComponents) -> Bool {
        guard let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              (scheme == "reader-file" && host == "file")
                || (scheme == "ebook" && host == "ebook")
                || (scheme == "mokuro" && host == "mokuro"),
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.percentEncodedPath.hasPrefix("/load/") else {
            return false
        }

        let rawComponents = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: false)
        // The leading empty component is followed by `load`, a storage location,
        // and at least one component identifying the package.
        guard rawComponents.count >= 4,
              rawComponents[0].isEmpty,
              rawComponents[1] == "load",
              rawComponents[2] == "local" || rawComponents[2] == "icloud" else {
            return false
        }

        for rawComponent in rawComponents.dropFirst(1) {
            let rawComponent = String(rawComponent)
            guard !rawComponent.isEmpty,
                  !rawComponent.contains("\\"),
                  let component = rawComponent.removingPercentEncoding,
                  !component.isEmpty,
                  component != ".",
                  component != "..",
                  !component.contains("/"),
                  !component.contains("\\"),
                  !component.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                return false
            }

            // Reject encoded separators and dot segments, including mixed-case
            // escapes. A second URL/path decoder must never be able to turn a
            // valid component into a traversal component later.
            let lowercased = rawComponent.lowercased()
            guard !lowercased.contains("%2f"),
                  !lowercased.contains("%5c"),
                  !lowercased.contains("%2e") else {
                return false
            }
        }
        return true
    }

    private static func validateContainedPath(
        _ relativePath: RootRelativePath,
        within rootURL: URL
    ) throws {
        let standardizedRootURL = rootURL.standardizedFileURL
        let candidateURL: URL
        do {
            candidateURL = try relativePath.fileURL(forRoot: rootURL).standardizedFileURL
        } catch is RootRelativePathError {
            throw ReaderFileManagerError.invalidFileURL
        }
        let lexicalRootComponents = standardizedRootURL.pathComponents
        let lexicalCandidateComponents = candidateURL.pathComponents
        guard lexicalCandidateComponents.count > lexicalRootComponents.count,
              Array(lexicalCandidateComponents.prefix(lexicalRootComponents.count)) == lexicalRootComponents else {
            throw ReaderFileManagerError.invalidFileURL
        }

        let resolvedRootURL = standardizedRootURL.resolvingSymlinksInPath().standardizedFileURL
        let rootComponents = resolvedRootURL.pathComponents
        var existingAncestorURL = candidateURL
        let fileManager = FileManager.default
        while existingAncestorURL.pathComponents.count > lexicalRootComponents.count,
              !fileManager.fileExists(atPath: existingAncestorURL.path) {
            // A dangling symlink cannot be a valid destination. Detect it
            // before climbing to a parent that might otherwise look safe.
            if (try? fileManager.destinationOfSymbolicLink(atPath: existingAncestorURL.path)) != nil {
                throw ReaderFileManagerError.invalidFileURL
            }
            existingAncestorURL.deleteLastPathComponent()
        }
        if existingAncestorURL.pathComponents.count > lexicalRootComponents.count {
            // Resolve the deepest existing prefix. Foundation does not always
            // resolve a symlink in a parent of a still-missing destination.
            let components = existingAncestorURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard components.count > rootComponents.count,
                  Array(components.prefix(rootComponents.count)) == rootComponents else {
                throw ReaderFileManagerError.invalidFileURL
            }
        }
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

        let localRootURL: URL? = storageLocation == .local
            ? try relativePath.fileURL(forRoot: localDrive?.rootDirectory ?? Self.getDocumentsDirectory()) : nil
        let cloudRootURL: URL? = storageLocation == .icloud
            ? try cloudDrive.map { try relativePath.fileURL(forRoot: $0.rootDirectory) } : nil
        let activeRootURL: URL?
        switch storageLocation {
        case .local:
            activeRootURL = localRootURL
        case .icloud:
            activeRootURL = cloudRootURL
        }

        // `RootRelativePath` intentionally remains a lightweight string type;
        // prove that each filesystem URL derived from the untrusted URL stays
        // below its drive root before it is used for availability or reads.
        switch storageLocation {
        case .local:
            try Self.validateContainedPath(
                relativePath, within: localDrive?.rootDirectory ?? Self.getDocumentsDirectory()
            )
        case .icloud:
            if let cloudDrive {
                try Self.validateContainedPath(relativePath, within: cloudDrive.rootDirectory)
            }
        }

        return ReaderBackingPathContext(
            readerBackingURL: readerBackingURL,
            relativePath: relativePath,
            storageLocation: storageLocation,
            canonicalURL: canonicalURL,
            localRootURL: localRootURL,
            cloudRootURL: cloudRootURL,
            activeRootURL: activeRootURL,
            localRootExists: try localRootURL.map { try Self.fileSystemEntryExists(at: $0) } ?? false,
            cloudRootExists: try cloudRootURL.map { try Self.fileSystemEntryExists(at: $0) } ?? false
        )
    }

    /// Automatic identity discovery must not use resolveReadableLocalURL,
    /// which can start provider downloads. This is a metadata-only eligibility
    /// check, with no local-path fallback for an unavailable iCloud source.
    /// nil is not evidence that the book/history is absent on another device.
    @MainActor
    public func resolveAlreadyReadableEBookURL(forReaderBackingURL url: URL) async throws -> URL? {
        guard url.lakePathExtension.lowercased() == "epub" else { throw ReaderFileManagerError.invalidFileURL }
        let observed = try readerBackingPathContext(for: url)
        guard let candidate = observed.activeRootURL else { return nil }
        let location: ReaderEBookLocalAvailability.StorageLocation =
            observed.storageLocation == .icloud ? .iCloud : .local
        let worker = Task.detached(priority: .utility) {
            try ReaderEBookLocalAvailability.isAlreadyReadable(at: candidate, location: location)
        }
        let readable = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        let current = try readerBackingPathContext(for: url)
        guard current.activeRootURL?.absoluteString.utf8.elementsEqual(candidate.absoluteString.utf8) == true else {
            throw ReaderEBookPackageSnapshotError.sourceChanged
        }
        return readable ? candidate : nil
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
            switch try payloadStateProvider(payloadURL) {
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

        // Missing/downloading components dominate transfer activity. Only a fully
        // readable package may be reported as uploading to read consumers.
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

        return ReaderBackingAvailability(
            status: hasUploadingPayload ? .uploading : .availableLocally,
            localURL: activeRootURL,
            requestedDownload: false
        )
    }

    enum PayloadState: Equatable, Sendable {
        case current
        case downloading
        case uploading
        case notLocal
    }

    private static func payloadState(at url: URL) throws -> PayloadState {
        try Task.checkCancellation()
        guard try fileSystemEntryExists(at: url) else {
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
        try Task.checkCancellation()
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
                let state = try payloadStateProvider(payloadURL)
                guard state == .current || state == .uploading else {
                    return false
                }
            }
            return true
        }
    }

    private static func fileSystemEntryExists(at url: URL) throws -> Bool {
        // fileExists also returns false when inspection is denied. Only an
        // explicit missing-item error is absence evidence for a tombstone.
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return true
        } catch {
            if isMissingFileError(error) { return false }
            throw error
        }
    }

    private static func postReaderBackingStatusRefresh(for readerBackingURL: URL) {
        NotificationCenter.default.post(
            name: readerBackingStatusRefreshRequestedNotification,
            object: readerBackingURL.absoluteString
        )
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
        let rootComponents = rootDirectory.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        guard fileComponents.count >= rootComponents.count,
              Array(fileComponents.prefix(rootComponents.count)) == rootComponents else {
            print("File is not within the root directory.")
            return nil
        }
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
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
        if ReaderFileStoragePaths.isDownloadArtifact(absoluteFileURL) { return true }
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
        let selection = try metadataRefreshSelection(realmConfiguration: resolvedHistoryRealmConfiguration)
        guard let drive = ((selection.cloudDrive?.isConnected ?? false)
            ? selection.cloudDrive : nil) ?? selection.localDrive else { return nil }

        let targetDirectory = try await Self.rootRelativePath(forImportedURL: url, drive: drive)
        try validateMetadataRefreshSelection(selection)
        // A basename is not proof that a file came from this catalog resource.
        // Keep legacy files untouched rather than adopting an ambiguous match.
        let identity = ReaderFileStoragePaths.downloadIdentity(for: url)
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let targetFilePath = targetDirectory
            .appending(ReaderFileStoragePaths.downloadsDirectory)
            .appending(digest)
            .appending(try ReaderFileStoragePaths.downloadFilename(for: url))
        try Self.validateContainedPath(targetFilePath, within: drive.rootDirectory)
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

    /// Streams a deterministic package manifest into SHA-256. Every record
    /// contains its relative path, entry type, size, and (for regular files)
    /// its bytes. This avoids the old quadratic Data concatenation and keeps
    /// package comparison independent of directory enumeration order.
    func packageManifestDigest() throws -> Data {
        let fileManager = FileManager.default
        let rootURL = standardizedFileURL
        let resolvedRootURL = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let rootValues = try resolvedRootURL.resourceValues(forKeys: [.isDirectoryKey])
        guard rootValues.isDirectory == true else {
            throw PackageManifestError.invalidRoot
        }

        var hasher = SHA256()
        try appendPackageManifestEntries(
            at: rootURL,
            relativePath: "",
            resolvedRootURL: resolvedRootURL,
            fileManager: fileManager,
            hasher: &hasher
        )
        return Data(hasher.finalize())
    }
}

private enum PackageManifestError: Swift.Error {
    case invalidRoot
}

private func appendPackageManifestEntries(
    at directoryURL: URL,
    relativePath: String,
    resolvedRootURL: URL,
    fileManager: FileManager,
    hasher: inout SHA256
) throws {
    let children = try fileManager.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .fileSizeKey,
        ],
        options: []
    ).sorted { lhs, rhs in
        lhs.lastPathComponent.utf8.lexicographicallyPrecedes(rhs.lastPathComponent.utf8)
    }

    for childURL in children {
        try Task.checkCancellation()
        let childRelativePath = relativePath.isEmpty
            ? childURL.lastPathComponent
            : relativePath + "/" + childURL.lastPathComponent

        // Asking FileManager for the link destination does not dereference
        // the link. Record its target bytes and never read or recurse through
        // it; this prevents a package-local symlink from exposing outside
        // files during comparison.
        if let symlinkTarget = try? fileManager.destinationOfSymbolicLink(atPath: childURL.path) {
            let targetData = Data(symlinkTarget.utf8)
            appendPackageManifestField("entry", hasher: &hasher)
            appendPackageManifestField(childRelativePath, hasher: &hasher)
            appendPackageManifestField("symlink", hasher: &hasher)
            appendPackageManifestField(String(targetData.count), hasher: &hasher)
            hasher.update(data: targetData)
            hasher.update(data: Data([0]))
            continue
        }

        let resolvedURL = childURL.resolvingSymlinksInPath().standardizedFileURL
        guard isPackageManifestContained(resolvedURL, within: resolvedRootURL) else {
            // A link may have been introduced between enumeration and this
            // check. Do not follow an entry that escaped the package root.
            continue
        }

        let values = try childURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
        if values.isDirectory == true {
            appendPackageManifestField("entry", hasher: &hasher)
            appendPackageManifestField(childRelativePath, hasher: &hasher)
            appendPackageManifestField("directory", hasher: &hasher)
            appendPackageManifestField("0", hasher: &hasher)
            try appendPackageManifestEntries(
                at: childURL,
                relativePath: childRelativePath,
                resolvedRootURL: resolvedRootURL,
                fileManager: fileManager,
                hasher: &hasher
            )
            continue
        }

        guard values.isRegularFile == true else { continue }
        let advertisedSize = Int64(values.fileSize ?? 0)
        appendPackageManifestField("entry", hasher: &hasher)
        appendPackageManifestField(childRelativePath, hasher: &hasher)
        appendPackageManifestField("file", hasher: &hasher)
        appendPackageManifestField(String(advertisedSize), hasher: &hasher)

        let handle = try FileHandle(forReadingFrom: resolvedURL)
        defer { try? handle.close() }
        while let bytes = try handle.read(upToCount: 64 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: bytes)
        }
        hasher.update(data: Data([0]))
    }
}

private func appendPackageManifestField(_ value: String, hasher: inout SHA256) {
    hasher.update(data: Data(value.utf8))
    hasher.update(data: Data([0]))
}

private func isPackageManifestContained(_ url: URL, within rootURL: URL) -> Bool {
    let rootComponents = rootURL.pathComponents
    let components = url.pathComponents
    return components.count > rootComponents.count
        && Array(components.prefix(rootComponents.count)) == rootComponents
}

fileprivate extension FileManager {
    func isDirectory(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
