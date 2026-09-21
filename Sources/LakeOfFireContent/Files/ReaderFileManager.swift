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
    /// A reader-URL processor returned a URL that does not map back to the
    /// exact selected drive path.
    case invalidReaderFileURL
    /// More than one processor claimed the same file with different reader URLs.
    case ambiguousReaderFileURL
    /// A destination processor returned a path that is not strictly relative
    /// to the selected drive root.
    case invalidDestinationPath
    /// More than one processor claimed the same file with different destinations.
    case ambiguousDestinationPath
    case driveMissing
    /// Enumeration did not establish a complete current inventory, so it is unsafe to
    /// publish replacements or derive synchronized orphan tombstones from it.
    case incompleteFileInventory
    /// A drive root or Realm configuration changed while a refresh was in flight.
    case refreshSuperseded
}

struct ReaderFileSourceAccess: @unchecked Sendable {
    let start: (URL) throws -> Bool
    let stop: (URL) -> Void

    static let securityScoped = Self(
        start: { $0.startAccessingSecurityScopedResource() },
        stop: { $0.stopAccessingSecurityScopedResource() }
    )
}

enum ReaderFilePayloadState: Equatable {
    case current
    case downloading
    case uploading
    case notLocal
}

struct ReaderFileAvailabilityAccess: @unchecked Sendable {
    let payloadState: (URL) throws -> ReaderFilePayloadState
    let startDownloading: (URL) throws -> Void
    let canCoordinateRead: (URL) async throws -> Bool
}

private final class ReaderFilePostprocessorOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var deferredContentFilePrimaryKeys = Set<String>()

    func deferPostprocessing(contentFilePrimaryKey: String) {
        lock.lock()
        deferredContentFilePrimaryKeys.insert(contentFilePrimaryKey)
        lock.unlock()
    }

    func isDeferred(contentFilePrimaryKey: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return deferredContentFilePrimaryKeys.contains(contentFilePrimaryKey)
    }
}

public struct ReaderFilePostprocessorContext: @unchecked Sendable {
    public let readerFileManager: ReaderFileManager
    public let realmConfiguration: Realm.Configuration
    public let contentFiles: [ContentFile]
    @RealmBackgroundActor public let realm: Realm
    private let outcome: ReaderFilePostprocessorOutcome?
    private let admission: ReaderFilePostprocessorAdmission?

    @RealmBackgroundActor
    fileprivate init(
        readerFileManager: ReaderFileManager,
        realmConfiguration: Realm.Configuration,
        realm: Realm,
        contentFiles: [ContentFile],
        outcome: ReaderFilePostprocessorOutcome? = nil,
        admission: ReaderFilePostprocessorAdmission? = nil
    ) {
        self.readerFileManager = readerFileManager
        self.realmConfiguration = realmConfiguration
        self.realm = realm
        self.contentFiles = contentFiles
        self.outcome = outcome
        self.admission = admission
    }

    /// Keeps this file generation pending without failing the wider import or
    /// suppressing another processor. Only versioned processors have a durable
    /// outcome collector; legacy anonymous adapters remain best effort.
    @RealmBackgroundActor
    public func deferPostprocessing(for contentFile: ContentFile) {
        outcome?.deferPostprocessing(
            contentFilePrimaryKey: contentFile.compoundKey
        )
    }

    /// Commits a durable processor's derived metadata only while the exact
    /// processor registration, file incarnation, source generation, and work-item
    /// attempt supplied to this invocation are still current.
    ///
    /// Durable processors should publish all Realm effects through this method
    /// after suspension points. A rejected write leaves the file's work item pending
    /// so the active processor and source generation can retry it.
    @RealmBackgroundActor
    @discardableResult
    public func performCurrentWrite(
        _ mutation: @escaping @RealmBackgroundActor (Realm, ContentFile) throws -> Void
    ) async throws -> Bool {
        guard let admission else {
            return false
        }
        let didApply = try await readerFileManager.performPostprocessorWriteIfCurrent(
            admission: admission,
            in: realm,
            mutation: mutation
        )
        if !didApply {
            outcome?.deferPostprocessing(
                contentFilePrimaryKey: admission.contentFilePrimaryKey
            )
        }
        return didApply
    }
}

private typealias ReaderFileDestinationProcessor = (URL) async throws -> RootRelativePath?
private typealias ReaderFileURLProcessor = @RealmBackgroundActor (URL, String) async throws -> URL?
private typealias ReaderFilePostprocessor = @RealmBackgroundActor (ReaderFilePostprocessorContext) async throws -> Void

private struct ReaderFilePostprocessorIdentity: Hashable, Sendable {
    let identifier: String
    let version: Int64
}

private struct ReaderFilePostprocessorRegistration: @unchecked Sendable {
    let registrationIdentifier: UUID
    let identity: ReaderFilePostprocessorIdentity?
    let processor: ReaderFilePostprocessor
}

fileprivate struct ReaderFilePostprocessorAdmission: Sendable {
    let registrationIdentifier: UUID
    let processorIdentity: ReaderFilePostprocessorIdentity
    let workItemIdentifier: String
    let attemptIdentifier: String
    let storageScopeIdentifier: String
    let contentFilePrimaryKey: String
    let contentFileCreatedAt: Date
    let readerFileURLString: String
    let absoluteFileURL: URL
    let sourceModifiedAt: Date?
    let sourceFileSize: Int64
}

private let defaultReaderContentMimeTypes: [UTType] = [
    .plainText,
    .html,
    UTType(filenameExtension: "md")
        ?? UTType(importedAs: "net.daringfireball.markdown"),
    .zip,
]

private struct ReaderFileProcessorRegistrySnapshot: @unchecked Sendable {
    let readerContentMimeTypes: [UTType]
    let destinationProcessors: [ReaderFileDestinationProcessor]
    let readerFileURLProcessors: [ReaderFileURLProcessor]
    let filePostprocessors: [ReaderFilePostprocessorRegistration]
}

private struct ReaderFileProcessorOperationSnapshot: @unchecked Sendable {
    let managerIdentity: ObjectIdentifier
    let processors: ReaderFileProcessorRegistrySnapshot
}

private final class ReaderFileProcessorRegistry: @unchecked Sendable {
    private struct Registration<Processor> {
        let identifier: String?
        let processor: Processor
    }

    private let lock = NSLock()
    private var baseReaderContentMimeTypes = defaultReaderContentMimeTypes
    private var readerContentMimeTypeRegistrations = [Registration<[UTType]>]()
    private var destinationRegistrations = [Registration<ReaderFileDestinationProcessor>]()
    private var readerFileURLRegistrations = [Registration<ReaderFileURLProcessor>]()
    private var filePostprocessorRegistrations = [Registration<ReaderFilePostprocessorRegistration>]()

    func snapshot() -> ReaderFileProcessorRegistrySnapshot {
        lock.lock()
        defer { lock.unlock() }
        var readerContentMimeTypes = baseReaderContentMimeTypes
        for registration in readerContentMimeTypeRegistrations {
            for mimeType in registration.processor where !readerContentMimeTypes.contains(mimeType) {
                readerContentMimeTypes.append(mimeType)
            }
        }
        return ReaderFileProcessorRegistrySnapshot(
            readerContentMimeTypes: readerContentMimeTypes,
            destinationProcessors: destinationRegistrations.map(\.processor),
            readerFileURLProcessors: readerFileURLRegistrations.map(\.processor),
            filePostprocessors: filePostprocessorRegistrations.map(\.processor)
        )
    }

    func replaceReaderContentMimeTypes(_ mimeTypes: [UTType]) {
        lock.lock()
        baseReaderContentMimeTypes = mimeTypes
        readerContentMimeTypeRegistrations = []
        lock.unlock()
    }

    func replaceDestinationProcessors(_ processors: [ReaderFileDestinationProcessor]) {
        lock.lock()
        destinationRegistrations = processors.map {
            Registration(identifier: nil, processor: $0)
        }
        lock.unlock()
    }

    func replaceReaderFileURLProcessors(_ processors: [ReaderFileURLProcessor]) {
        lock.lock()
        readerFileURLRegistrations = processors.map {
            Registration(identifier: nil, processor: $0)
        }
        lock.unlock()
    }

    func replaceFilePostprocessors(_ processors: [ReaderFilePostprocessor]) {
        lock.lock()
        filePostprocessorRegistrations = processors.map {
            Registration(
                identifier: nil,
                processor: ReaderFilePostprocessorRegistration(
                    registrationIdentifier: UUID(),
                    identity: nil,
                    processor: $0
                )
            )
        }
        lock.unlock()
    }

    func registerDestinationProcessor(
        identifier: String,
        processor: @escaping ReaderFileDestinationProcessor
    ) {
        lock.lock()
        replaceOrAppend(
            identifier: identifier,
            processor: processor,
            registrations: &destinationRegistrations
        )
        lock.unlock()
    }

    func registerReaderFileURLProcessor(
        identifier: String,
        processor: @escaping ReaderFileURLProcessor
    ) {
        lock.lock()
        replaceOrAppend(
            identifier: identifier,
            processor: processor,
            registrations: &readerFileURLRegistrations
        )
        lock.unlock()
    }

    func registerFilePostprocessor(
        identifier: String,
        version: Int64?,
        processor: @escaping ReaderFilePostprocessor
    ) {
        lock.lock()
        replaceOrAppend(
            identifier: identifier,
            processor: ReaderFilePostprocessorRegistration(
                registrationIdentifier: UUID(),
                identity: version.map {
                    ReaderFilePostprocessorIdentity(identifier: identifier, version: $0)
                },
                processor: processor
            ),
            registrations: &filePostprocessorRegistrations
        )
        lock.unlock()
    }

    func registerProcessorBundle(
        identifier: String,
        fileProcessorVersion: Int64?,
        readerContentMimeTypes newReaderContentMimeTypes: [UTType],
        destinationProcessor: @escaping ReaderFileDestinationProcessor,
        readerFileURLProcessor: @escaping ReaderFileURLProcessor,
        filePostprocessor: @escaping ReaderFilePostprocessor
    ) {
        lock.lock()
        replaceOrAppend(
            identifier: identifier,
            processor: newReaderContentMimeTypes,
            registrations: &readerContentMimeTypeRegistrations
        )
        replaceOrAppend(
            identifier: identifier,
            processor: destinationProcessor,
            registrations: &destinationRegistrations
        )
        replaceOrAppend(
            identifier: identifier,
            processor: readerFileURLProcessor,
            registrations: &readerFileURLRegistrations
        )
        replaceOrAppend(
            identifier: identifier,
            processor: ReaderFilePostprocessorRegistration(
                registrationIdentifier: UUID(),
                identity: fileProcessorVersion.map {
                    ReaderFilePostprocessorIdentity(identifier: identifier, version: $0)
                },
                processor: filePostprocessor
            ),
            registrations: &filePostprocessorRegistrations
        )
        lock.unlock()
    }

    func mutateIfCurrentFilePostprocessor<Result>(
        registrationIdentifier: UUID,
        _ mutation: () throws -> Result?
    ) rethrows -> Result? {
        lock.lock()
        defer { lock.unlock() }
        guard filePostprocessorRegistrations.contains(where: {
            $0.processor.registrationIdentifier == registrationIdentifier
        }) else {
            return nil
        }
        return try mutation()
    }

    private func replaceOrAppend<Processor>(
        identifier: String,
        processor: Processor,
        registrations: inout [Registration<Processor>]
    ) {
        let registration = Registration(identifier: identifier, processor: processor)
        if let index = registrations.firstIndex(where: { $0.identifier == identifier }) {
            registrations[index] = registration
        } else {
            registrations.append(registration)
        }
    }
}

/// Detached Realm metadata for one ordinary `reader-file:` response.
///
/// The store and creation timestamp identify the exact `ContentFile` incarnation. The
/// remaining fields are included so a caller can reject metadata changes that overlap its
/// byte read without transferring a Realm-managed object between actors.
public struct ReaderFileDocumentMetadataSnapshot: Hashable, Sendable {
    public let storeIdentity: BookmarkStoreIdentity
    public let contentFilePrimaryKey: String
    public let sourceURL: URL
    public let createdAt: Date
    public let modifiedAt: Date
    public let fileMetadataRefreshedAt: Date?
    public let mimeType: String

    public init(
        storeIdentity: BookmarkStoreIdentity,
        contentFilePrimaryKey: String,
        sourceURL: URL,
        createdAt: Date,
        modifiedAt: Date,
        fileMetadataRefreshedAt: Date?,
        mimeType: String
    ) {
        self.storeIdentity = storeIdentity
        self.contentFilePrimaryKey = contentFilePrimaryKey
        self.sourceURL = sourceURL
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.fileMetadataRefreshedAt = fileMetadataRefreshedAt
        self.mimeType = mimeType
    }
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
    public static let driveAvailabilityDidChangeNotification = Notification.Name(
        "ReaderFileManager.driveAvailabilityDidChange"
    )

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

    private struct RefreshMetadataIdentity: Hashable {
        let realmConfiguration: String
        let localDriveRoot: String?
        let cloudDriveRoot: String?
        let cloudContainerIdentifier: String?
    }

    private struct PostprocessorSourceGeneration: Equatable, Sendable {
        let modifiedAt: Date?
        let fileSize: Int64

        var isComplete: Bool {
            modifiedAt != nil && fileSize >= 0
        }
    }

    private struct LegacyRootRelocationReceiptSnapshot: Sendable {
        let receiptIdentifier: String
        let sourceRelativePath: String
        let sourceReaderBackingURLString: String
        let sourceContentFilePrimaryKey: String
        let sourceContentFileCreatedAt: Date
        let sourceModifiedAt: Date?
        let sourceFileSize: Int64
        let targetReaderURLString: String
        let targetContentFilePrimaryKey: String
        let targetContentFileCreatedAt: Date
        let targetModifiedAt: Date?
        let targetFileSize: Int64

        init(_ receipt: ReaderFileLegacyRootRelocationReceipt) {
            receiptIdentifier = receipt.receiptIdentifier
            sourceRelativePath = receipt.sourceRelativePath
            sourceReaderBackingURLString = receipt.sourceReaderBackingURLString
            sourceContentFilePrimaryKey = receipt.sourceContentFilePrimaryKey
            sourceContentFileCreatedAt = receipt.sourceContentFileCreatedAt
            sourceModifiedAt = receipt.sourceModifiedAt
            sourceFileSize = receipt.sourceFileSize
            targetReaderURLString = receipt.targetReaderURLString
            targetContentFilePrimaryKey = receipt.targetContentFilePrimaryKey
            targetContentFileCreatedAt = receipt.targetContentFileCreatedAt
            targetModifiedAt = receipt.targetModifiedAt
            targetFileSize = receipt.targetFileSize
        }
    }

    @RealmBackgroundActor
    private struct PostprocessorCandidate {
        let contentFile: ContentFile
        let absoluteFileURL: URL
        let sourceGeneration: PostprocessorSourceGeneration
    }

    /// A complete inventory is valid only until the next drive observation. The
    /// receipt is intentionally separate from `RefreshMetadataIdentity`: a
    /// changed inventory must make the in-flight scan retry, rather than run a
    /// second concurrent scan for the same drive roots.
    private final class DriveInventoryGeneration: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0

        @MainActor
        func advance() {
            lock.lock()
            value &+= 1
            lock.unlock()
        }

        func receipt() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func isCurrent(_ receipt: UInt64) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return value == receipt
        }

        /// Holding the receipt lock through the synchronous Realm write keeps a
        /// drive-change notification from admitting a replacement inventory in
        /// the middle of an orphan-tombstone transaction.
        func mutateIfCurrent(
            _ receipt: UInt64,
            mutation: () throws -> Void
        ) throws {
            lock.lock()
            defer { lock.unlock() }
            guard value == receipt else {
                throw ReaderFileManagerError.refreshSuperseded
            }
            try mutation()
        }
    }

    private let processorRegistry = ReaderFileProcessorRegistry()
    @TaskLocal private static var operationProcessorSnapshot: ReaderFileProcessorOperationSnapshot?

    public static var fileDestinationProcessors: [(URL) async throws -> RootRelativePath?] {
        get { shared.processorRegistry.snapshot().destinationProcessors }
        set { shared.processorRegistry.replaceDestinationProcessors(newValue) }
    }

    public static var readerFileURLProcessors: [@RealmBackgroundActor (URL, String) async throws -> URL?] {
        get { shared.processorRegistry.snapshot().readerFileURLProcessors }
        set { shared.processorRegistry.replaceReaderFileURLProcessors(newValue) }
    }

    public static var fileProcessors: [@RealmBackgroundActor ([ContentFile]) async throws -> Void] {
        get {
            let readerFileManager = shared
            return readerFileManager.processorRegistry.snapshot().filePostprocessors.map { registration in
                { @RealmBackgroundActor contentFiles in
                    let realm: Realm
                    let realmConfiguration: Realm.Configuration
                    if let contentRealm = contentFiles.first?.realm {
                        realm = contentRealm
                        realmConfiguration = contentRealm.configuration
                    } else {
                        realmConfiguration = readerFileManager.resolvedHistoryRealmConfiguration
                        realm = try await RealmBackgroundActor.shared.cachedRealm(
                            for: realmConfiguration
                        )
                    }
                    try await registration.processor(ReaderFilePostprocessorContext(
                        readerFileManager: readerFileManager,
                        realmConfiguration: realmConfiguration,
                        realm: realm,
                        contentFiles: contentFiles
                    ))
                }
            }
        }
        set {
            shared.processorRegistry.replaceFilePostprocessors(newValue.map { processor in
                { context in
                    try await processor(context.contentFiles)
                }
            })
        }
    }

    public static func registerFileDestinationProcessor(
        identifier: String,
        processor: @escaping (URL) async throws -> RootRelativePath?
    ) {
        shared.processorRegistry.registerDestinationProcessor(
            identifier: identifier,
            processor: processor
        )
    }

    public static func registerReaderFileURLProcessor(
        identifier: String,
        processor: @escaping @RealmBackgroundActor (URL, String) async throws -> URL?
    ) {
        shared.processorRegistry.registerReaderFileURLProcessor(
            identifier: identifier,
            processor: processor
        )
    }

    public static func registerFileProcessor(
        identifier: String,
        processor: @escaping @RealmBackgroundActor ([ContentFile]) async throws -> Void
    ) {
        shared.processorRegistry.registerFilePostprocessor(
            identifier: identifier,
            version: nil,
            processor: { context in
                try await processor(context.contentFiles)
            }
        )
    }

    public static func registerFileProcessor(
        identifier: String,
        version: Int64,
        processor: @escaping @RealmBackgroundActor ([ContentFile]) async throws -> Void
    ) {
        precondition(version > 0, "A durable file processor version must be positive")
        shared.processorRegistry.registerFilePostprocessor(
            identifier: identifier,
            version: version,
            processor: { context in
                try await processor(context.contentFiles)
            }
        )
    }

    public static func registerFileProcessorBundle(
        identifier: String,
        readerContentMimeTypes: [UTType] = [],
        destinationProcessor: @escaping (URL) async throws -> RootRelativePath?,
        readerFileURLProcessor: @escaping @RealmBackgroundActor (URL, String) async throws -> URL?,
        fileProcessor: @escaping @RealmBackgroundActor ([ContentFile]) async throws -> Void
    ) {
        shared.registerFileProcessorBundle(
            identifier: identifier,
            readerContentMimeTypes: readerContentMimeTypes,
            destinationProcessor: destinationProcessor,
            readerFileURLProcessor: readerFileURLProcessor,
            fileProcessor: fileProcessor
        )
    }

    public func registerFileProcessorBundle(
        identifier: String,
        readerContentMimeTypes: [UTType] = [],
        destinationProcessor: @escaping (URL) async throws -> RootRelativePath?,
        readerFileURLProcessor: @escaping @RealmBackgroundActor (URL, String) async throws -> URL?,
        fileProcessor: @escaping @RealmBackgroundActor ([ContentFile]) async throws -> Void
    ) {
        registerFileProcessorBundle(
            identifier: identifier,
            readerContentMimeTypes: readerContentMimeTypes,
            destinationProcessor: destinationProcessor,
            readerFileURLProcessor: readerFileURLProcessor,
            contextualFileProcessor: { context in
                try await fileProcessor(context.contentFiles)
            }
        )
    }

    public func registerFileProcessorBundle(
        identifier: String,
        readerContentMimeTypes: [UTType] = [],
        destinationProcessor: @escaping (URL) async throws -> RootRelativePath?,
        readerFileURLProcessor: @escaping @RealmBackgroundActor (URL, String) async throws -> URL?,
        contextualFileProcessor: @escaping @RealmBackgroundActor (ReaderFilePostprocessorContext) async throws -> Void
    ) {
        processorRegistry.registerProcessorBundle(
            identifier: identifier,
            fileProcessorVersion: nil,
            readerContentMimeTypes: readerContentMimeTypes,
            destinationProcessor: destinationProcessor,
            readerFileURLProcessor: readerFileURLProcessor,
            filePostprocessor: contextualFileProcessor
        )
    }

    public func registerFileProcessorBundle(
        identifier: String,
        fileProcessorVersion: Int64,
        readerContentMimeTypes: [UTType] = [],
        destinationProcessor: @escaping (URL) async throws -> RootRelativePath?,
        readerFileURLProcessor: @escaping @RealmBackgroundActor (URL, String) async throws -> URL?,
        contextualFileProcessor: @escaping @RealmBackgroundActor (ReaderFilePostprocessorContext) async throws -> Void
    ) {
        precondition(fileProcessorVersion > 0, "A durable file processor version must be positive")
        processorRegistry.registerProcessorBundle(
            identifier: identifier,
            fileProcessorVersion: fileProcessorVersion,
            readerContentMimeTypes: readerContentMimeTypes,
            destinationProcessor: destinationProcessor,
            readerFileURLProcessor: readerFileURLProcessor,
            filePostprocessor: contextualFileProcessor
        )
    }
    
    nonisolated(unsafe) public static var shared = ReaderFileManager()

    /// Keeps isolated import/index tests and callers on one content Realm.
    var historyRealmConfigurationOverride: Realm.Configuration?

    private let defaultLocalRootURLProvider: @Sendable () -> URL
    private let allowsCloudDrive: Bool
    private let sourceAccess: ReaderFileSourceAccess
    private let availabilityAccess: ReaderFileAvailabilityAccess

    private static var systemAvailabilityAccess: ReaderFileAvailabilityAccess {
        ReaderFileAvailabilityAccess(
            payloadState: { try payloadState(at: $0) },
            startDownloading: {
                try FileManager.default.startDownloadingUbiquitousItem(at: $0)
            },
            canCoordinateRead: { try await canCoordinateRead(rootURL: $0) }
        )
    }

    public init() {
        defaultLocalRootURLProvider = { Self.getDocumentsDirectory() }
        allowsCloudDrive = true
        sourceAccess = .securityScoped
        availabilityAccess = Self.systemAvailabilityAccess
    }

    /// Creates a file manager whose imports and reads remain below one local
    /// root and never attach the user's iCloud Drive container.
    public init(isolatedLocalRootURL: URL) {
        let standardizedRootURL = isolatedLocalRootURL.standardizedFileURL
        defaultLocalRootURLProvider = { standardizedRootURL }
        allowsCloudDrive = false
        sourceAccess = .securityScoped
        availabilityAccess = Self.systemAvailabilityAccess
    }

    init(
        defaultLocalRootURLProvider: @escaping @Sendable () -> URL,
        sourceAccess: ReaderFileSourceAccess = .securityScoped,
        availabilityAccess: ReaderFileAvailabilityAccess? = nil
    ) {
        self.defaultLocalRootURLProvider = defaultLocalRootURLProvider
        allowsCloudDrive = true
        self.sourceAccess = sourceAccess
        self.availabilityAccess = availabilityAccess ?? Self.systemAvailabilityAccess
    }

    private var resolvedHistoryRealmConfiguration: Realm.Configuration {
        historyRealmConfigurationOverride ?? ReaderContentLoader.historyRealmConfiguration
    }

    @MainActor
    private func refreshMetadataIdentity(
        for realmConfiguration: Realm.Configuration
    ) -> RefreshMetadataIdentity {
        RefreshMetadataIdentity(
            realmConfiguration: Self.realmConfigurationIdentity(realmConfiguration),
            localDriveRoot: localDrive?.rootDirectory.standardizedFileURL.absoluteString,
            cloudDriveRoot: cloudDrive?.rootDirectory.standardizedFileURL.absoluteString,
            cloudContainerIdentifier: cloudDrive?.ubiquityContainerIdentifier
        )
    }

    private static func realmConfigurationIdentity(_ configuration: Realm.Configuration) -> String {
        if let fileURL = configuration.fileURL {
            return "file:\(fileURL.standardizedFileURL.absoluteString)"
        }
        if let inMemoryIdentifier = configuration.inMemoryIdentifier {
            return "memory:\(inMemoryIdentifier)"
        }
        return "default"
    }
    
    public var readerContentMimeTypes: [UTType] {
        get { processorRegistry.snapshot().readerContentMimeTypes }
        set { processorRegistry.replaceReaderContentMimeTypes(newValue) }
    }
    
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
    
    @MainActor private var refreshAllFilesMetadataTasks = [RefreshMetadataIdentity: Task<Void, any Swift.Error>]()
    @MainActor private var lastRefreshAllFilesMetadataStartedAt = [RefreshMetadataIdentity: Date]()
    @MainActor private var refreshAllFilesMetadataNeedsFollowUp = Set<RefreshMetadataIdentity>()
    private let driveInventoryGeneration = DriveInventoryGeneration()
    private static let refreshAllFilesMetadataDebounceInterval: TimeInterval = 2

    private static let internalStorageRootPrefixes: Set<String> = [
        "manabi-caches",
        "manabi-dictionaries",
        "manabi-dictionary-assets",
        "manabi-fonts",
    ]
    private static let predownloadStagingRootPrefix = "ReaderFileDownload."
    private static let transientRootPrefixes: Set<String> = [
        predownloadStagingRootPrefix,
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
        if allowsCloudDrive {
            cloudDrive = try? await CloudDrive(
                ubiquityContainerIdentifier: ubiquityContainerIdentifier,
                relativePathToRootInContainer: "Documents"
            )
        } else {
            cloudDrive = nil
        }
        cloudDrive?.observer = self
        //        legacyCloudDrive = try? await CloudDrive(ubiquityContainerIdentifier: ubiquityContainerIdentifier, relativePathToRootInContainer: "")
        let localRootURL = defaultLocalRootURLProvider()
        if allowsCloudDrive {
            localDrive = try? await CloudDrive(storage: .localDirectory(rootURL: localRootURL))
        } else {
            try FileManager.default.createDirectory(
                at: localRootURL,
                withIntermediateDirectories: true
            )
            localDrive = try await CloudDrive(storage: .localDirectory(rootURL: localRootURL))
        }
        localDrive?.observer = self
        NotificationCenter.default.post(name: Self.driveAvailabilityDidChangeNotification, object: self)
        Task { [weak self] in
            try await self?.refreshAllFilesMetadata()
        }
    }
    
    @MainActor
    public func appSuspendedDidChange(isSuspended: Bool) {
        if isSuspended {
            for task in refreshAllFilesMetadataTasks.values {
                task.cancel()
            }
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
        let realmConfiguration = resolvedHistoryRealmConfiguration
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
            try await markDeleted(
                contentURL: contentURL,
                realmConfiguration: realmConfiguration
            )
            await removeDeletedFileFromPublishedFiles(matching: readerBackingURL)
            Task { @MainActor [weak self] in
                try await self?.refreshAllFilesMetadata(
                    force: true,
                    realmConfiguration: realmConfiguration
                )
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
        try await markDeleted(
            contentURL: contentURL,
            realmConfiguration: realmConfiguration
        )
        await removeDeletedFileFromPublishedFiles(matching: readerBackingURL)
        Task { @MainActor [weak self] in
            try await self?.refreshAllFilesMetadata(
                force: true,
                realmConfiguration: realmConfiguration
            )
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

    /// Resolves ordinary-file response metadata from this manager's exact Realm destination.
    /// Only detached values leave `RealmBackgroundActor`.
    public func readerFileDocumentMetadataSnapshot(
        for fileURL: URL
    ) async throws -> ReaderFileDocumentMetadataSnapshot? {
        guard !Self.isInternalStorageReaderFileURL(fileURL) else { return nil }
        let realmConfiguration = resolvedHistoryRealmConfiguration
        return try await Self.readerFileDocumentMetadataSnapshot(
            for: fileURL,
            realmConfiguration: realmConfiguration
        )
    }

    @RealmBackgroundActor
    private static func readerFileDocumentMetadataSnapshot(
        for fileURL: URL,
        realmConfiguration: Realm.Configuration
    ) async throws -> ReaderFileDocumentMetadataSnapshot? {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
        try await realm.asyncRefresh()
        guard let contentFile = realm.objects(ContentFile.self)
            .filter(
                NSPredicate(
                    format: "isDeleted == %@ AND url == %@",
                    NSNumber(booleanLiteral: false),
                    fileURL.absoluteString as CVarArg
                )
            )
            .first else {
            return nil
        }
        return ReaderFileDocumentMetadataSnapshot(
            storeIdentity: BookmarkStoreIdentity(realmConfiguration: realmConfiguration),
            contentFilePrimaryKey: contentFile.compoundKey,
            sourceURL: contentFile.url,
            createdAt: contentFile.createdAt,
            modifiedAt: contentFile.modifiedAt,
            fileMetadataRefreshedAt: contentFile.fileMetadataRefreshedAt,
            mimeType: contentFile.mimeType
        )
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
        try await readerFileURL(
            for: downloadable.localDestination,
            drive: nil,
            processorSnapshot: processorRegistry.snapshot()
        )
    }
    
    @MainActor
    public func readerFileURL(for fileURL: URL, drive: CloudDrive? = nil) async throws -> URL? {
        try await readerFileURL(
            for: fileURL,
            drive: drive,
            processorSnapshot: processorRegistry.snapshot()
        )
    }

    @MainActor
    private func readerFileURL(
        for fileURL: URL,
        drive: CloudDrive?,
        processorSnapshot: ReaderFileProcessorRegistrySnapshot
    ) async throws -> URL? {
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
            if let encodedPath = "\(drive.ubiquityContainerIdentifier == nil ? "local" : "icloud")/\(normalizedPath)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
               let fallbackURL = URL(string: "reader-file://file/load/" + encodedPath) {
                var selectedProcessorURL: URL?
                for readerFileURLProcessor in processorSnapshot.readerFileURLProcessors {
                    guard let candidateURL = try await readerFileURLProcessor(
                        fileURL,
                        encodedPath
                    ) else {
                        continue
                    }
                    let validatedURL = try validatedReaderFileURL(
                        candidateURL,
                        expectedBackingURL: fallbackURL
                    )
                    if let selectedProcessorURL,
                       selectedProcessorURL != validatedURL {
                        throw ReaderFileManagerError.ambiguousReaderFileURL
                    }
                    selectedProcessorURL = validatedURL
                }
                return selectedProcessorURL ?? fallbackURL
            }
        }
        return nil
    }

    private func validatedReaderFileURL(
        _ candidateURL: URL,
        expectedBackingURL: URL
    ) throws -> URL {
        guard let components = URLComponents(
            url: candidateURL,
            resolvingAgainstBaseURL: false
        ),
        components.query == nil,
        components.fragment == nil,
        canonicalReaderBackingURL(for: candidateURL) == expectedBackingURL else {
            throw ReaderFileManagerError.invalidReaderFileURL
        }
        return candidateURL
    }

    @MainActor
    public func ensureImported(downloadable: Downloadable) async throws -> URL? {
        let realmConfiguration = resolvedHistoryRealmConfiguration
        let processorSnapshot = processorRegistry.snapshot()
        if try await drainLegacyRootRelocationReceipts(
            realmConfiguration: realmConfiguration
        ) {
            // A completed recovery removes a physical root file. Reconcile it
            // before looking up an existing download so it cannot be indexed
            // again from a stale published inventory.
            try await refreshAllFilesMetadata(
                force: true,
                realmConfiguration: realmConfiguration,
                processorSnapshot: processorSnapshot
            )
        }
        guard await downloadable.existsLocally() else { return nil }
        if let existingReaderURL = try await readerFileURL(
            for: downloadable.localDestination,
            drive: nil,
            processorSnapshot: processorSnapshot
        ),
           !isInternalStorageFileURL(downloadable.localDestination) {
            if let relocatedReaderURL = try await relocateLegacyRootDownloadIfNeeded(
                sourceURL: downloadable.localDestination,
                sourceReaderURL: existingReaderURL,
                realmConfiguration: realmConfiguration,
                processorSnapshot: processorSnapshot
            ) {
                return relocatedReaderURL
            }
            try await refreshMetadataForExistingLibraryFile(
                downloadable.localDestination,
                realmConfiguration: realmConfiguration,
                processorSnapshot: processorSnapshot
            )
            return existingReaderURL
        }
        return try await importFile(
            fileURL: downloadable.localDestination,
            realmConfiguration: realmConfiguration,
            processorSnapshot: processorSnapshot
        )
    }

    /// Moves only the old downloader shape: one normal file immediately below
    /// a connected drive root. The captured processor snapshot determines both
    /// the classification and the reader URL used for the target postimage.
    @MainActor
    private func relocateLegacyRootDownloadIfNeeded(
        sourceURL: URL,
        sourceReaderURL: URL,
        realmConfiguration: Realm.Configuration,
        processorSnapshot: ReaderFileProcessorRegistrySnapshot
    ) async throws -> URL? {
        guard let drive = [localDrive, cloudDrive]
            .compactMap({ $0 })
            .first(where: { drive in
                guard drive.isConnected,
                      let relative = Self.relativePath(
                        for: sourceURL,
                        relativeTo: drive.rootDirectory
                      ) else {
                    return false
                }
                let normalized = relative.hasPrefix("./")
                    ? String(relative.dropFirst(2))
                    : relative
                return normalized.split(separator: "/").count == 1
                    && !Self.shouldSkipDiscoveredRelativePath(normalized)
            }) else {
            return nil
        }
        guard let sourceRelativePathString = Self.relativePath(
            for: sourceURL,
            relativeTo: drive.rootDirectory
        ) else {
            return nil
        }
        let sourceRelativePath = RootRelativePath(
            path: sourceRelativePathString.hasPrefix("./")
                ? String(sourceRelativePathString.dropFirst(2))
                : sourceRelativePathString
        )
        guard sourceRelativePath.path.split(separator: "/").count == 1 else {
            return nil
        }
        let destinationDirectory = try await Self.rootRelativePath(
            forClassificationCandidateURL: sourceURL,
            drive: drive,
            processorSnapshot: processorSnapshot
        )
        guard !destinationDirectory.path.isEmpty else { return nil }
        let requestedTargetPath = destinationDirectory.appending(sourceURL.lastPathComponent)
        guard requestedTargetPath != sourceRelativePath else { return nil }
        guard try await supportsLegacyRootRelocationReceipts(
            realmConfiguration: realmConfiguration
        ) else {
            return nil
        }

        let sourceGeneration = Self.postprocessorSourceGeneration(at: sourceURL)
        guard sourceGeneration.isComplete else { return nil }
        guard let sourceReaderBackingURL = canonicalReaderBackingURL(for: sourceReaderURL) else {
            return nil
        }

        // Index the root source before any copy. A fresh old download has no
        // existing ContentFile row, and the later tombstone must identify one
        // exact live synchronized record rather than inventing it after copy.
        let sourceReferences = try await refreshFilesMetadata(
            drive: drive,
            relativePath: .root,
            realmConfiguration: realmConfiguration,
            processorSnapshot: processorSnapshot
        ) ?? []
        try await publishDiscoveredFiles(
            sourceReferences,
            realmConfiguration: realmConfiguration
        )

        // importFile preserves its collision hashing. Its return value is the
        // exact target chosen after that collision resolution, never merely the
        // requested destination path.
        guard let targetReaderURL = try await importFile(
            fileURL: sourceURL,
            realmConfiguration: realmConfiguration,
            processorSnapshot: processorSnapshot
        ) else {
            return nil
        }
        guard let targetReaderBackingURL = canonicalReaderBackingURL(
            for: targetReaderURL
        ) else {
            return targetReaderURL
        }
        let targetRelativePath = try Self.extractRelativePath(
            fileURL: targetReaderBackingURL
        )
        let targetURL = try targetRelativePath.fileURL(forRoot: drive.rootDirectory)
        let targetGeneration = Self.postprocessorSourceGeneration(at: targetURL)
        guard targetGeneration.isComplete else { return targetReaderURL }
        let storageScopeIdentifier = Self.postprocessorStorageScopeIdentifier(
            drive: drive,
            realmConfiguration: realmConfiguration
        )
        let receiptIdentifier = try await admitLegacyRootRelocationReceipt(
            storageScopeIdentifier: storageScopeIdentifier,
            sourceRelativePath: sourceRelativePath,
            sourceReaderURL: sourceReaderURL,
            sourceReaderBackingURL: sourceReaderBackingURL,
            sourceGeneration: sourceGeneration,
            targetReaderURL: targetReaderURL,
            targetGeneration: targetGeneration,
            targetURL: targetURL,
            sourceURL: sourceURL,
            realmConfiguration: realmConfiguration
        )
        guard let receiptIdentifier else {
            // The source changed while the target was being installed or the
            // target could not be proven to be the indexed postimage. Retain
            // both user-visible bytes and let a later download decide anew.
            return targetReaderURL
        }
        do {
            try await drive.removeFile(at: sourceRelativePath)
        } catch {
            // The committed receipt is the recovery owner; a failed removal
            // deliberately leaves the soft tombstone and receipt intact.
            return targetReaderURL
        }
        guard !(try await drive.fileExists(at: sourceRelativePath)) else {
            return targetReaderURL
        }
        try await removeLegacyRootRelocationReceipt(
            receiptIdentifier,
            realmConfiguration: realmConfiguration
        )
        try await refreshAllFilesMetadata(
            force: true,
            realmConfiguration: realmConfiguration,
            processorSnapshot: processorSnapshot
        )
        return targetReaderURL
    }

    @RealmBackgroundActor
    private func supportsLegacyRootRelocationReceipts(
        realmConfiguration: Realm.Configuration
    ) async throws -> Bool {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: realmConfiguration
        )
        return realm.schema.objectSchema.contains(where: {
            $0.className == ReaderFileLegacyRootRelocationReceipt.className()
        })
    }

    @RealmBackgroundActor
    private func admitLegacyRootRelocationReceipt(
        storageScopeIdentifier: String,
        sourceRelativePath: RootRelativePath,
        sourceReaderURL: URL,
        sourceReaderBackingURL: URL,
        sourceGeneration: PostprocessorSourceGeneration,
        targetReaderURL: URL,
        targetGeneration: PostprocessorSourceGeneration,
        targetURL: URL,
        sourceURL: URL,
        realmConfiguration: Realm.Configuration
    ) async throws -> String? {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: realmConfiguration
        )
        let sourceURLString = sourceReaderURL.absoluteString
        let targetURLString = targetReaderURL.absoluteString
        let sourceBackingURLString = sourceReaderBackingURL.absoluteString
        return try await realm.asyncWrite {
            guard Self.postprocessorSourceGeneration(at: sourceURL) == sourceGeneration,
                  Self.postprocessorSourceGeneration(at: targetURL) == targetGeneration,
                  let source = realm.objects(ContentFile.self)
                    .filter(NSPredicate(
                        format: "isDeleted == %@ AND url == %@",
                        NSNumber(booleanLiteral: false),
                        sourceURLString as CVarArg
                    ))
                    .first,
                  let target = realm.objects(ContentFile.self)
                    .filter(NSPredicate(
                        format: "isDeleted == %@ AND url == %@",
                        NSNumber(booleanLiteral: false),
                        targetURLString as CVarArg
                    ))
                    .first,
                  source.compoundKey != target.compoundKey else {
                return nil
            }
            let receiptIdentifier = ReaderFileLegacyRootRelocationReceipt
                .makeReceiptIdentifier(
                    storageScopeIdentifier: storageScopeIdentifier,
                    sourceRelativePath: sourceRelativePath.path,
                    sourceContentFilePrimaryKey: source.compoundKey
                )
            let receipt = realm.object(
                ofType: ReaderFileLegacyRootRelocationReceipt.self,
                forPrimaryKey: receiptIdentifier
            ) ?? ReaderFileLegacyRootRelocationReceipt()
            receipt.receiptIdentifier = receiptIdentifier
            receipt.storageScopeIdentifier = storageScopeIdentifier
            receipt.sourceRelativePath = sourceRelativePath.path
            receipt.sourceReaderBackingURLString = sourceBackingURLString
            receipt.sourceContentFilePrimaryKey = source.compoundKey
            receipt.sourceContentFileCreatedAt = source.createdAt
            receipt.sourceModifiedAt = sourceGeneration.modifiedAt
            receipt.sourceFileSize = sourceGeneration.fileSize
            receipt.targetReaderURLString = targetURLString
            receipt.targetContentFilePrimaryKey = target.compoundKey
            receipt.targetContentFileCreatedAt = target.createdAt
            receipt.targetModifiedAt = targetGeneration.modifiedAt
            receipt.targetFileSize = targetGeneration.fileSize
            receipt.createdAt = Date()
            if receipt.realm == nil {
                realm.add(receipt)
            }

            // This is the synchronized half of relocation. Do not alter the
            // local receipt's metadata or pending-mutation rows by hand.
            source.isDeleted = true
            source.refreshChangeMetadata(explicitlyModified: true)
            return receiptIdentifier
        }
    }

    @RealmBackgroundActor
    private func removeLegacyRootRelocationReceipt(
        _ receiptIdentifier: String,
        realmConfiguration: Realm.Configuration
    ) async throws {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: realmConfiguration
        )
        try await realm.asyncWrite {
            guard let receipt = realm.object(
                ofType: ReaderFileLegacyRootRelocationReceipt.self,
                forPrimaryKey: receiptIdentifier
            ) else {
                return
            }
            realm.delete(receipt)
        }
    }

    /// Retries only receipts whose indexed target and tombstoned source still
    /// describe the exact generation captured at relocation time. A changed
    /// source or target remains recoverable evidence and is never deleted.
    @MainActor
    private func drainLegacyRootRelocationReceipts(
        realmConfiguration: Realm.Configuration
    ) async throws -> Bool {
        var removedAnySource = false
        for drive in [localDrive, cloudDrive].compactMap({ $0 }).filter(\.isConnected) {
            let storageScopeIdentifier = Self.postprocessorStorageScopeIdentifier(
                drive: drive,
                realmConfiguration: realmConfiguration
            )
            let receipts = try await legacyRootRelocationReceiptSnapshots(
                storageScopeIdentifier: storageScopeIdentifier,
                realmConfiguration: realmConfiguration
            )
            for receipt in receipts {
                guard let sourceRelativePath = Self.validLegacyRootSourcePath(
                    receipt.sourceRelativePath
                ),
                let sourceBackingURL = URL(
                    string: receipt.sourceReaderBackingURLString
                ),
                let expectedSourceURL = try? sourceRelativePath.fileURL(
                    forRoot: drive.rootDirectory
                ),
                let receiptSourceURL = try? validatedReceiptSourceURL(
                    sourceBackingURL: sourceBackingURL,
                    sourceRelativePath: sourceRelativePath,
                    drive: drive
                ),
                receiptSourceURL == expectedSourceURL,
                try await legacyRootRelocationReceiptStillMatches(
                    receipt,
                    sourceURL: try sourceRelativePath.fileURL(forRoot: drive.rootDirectory),
                    targetURL: try receiptTargetURL(receipt, drive: drive),
                    realmConfiguration: realmConfiguration
                ) else {
                    continue
                }
                let sourceExists = try await drive.fileExists(at: sourceRelativePath)
                if sourceExists {
                    do {
                        try await drive.removeFile(at: sourceRelativePath)
                    } catch {
                        continue
                    }
                }
                guard !(try await drive.fileExists(at: sourceRelativePath)) else {
                    continue
                }
                try await removeLegacyRootRelocationReceipt(
                    receipt.receiptIdentifier,
                    realmConfiguration: realmConfiguration
                )
                removedAnySource = true
            }
        }
        return removedAnySource
    }

    @MainActor
    private func validatedReceiptSourceURL(
        sourceBackingURL: URL,
        sourceRelativePath: RootRelativePath,
        drive: CloudDrive
    ) throws -> URL {
        guard canonicalReaderBackingURL(for: sourceBackingURL) == sourceBackingURL,
              try Self.extractRelativePath(fileURL: sourceBackingURL) == sourceRelativePath,
              let (receiptDrive, _) = try? extractCloudDrivePath(
                fromReaderFileURL: sourceBackingURL
              ),
              receiptDrive.rootDirectory.standardizedFileURL
                == drive.rootDirectory.standardizedFileURL else {
            throw ReaderFileManagerError.invalidFileURL
        }
        return try sourceRelativePath.fileURL(forRoot: drive.rootDirectory)
    }

    @MainActor
    private func receiptTargetURL(
        _ receipt: LegacyRootRelocationReceiptSnapshot,
        drive: CloudDrive
    ) throws -> URL {
        guard let targetReaderURL = URL(string: receipt.targetReaderURLString),
              let targetBackingURL = canonicalReaderBackingURL(for: targetReaderURL),
              let (receiptDrive, targetRelativePath) = try? extractCloudDrivePath(
                fromReaderFileURL: targetBackingURL
              ),
              receiptDrive.rootDirectory.standardizedFileURL
                == drive.rootDirectory.standardizedFileURL else {
            throw ReaderFileManagerError.invalidFileURL
        }
        return try targetRelativePath.fileURL(forRoot: drive.rootDirectory)
    }

    private static func validLegacyRootSourcePath(
        _ path: String
    ) -> RootRelativePath? {
        guard let validated = try? validatedDestinationPath(RootRelativePath(path: path)),
              validated.path.split(separator: "/").count == 1,
              !shouldSkipDiscoveredRelativePath(validated.path) else {
            return nil
        }
        return validated
    }

    @RealmBackgroundActor
    private func legacyRootRelocationReceiptSnapshots(
        storageScopeIdentifier: String,
        realmConfiguration: Realm.Configuration
    ) async throws -> [LegacyRootRelocationReceiptSnapshot] {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: realmConfiguration
        )
        guard realm.schema.objectSchema.contains(where: {
            $0.className == ReaderFileLegacyRootRelocationReceipt.className()
        }) else {
            return []
        }
        return realm.objects(ReaderFileLegacyRootRelocationReceipt.self)
            .where { $0.storageScopeIdentifier == storageScopeIdentifier }
            .map(LegacyRootRelocationReceiptSnapshot.init)
    }

    @RealmBackgroundActor
    private func legacyRootRelocationReceiptStillMatches(
        _ receipt: LegacyRootRelocationReceiptSnapshot,
        sourceURL: URL,
        targetURL: URL,
        realmConfiguration: Realm.Configuration
    ) async throws -> Bool {
        let sourceExists = FileManager.default.fileExists(atPath: sourceURL.path)
        let sourceGeneration = Self.postprocessorSourceGeneration(at: sourceURL)
        let targetGeneration = Self.postprocessorSourceGeneration(at: targetURL)
        guard (!sourceExists || (
                sourceGeneration.modifiedAt == receipt.sourceModifiedAt
                    && sourceGeneration.fileSize == receipt.sourceFileSize
              )),
              targetGeneration.modifiedAt == receipt.targetModifiedAt,
              targetGeneration.fileSize == receipt.targetFileSize else {
            return false
        }
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: realmConfiguration
        )
        guard let source = realm.object(
            ofType: ContentFile.self,
            forPrimaryKey: receipt.sourceContentFilePrimaryKey
        ),
        source.isDeleted,
        source.createdAt == receipt.sourceContentFileCreatedAt,
        canonicalReaderBackingURL(for: source.url)?.absoluteString
            == receipt.sourceReaderBackingURLString,
        let target = realm.object(
            ofType: ContentFile.self,
            forPrimaryKey: receipt.targetContentFilePrimaryKey
        ),
        !target.isDeleted,
        target.createdAt == receipt.targetContentFileCreatedAt,
        target.url.absoluteString == receipt.targetReaderURLString else {
            return false
        }
        return true
    }

    @MainActor
    private func isInternalStorageFileURL(_ fileURL: URL) -> Bool {
        [cloudDrive, localDrive]
            .compactMap { $0 }
            .filter(\.isConnected)
            .contains { drive in
                guard var relativePath = Self.relativePath(
                    for: fileURL,
                    relativeTo: drive.rootDirectory
                ) else {
                    return false
                }
                if relativePath.hasPrefix("./") {
                    relativePath = String(relativePath.dropFirst(2))
                }
                return Self.shouldSkipDiscoveredRelativePath(relativePath)
            }
    }

    @MainActor
    private func refreshMetadataForExistingLibraryFile(
        _ fileURL: URL,
        realmConfiguration: Realm.Configuration,
        processorSnapshot: ReaderFileProcessorRegistrySnapshot
    ) async throws {
        let drives = [cloudDrive, localDrive].compactMap { drive in
            drive?.isConnected == true ? drive : nil
        }
        for drive in drives {
            guard let relativePath = Self.relativePath(for: fileURL, relativeTo: drive.rootDirectory) else { continue }
            let parentPath = URL(fileURLWithPath: relativePath).deletingLastPathComponent().relativePath
            let parent = RootRelativePath(path: parentPath == "." ? "" : parentPath)
            let discoveredReferences = try await refreshFilesMetadata(
                drive: drive,
                relativePath: parent,
                realmConfiguration: realmConfiguration,
                processorSnapshot: processorSnapshot
            ) ?? []
            try await publishDiscoveredFiles(
                discoveredReferences,
                realmConfiguration: realmConfiguration
            )
            try await refreshAllFilesMetadata(
                force: true,
                realmConfiguration: realmConfiguration,
                processorSnapshot: processorSnapshot
            )
            return
        }
    }

    @MainActor
    private func publishDiscoveredFiles(
        _ references: [ThreadSafeReference<ContentFile>],
        realmConfiguration: Realm.Configuration
    ) async throws {
        guard !references.isEmpty else { return }
        let realm = try await Realm.open(configuration: realmConfiguration)
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
    
    /// Imports the readable local candidate. `downloadURL` is remote provenance
    /// only and never participates in content-based destination classification.
    @MainActor
    public func importFile(fileURL: URL, fromDownloadURL _: URL?) async throws -> URL? {
        try await importFile(
            fileURL: fileURL,
            realmConfiguration: resolvedHistoryRealmConfiguration,
            processorSnapshot: processorRegistry.snapshot()
        )
    }

    @MainActor
    private func importFile(
        fileURL: URL,
        realmConfiguration: Realm.Configuration,
        processorSnapshot: ReaderFileProcessorRegistrySnapshot
    ) async throws -> URL? {
        guard let drive = ((cloudDrive?.isConnected ?? false) ? cloudDrive : nil) ?? localDrive else { return nil }

        let shouldStopAccessingFile = try sourceAccess.start(fileURL)
        defer {
            if shouldStopAccessingFile {
                sourceAccess.stop(fileURL)
            }
        }

        let targetDirectory = try await Self.rootRelativePath(
            forLocalCandidateURL: fileURL,
            drive: drive,
            processorSnapshot: processorSnapshot
        )
        var targetFilePath = targetDirectory.appending(fileURL.lastPathComponent)
        let targetURL = try targetFilePath.directoryURL(forRoot: drive.rootDirectory)

        try Self.validateDestinationContainment(
            targetDirectory,
            in: drive.rootDirectory
        )
        try await drive.createDirectory(at: targetDirectory)

        try Self.validateDestinationContainment(
            targetFilePath,
            in: drive.rootDirectory
        )
        
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
            try Self.validateDestinationContainment(
                targetFilePath,
                in: drive.rootDirectory
            )
            try await drive.upload(from: fileURL, to: targetFilePath)
        }
        
        do {
            _ = try await refreshFilesMetadata(
                drive: drive,
                relativePath: targetDirectory,
                realmConfiguration: realmConfiguration,
                processorSnapshot: processorSnapshot
            )
            let realm = try await Realm.open(configuration: realmConfiguration)
            let importedFileURL = try targetFilePath.fileURL(forRoot: drive.rootDirectory)
            guard let importedReaderFileURL = try await readerFileURL(
                for: importedFileURL,
                drive: drive,
                processorSnapshot: processorSnapshot
            ) else {
                debugPrint("Warning: Unable to resolve reader file URL for imported file", importedFileURL)
                return nil
            }
            guard let content = realm.objects(ContentFile.self)
                .filter(NSPredicate(format: "isDeleted == %@ AND url == %@", NSNumber(booleanLiteral: false), importedReaderFileURL.absoluteString as CVarArg))
                .first else {
                debugPrint("Warning: No matching content metadata returned for imported file", importedReaderFileURL)
                return nil
            }
            try await refreshAllFilesMetadata(
                force: true,
                realmConfiguration: realmConfiguration,
                processorSnapshot: processorSnapshot
            )
            let finalRealm = try await Realm.open(configuration: realmConfiguration)
            guard let finalContent = finalRealm.object(ofType: ContentFile.self, forPrimaryKey: content.compoundKey),
                  !finalContent.isDeleted,
                  finalContent.url == importedReaderFileURL else {
                throw ReaderFileManagerError.incompleteFileInventory
            }
            return finalContent.url
        } catch {
            debugPrint("Error importing file:", error)
            throw error
        }
    }
    
    @MainActor
    public func refreshAllFilesMetadata(force: Bool = false) async throws {
        try await refreshAllFilesMetadata(
            force: force,
            realmConfiguration: resolvedHistoryRealmConfiguration,
            processorSnapshot: processorRegistry.snapshot()
        )
    }

    @MainActor
    private func refreshAllFilesMetadata(
        force: Bool,
        realmConfiguration: Realm.Configuration
    ) async throws {
        try await refreshAllFilesMetadata(
            force: force,
            realmConfiguration: realmConfiguration,
            processorSnapshot: processorRegistry.snapshot()
        )
    }

    @MainActor
    private func refreshAllFilesMetadata(
        force: Bool,
        realmConfiguration: Realm.Configuration,
        processorSnapshot: ReaderFileProcessorRegistrySnapshot
    ) async throws {
        let didDrainLegacyRootRelocation = try await drainLegacyRootRelocationReceipts(
            realmConfiguration: realmConfiguration
        )
        let force = force || didDrainLegacyRootRelocation
        let refreshIdentity = refreshMetadataIdentity(for: realmConfiguration)
        if let refreshAllFilesMetadataTask = refreshAllFilesMetadataTasks[refreshIdentity] {
            // Joiners and forced follow-ups intentionally inherit the in-flight owner's
            // processor snapshot. A replacement applies to the next independent refresh.
            if force {
                refreshAllFilesMetadataNeedsFollowUp.insert(refreshIdentity)
            }
            try await refreshAllFilesMetadataTask.value
            return
        }
        if !force,
           files != nil,
           let lastRefreshAllFilesMetadataStartedAt = lastRefreshAllFilesMetadataStartedAt[refreshIdentity],
           Date().timeIntervalSince(lastRefreshAllFilesMetadataStartedAt)
                < Self.refreshAllFilesMetadataDebounceInterval {
            return
        }

        refreshAllFilesMetadataNeedsFollowUp.remove(refreshIdentity)
        lastRefreshAllFilesMetadataStartedAt[refreshIdentity] = Date()
        let refreshTask = Task { @MainActor in
            defer {
                refreshAllFilesMetadataTasks.removeValue(forKey: refreshIdentity)
                refreshAllFilesMetadataNeedsFollowUp.remove(refreshIdentity)
            }
            repeat {
                refreshAllFilesMetadataNeedsFollowUp.remove(refreshIdentity)
                do {
                    guard localDrive != nil || cloudDrive != nil else { return }
                    let inventoryReceipt = driveInventoryGeneration.receipt()
                    let files = try await Self.$operationProcessorSnapshot.withValue(
                        ReaderFileProcessorOperationSnapshot(
                            managerIdentity: ObjectIdentifier(self),
                            processors: processorSnapshot
                        )
                    ) {
                        var files = [ThreadSafeReference<ContentFile>]()
                        for drive in [localDrive, cloudDrive].compactMap({ $0 }) {
                            try Task.checkCancellation()
                            if let discovered = try await refreshFilesMetadata(
                                drive: drive,
                                realmConfiguration: realmConfiguration
                            ) {
                                files.append(contentsOf: discovered)
                            }
                        }
                        return files
                    }

                    let discoveredFiles = files
                    try await { @MainActor [weak self] in
                        try Task.checkCancellation()
                        guard let self = self else { return }
                        guard self.refreshMetadataIdentity(for: realmConfiguration) == refreshIdentity,
                              Self.realmConfigurationIdentity(self.resolvedHistoryRealmConfiguration)
                                == refreshIdentity.realmConfiguration,
                              self.driveInventoryGeneration.isCurrent(inventoryReceipt) else {
                            throw ReaderFileManagerError.refreshSuperseded
                        }
                        let realm = try await Realm.open(configuration: realmConfiguration)
                        let files = try discoveredFiles.compactMap {
                            try Task.checkCancellation()
                            return realm.resolve($0)
                        }
                        self.files = files
                        let discoveredURLs = try files.map {
                            try Task.checkCancellation()
                            return $0.url
                        }

                        // Delete orphans (objects with no corresponding file on disk)
                        try await { @RealmBackgroundActor in
                            try Task.checkCancellation()
                            guard await MainActor.run(body: {
                                self.refreshMetadataIdentity(for: realmConfiguration) == refreshIdentity
                                    && self.driveInventoryGeneration.isCurrent(inventoryReceipt)
                            }) else {
                                throw ReaderFileManagerError.refreshSuperseded
                            }
                            let realm = try await RealmBackgroundActor.shared.cachedRealm(
                                for: realmConfiguration
                            )
                            let existingURLs = try discoveredURLs.map {
                                try Task.checkCancellation()
                                return $0.absoluteString
                            }
                            let orphans = realm.objects(ContentFile.self).filter(NSPredicate(format: "isDeleted == %@ AND NOT (url IN %@)", NSNumber(booleanLiteral: false), existingURLs))
                            //await realm.asyncRefresh()
                            try await realm.asyncWrite {
                                try self.driveInventoryGeneration.mutateIfCurrent(inventoryReceipt) {
                                    let orphanPrimaryKeys = Array(orphans.map(\.compoundKey))
                                    for orphan in orphans {
                                        try Task.checkCancellation()
                                        orphan.isDeleted = true
                                        orphan.refreshChangeMetadata(explicitlyModified: true)
                                    }
                                    Self.deletePostprocessingWorkItems(
                                        contentFilePrimaryKeys: orphanPrimaryKeys,
                                        in: realm
                                    )
                                }
                            }
                        }()
                    }()
                } catch ReaderFileManagerError.refreshSuperseded
                    where refreshAllFilesMetadataNeedsFollowUp.contains(refreshIdentity)
                        && !Task.isCancelled {
                    continue
                } catch {
                    if !(error is CancellationError) {
                        Logger.shared.logger.error("\(error)")
                    }
                    throw error
                }
            } while refreshAllFilesMetadataNeedsFollowUp.contains(refreshIdentity) && !Task.isCancelled
        }
        refreshAllFilesMetadataTasks[refreshIdentity] = refreshTask
        try await refreshTask.value
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
        let processorSnapshot: ReaderFileProcessorRegistrySnapshot
        if let operationSnapshot = Self.operationProcessorSnapshot,
           operationSnapshot.managerIdentity == ObjectIdentifier(self) {
            processorSnapshot = operationSnapshot.processors
        } else {
            processorSnapshot = processorRegistry.snapshot()
        }
        return try await refreshFilesMetadata(
            drive: drive,
            relativePath: relativePath,
            realmConfiguration: realmConfiguration,
            processorSnapshot: processorSnapshot
        )
    }

    @MainActor
    private func refreshFilesMetadata(
        drive: CloudDrive,
        relativePath: RootRelativePath?,
        realmConfiguration: Realm.Configuration?,
        processorSnapshot: ReaderFileProcessorRegistrySnapshot
    ) async throws -> [ThreadSafeReference<ContentFile>]? {
        let realmConfiguration = realmConfiguration ?? resolvedHistoryRealmConfiguration
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
                            stage: "discovery.incompleteMissing",
                            path: tryRelativePath.path,
                            reason: "disappearedDuringRefresh"
                        )
                        throw ReaderFileManagerError.incompleteFileInventory
                    }
                    throw error
                }
                if !url.isFilePackage(),
                   !Self.additionalFilePackageSuffixesToAvoidDescendingInto.contains(where: { lastPathComponent.hasSuffix($0) }),
                   isDirectory {
                    let discoveredFiles = try await refreshFilesMetadata(
                        drive: drive,
                        relativePath: tryRelativePath,
                        realmConfiguration: realmConfiguration,
                        processorSnapshot: processorSnapshot
                    )
                    files.append(contentsOf: discoveredFiles ?? [])
                } else {
                    let indexDecision = contentFileIndexDecision(
                        at: absoluteFileURL,
                        processorSnapshot: processorSnapshot
                    )
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
                        drive: drive,
                        processorSnapshot: processorSnapshot
                    ) {
                        filesToUpdate.append((readerFileURL, absoluteFileURL))
                    }
                }
            }
        } catch {
            if Self.isMissingFileError(error) {
                Self.logContentFileDecision(
                    stage: "discovery.incompleteMissingDirectory",
                    path: relativePath?.path ?? "",
                    reason: "disappearedDuringRefresh"
                )
                throw ReaderFileManagerError.incompleteFileInventory
            }
            if !(error is CancellationError) {
                debugPrint("refreshFilesMetadata error:", error)
            }
            throw error
        }

        if !filesToUpdate.isEmpty {
            let pendingFilesToUpdate = filesToUpdate
            let storageScopeIdentifier = Self.postprocessorStorageScopeIdentifier(
                drive: drive,
                realmConfiguration: realmConfiguration
            )
            let updatedFiles = try await { @RealmBackgroundActor in
                var updatedFiles = [ContentFile]()
                var allFileRefs = [ThreadSafeReference<ContentFile>]()
                var candidatesByPrimaryKey = [String: PostprocessorCandidate]()
                var candidatePrimaryKeys = [String]()
                var updatedPrimaryKeys = Set<String>()
                let realm = try await RealmBackgroundActor.shared.cachedRealm(
                    for: realmConfiguration
                )

                try await realm.asyncWrite {
                    for (readerFileURL, absoluteFileURL) in pendingFilesToUpdate {
                        try Task.checkCancellation()
                        let sourceGeneration = Self.postprocessorSourceGeneration(
                            at: absoluteFileURL
                        )

                        if let existing = realm.objects(ContentFile.self).filter(NSPredicate(format: "url == %@", readerFileURL.absoluteString as CVarArg)).first {
                            try Task.checkCancellation()
                            if try setMetadata(readerFileURL: readerFileURL, absoluteFileURL: absoluteFileURL, contentFile: existing) {
                                updatedFiles.append(existing)
                                updatedPrimaryKeys.insert(existing.compoundKey)
                            }
                            candidatesByPrimaryKey[existing.compoundKey] = PostprocessorCandidate(
                                contentFile: existing,
                                absoluteFileURL: absoluteFileURL,
                                sourceGeneration: sourceGeneration
                            )
                            candidatePrimaryKeys.append(existing.compoundKey)
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
                                contentFile.refreshChangeMetadata(explicitlyModified: true)
                                updatedFiles.append(contentFile)
                                updatedPrimaryKeys.insert(contentFile.compoundKey)
                            }
                            candidatesByPrimaryKey[contentFile.compoundKey] = PostprocessorCandidate(
                                contentFile: contentFile,
                                absoluteFileURL: absoluteFileURL,
                                sourceGeneration: sourceGeneration
                            )
                            candidatePrimaryKeys.append(contentFile.compoundKey)
                            allFileRefs.append(ThreadSafeReference(to: contentFile))
                        }
                    }

                    for registration in processorSnapshot.filePostprocessors {
                        guard let processorIdentity = registration.identity else { continue }
                        for primaryKey in candidatePrimaryKeys {
                            guard let candidate = candidatesByPrimaryKey[primaryKey] else { continue }
                            let contentFile = candidate.contentFile
                            let workItemIdentifier = ReaderFilePostprocessingWorkItem.makeWorkItemIdentifier(
                                storageScopeIdentifier: storageScopeIdentifier,
                                processorIdentifier: processorIdentity.identifier,
                                contentFilePrimaryKey: contentFile.compoundKey
                            )
                            let portableWorkItemIdentifier = ReaderFilePostprocessingWorkItem
                                .makePortableWorkItemIdentifier(
                                    processorIdentifier: processorIdentity.identifier,
                                    contentFilePrimaryKey: contentFile.compoundKey
                                )
                            let portableWorkItem = realm.object(
                                ofType: ReaderFilePostprocessingWorkItem.self,
                                forPrimaryKey: portableWorkItemIdentifier
                            )
                            guard updatedPrimaryKeys.contains(contentFile.compoundKey)
                                    || realm.object(
                                        ofType: ReaderFilePostprocessingWorkItem.self,
                                        forPrimaryKey: workItemIdentifier
                                    ) != nil
                                    || portableWorkItem != nil else {
                                continue
                            }
                            Self.admitPostprocessingWorkItem(
                                workItemIdentifier: workItemIdentifier,
                                storageScopeIdentifier: storageScopeIdentifier,
                                processorIdentity: processorIdentity,
                                candidate: candidate,
                                in: realm
                            )
                            if let portableWorkItem,
                               portableWorkItem.workItemIdentifier != workItemIdentifier {
                                realm.delete(portableWorkItem)
                            }
                        }
                    }
                }
                var firstPostprocessorError: (any Swift.Error)?
                for registration in processorSnapshot.filePostprocessors {
                    try Task.checkCancellation()
                    if let processorIdentity = registration.identity {
                        let pending = candidatePrimaryKeys.compactMap { primaryKey -> (
                            ContentFile,
                            ReaderFilePostprocessorAdmission
                        )? in
                            guard let candidate = candidatesByPrimaryKey[primaryKey] else {
                                return nil
                            }
                            guard candidate.sourceGeneration.isComplete else {
                                return nil
                            }
                            let contentFile = candidate.contentFile
                            let workItemIdentifier = ReaderFilePostprocessingWorkItem.makeWorkItemIdentifier(
                                storageScopeIdentifier: storageScopeIdentifier,
                                processorIdentifier: processorIdentity.identifier,
                                contentFilePrimaryKey: contentFile.compoundKey
                            )
                            guard let workItem = realm.object(
                                ofType: ReaderFilePostprocessingWorkItem.self,
                                forPrimaryKey: workItemIdentifier
                            ),
                            Self.postprocessingWorkItem(
                                workItem,
                                matches: processorIdentity,
                                storageScopeIdentifier: storageScopeIdentifier,
                                candidate: candidate
                            ) else {
                                return nil
                            }
                            return (
                                contentFile,
                                ReaderFilePostprocessorAdmission(
                                    registrationIdentifier: registration.registrationIdentifier,
                                    processorIdentity: processorIdentity,
                                    workItemIdentifier: workItemIdentifier,
                                    attemptIdentifier: workItem.attemptIdentifier,
                                    storageScopeIdentifier: storageScopeIdentifier,
                                    contentFilePrimaryKey: contentFile.compoundKey,
                                    contentFileCreatedAt: contentFile.createdAt,
                                    readerFileURLString: contentFile.url.absoluteString,
                                    absoluteFileURL: candidate.absoluteFileURL,
                                    sourceModifiedAt: candidate.sourceGeneration.modifiedAt,
                                    sourceFileSize: candidate.sourceGeneration.fileSize
                                )
                            )
                        }
                        for (contentFile, admission) in pending {
                            try Task.checkCancellation()
                            let outcome = ReaderFilePostprocessorOutcome()
                            let postprocessorContext = ReaderFilePostprocessorContext(
                                readerFileManager: self,
                                realmConfiguration: realmConfiguration,
                                realm: realm,
                                contentFiles: [contentFile],
                                outcome: outcome,
                                admission: admission
                            )
                            do {
                                try await registration.processor(postprocessorContext)
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                if firstPostprocessorError == nil {
                                    firstPostprocessorError = error
                                }
                                continue
                            }
                            try Task.checkCancellation()
                            if outcome.isDeferred(
                                contentFilePrimaryKey: contentFile.compoundKey
                            ) {
                                continue
                            }
                            try await realm.asyncWrite {
                                self.processorRegistry.mutateIfCurrentFilePostprocessor(
                                    registrationIdentifier: admission.registrationIdentifier
                                ) {
                                    guard self.postprocessorStateIsCurrent(
                                        admission,
                                        in: realm
                                    ),
                                    let workItem = realm.object(
                                        ofType: ReaderFilePostprocessingWorkItem.self,
                                        forPrimaryKey: admission.workItemIdentifier
                                    ) else {
                                        return false
                                    }
                                    realm.delete(workItem)
                                    return true
                                }
                            }
                        }
                        continue
                    }

                    let postprocessorContext = ReaderFilePostprocessorContext(
                        readerFileManager: self,
                        realmConfiguration: realmConfiguration,
                        realm: realm,
                        contentFiles: updatedFiles
                    )
                    do {
                        try await registration.processor(postprocessorContext)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        if firstPostprocessorError == nil {
                            firstPostprocessorError = error
                        }
                    }
                }
                if let firstPostprocessorError {
                    throw firstPostprocessorError
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

    private static func postprocessorStorageScopeIdentifier(
        drive: CloudDrive,
        realmConfiguration: Realm.Configuration
    ) -> String {
        let components = [
            realmConfigurationIdentity(realmConfiguration),
            drive.rootDirectory.standardizedFileURL.absoluteString,
            drive.ubiquityContainerIdentifier ?? "local",
        ]
        return components
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
    }

    private static func postprocessorSourceGeneration(
        at absoluteFileURL: URL
    ) -> PostprocessorSourceGeneration {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: absoluteFileURL.path
        )
        return PostprocessorSourceGeneration(
            modifiedAt: attributes?[.modificationDate] as? Date,
            fileSize: (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        )
    }

    @RealmBackgroundActor
    fileprivate func performPostprocessorWriteIfCurrent(
        admission: ReaderFilePostprocessorAdmission,
        in realm: Realm,
        mutation: @escaping @RealmBackgroundActor (Realm, ContentFile) throws -> Void
    ) async throws -> Bool {
        try Task.checkCancellation()
        return try await realm.asyncWrite {
            try processorRegistry.mutateIfCurrentFilePostprocessor(
                registrationIdentifier: admission.registrationIdentifier
            ) {
                guard postprocessorStateIsCurrent(admission, in: realm),
                      let contentFile = realm.object(
                        ofType: ContentFile.self,
                        forPrimaryKey: admission.contentFilePrimaryKey
                      ) else {
                    return nil
                }
                try mutation(realm, contentFile)
                return true
            } ?? false
        }
    }

    @RealmBackgroundActor
    private func postprocessorStateIsCurrent(
        _ admission: ReaderFilePostprocessorAdmission,
        in realm: Realm
    ) -> Bool {
        guard let contentFile = realm.object(
            ofType: ContentFile.self,
            forPrimaryKey: admission.contentFilePrimaryKey
        ),
        contentFile.createdAt == admission.contentFileCreatedAt,
        contentFile.url.absoluteString == admission.readerFileURLString,
        let workItem = realm.object(
            ofType: ReaderFilePostprocessingWorkItem.self,
            forPrimaryKey: admission.workItemIdentifier
        ),
        workItem.storageScopeIdentifier == admission.storageScopeIdentifier,
        workItem.processorIdentifier == admission.processorIdentity.identifier,
        workItem.processorVersion == admission.processorIdentity.version,
        workItem.contentFilePrimaryKey == admission.contentFilePrimaryKey,
        workItem.contentFileCreatedAt == admission.contentFileCreatedAt,
        workItem.readerFileURLString == admission.readerFileURLString,
        workItem.sourceModifiedAt == admission.sourceModifiedAt,
        workItem.sourceFileSize == admission.sourceFileSize,
        workItem.attemptIdentifier == admission.attemptIdentifier else {
            return false
        }
        let currentSourceGeneration = Self.postprocessorSourceGeneration(
            at: admission.absoluteFileURL
        )
        return currentSourceGeneration.modifiedAt == admission.sourceModifiedAt
            && currentSourceGeneration.fileSize == admission.sourceFileSize
    }

    @RealmBackgroundActor
    private static func admitPostprocessingWorkItem(
        workItemIdentifier: String,
        storageScopeIdentifier: String,
        processorIdentity: ReaderFilePostprocessorIdentity,
        candidate: PostprocessorCandidate,
        in realm: Realm
    ) {
        let contentFile = candidate.contentFile
        let workItem: ReaderFilePostprocessingWorkItem
        if let existing = realm.object(
            ofType: ReaderFilePostprocessingWorkItem.self,
            forPrimaryKey: workItemIdentifier
        ) {
            workItem = existing
        } else {
            workItem = ReaderFilePostprocessingWorkItem()
            workItem.workItemIdentifier = workItemIdentifier
        }
        workItem.storageScopeIdentifier = storageScopeIdentifier
        workItem.processorIdentifier = processorIdentity.identifier
        workItem.processorVersion = processorIdentity.version
        workItem.contentFilePrimaryKey = contentFile.compoundKey
        workItem.contentFileCreatedAt = contentFile.createdAt
        workItem.readerFileURLString = contentFile.url.absoluteString
        workItem.sourceModifiedAt = candidate.sourceGeneration.modifiedAt
        workItem.sourceFileSize = candidate.sourceGeneration.fileSize
        workItem.attemptIdentifier = UUID().uuidString
        workItem.enqueuedAt = Date()
        if workItem.realm == nil {
            realm.add(workItem)
        }
    }

    @RealmBackgroundActor
    private static func postprocessingWorkItem(
        _ workItem: ReaderFilePostprocessingWorkItem,
        matches processorIdentity: ReaderFilePostprocessorIdentity,
        storageScopeIdentifier: String,
        candidate: PostprocessorCandidate
    ) -> Bool {
        let contentFile = candidate.contentFile
        return workItem.storageScopeIdentifier == storageScopeIdentifier
            && workItem.processorIdentifier == processorIdentity.identifier
            && workItem.processorVersion == processorIdentity.version
            && workItem.contentFilePrimaryKey == contentFile.compoundKey
            && workItem.contentFileCreatedAt == contentFile.createdAt
            && workItem.readerFileURLString == contentFile.url.absoluteString
            && workItem.sourceModifiedAt == candidate.sourceGeneration.modifiedAt
            && workItem.sourceFileSize == candidate.sourceGeneration.fileSize
    }

    @RealmBackgroundActor
    private static func deletePostprocessingWorkItems(
        contentFilePrimaryKeys: [String],
        in realm: Realm
    ) {
        guard !contentFilePrimaryKeys.isEmpty,
              realm.schema.objectSchema.contains(where: {
                  $0.className == ReaderFilePostprocessingWorkItem.className()
              }) else {
            return
        }
        let workItems = realm.objects(ReaderFilePostprocessingWorkItem.self).filter(
            NSPredicate(
                format: "contentFilePrimaryKey IN %@",
                contentFilePrimaryKeys
            )
        )
        realm.delete(workItems)
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
    private func markDeleted(
        contentURL: URL,
        realmConfiguration: Realm.Configuration
    ) async throws {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
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
            let deletedPrimaryKeys = contentFiles.map(\.compoundKey)
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
            Self.deletePostprocessingWorkItems(
                contentFilePrimaryKeys: deletedPrimaryKeys,
                in: realm
            )
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
            switch try availabilityAccess.payloadState(payloadURL) {
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
                    try availabilityAccess.startDownloading(payloadURL)
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

        guard try await availabilityAccess.canCoordinateRead(activeRootURL) else {
            return ReaderBackingAvailability(status: .cloudOnly, localURL: activeRootURL, requestedDownload: false)
        }

        return ReaderBackingAvailability(status: .availableLocally, localURL: activeRootURL, requestedDownload: false)
    }

    private static func payloadState(at url: URL) throws -> ReaderFilePayloadState {
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
                guard try availabilityAccess.payloadState(payloadURL) == .current else {
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

    private func contentFileIndexDecision(
        at absoluteFileURL: URL,
        processorSnapshot: ReaderFileProcessorRegistrySnapshot
    ) -> ContentFileIndexDecision {
        if Self.shouldSkipDiscoveredFile(at: absoluteFileURL) {
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

        if processorSnapshot.readerContentMimeTypes.contains(where: { fileType.conforms(to: $0) }) {
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

    static func isMissingFileError(_ error: any Swift.Error) -> Bool {
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
        
        let targetDirectory = try await Self.rootRelativePath(
            forDownloadURL: url,
            drive: drive,
            processorSnapshot: processorRegistry.snapshot()
        )
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
            guard let self else { return }
            self.driveInventoryGeneration.advance()
            try? await self.refreshAllFilesMetadata(force: true)
        }
    }
}

private extension ReaderFileManager {
    @MainActor
    static func rootRelativePath(
        forLocalCandidateURL url: URL,
        drive: CloudDrive,
        processorSnapshot: ReaderFileProcessorRegistrySnapshot
    ) async throws -> RootRelativePath {
        try await rootRelativePath(
            forClassificationCandidateURL: url,
            drive: drive,
            processorSnapshot: processorSnapshot
        )
    }

    @MainActor
    static func rootRelativePath(
        forDownloadURL url: URL,
        drive _: CloudDrive,
        processorSnapshot: ReaderFileProcessorRegistrySnapshot
    ) async throws -> RootRelativePath {
        if url.isEBookURL,
           processorSnapshot.readerContentMimeTypes.contains(where: {
               UTType.epub.conforms(to: $0)
           }) {
            return RootRelativePath(path: "Books")
        }
        let downloadIdentity = String(format: "%02X", stableHash(url.absoluteString))
        return RootRelativePath(path: predownloadStagingRootPrefix + downloadIdentity)
    }

    @MainActor
    static func rootRelativePath(
        forClassificationCandidateURL url: URL,
        drive: CloudDrive,
        processorSnapshot: ReaderFileProcessorRegistrySnapshot
    ) async throws -> RootRelativePath {
        switch url.lakePathExtension.lowercased() {
        default:
            var selectedDestination: RootRelativePath?
            for fileDestinationProcessor in processorSnapshot.destinationProcessors {
                guard let candidateDestination = try await fileDestinationProcessor(url) else {
                    continue
                }
                let validatedDestination = try validatedDestinationPath(candidateDestination)
                if let selectedDestination,
                   selectedDestination != validatedDestination {
                    throw ReaderFileManagerError.ambiguousDestinationPath
                }
                selectedDestination = validatedDestination
            }
            return selectedDestination ?? .root
        }
    }

    static func validatedDestinationPath(
        _ destination: RootRelativePath
    ) throws -> RootRelativePath {
        guard !destination.path.isEmpty else {
            return destination
        }
        let components = destination.path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !destination.path.hasPrefix("/"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ReaderFileManagerError.invalidDestinationPath
        }
        return destination
    }

    static func validateDestinationContainment(
        _ destination: RootRelativePath,
        in driveRootURL: URL
    ) throws {
        let destination = try validatedDestinationPath(destination)
        let resolvedRootURL = driveRootURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var resolvedCandidateURL = resolvedRootURL

        for component in destination.path.split(separator: "/") {
            let unresolvedCandidateURL = resolvedCandidateURL
                .appendingPathComponent(String(component))
                .standardizedFileURL
            if let symbolicLinkDestination = try? FileManager.default
                .destinationOfSymbolicLink(atPath: unresolvedCandidateURL.path) {
                let symbolicLinkDestinationURL: URL
                if symbolicLinkDestination.hasPrefix("/") {
                    symbolicLinkDestinationURL = URL(fileURLWithPath: symbolicLinkDestination)
                } else {
                    symbolicLinkDestinationURL = unresolvedCandidateURL
                        .deletingLastPathComponent()
                        .appendingPathComponent(symbolicLinkDestination)
                }
                resolvedCandidateURL = symbolicLinkDestinationURL
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
            } else {
                resolvedCandidateURL = unresolvedCandidateURL.resolvingSymlinksInPath()
            }
            guard isContainedFileURL(
                resolvedCandidateURL,
                in: resolvedRootURL
            ) else {
                throw ReaderFileManagerError.invalidDestinationPath
            }
        }
    }

    static func isContainedFileURL(
        _ candidateURL: URL,
        in rootURL: URL
    ) -> Bool {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let candidateComponents = candidateURL.standardizedFileURL.pathComponents
        return candidateComponents.count >= rootComponents.count
            && candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
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
