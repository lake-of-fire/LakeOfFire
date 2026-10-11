import Foundation
import RealmSwift
import RealmSwiftGaps
import LakeOfFireContent

enum LibraryScriptField: Int, Hashable, Sendable {
    case title, text, enabled, injectAtStart, mainFrameOnly, sandboxed, previewURL
}

enum LibraryScriptFieldEdit: Equatable, Sendable {
    case title(String), text(String), enabled(Bool), injectAtStart(Bool)
    case mainFrameOnly(Bool), sandboxed(Bool), previewURL(String)

    var field: LibraryScriptField {
        switch self {
        case .title: return .title
        case .text: return .text
        case .enabled: return .enabled
        case .injectAtStart: return .injectAtStart
        case .mainFrameOnly: return .mainFrameOnly
        case .sandboxed: return .sandboxed
        case .previewURL: return .previewURL
        }
    }

    @RealmBackgroundActor
    func apply(to script: UserScript) -> Bool {
        switch self {
        case .title(let value):
            guard script.title != value else { return false }
            script.title = value
        case .text(let value):
            guard script.script != value else { return false }
            script.script = value
        case .enabled(let value):
            guard script.isArchived != !value else { return false }
            script.isArchived = !value
        case .injectAtStart(let value):
            guard script.injectAtStart != value else { return false }
            script.injectAtStart = value
        case .mainFrameOnly(let value):
            guard script.mainFrameOnly != value else { return false }
            script.mainFrameOnly = value
        case .sandboxed(let value):
            guard script.sandboxed != value else { return false }
            script.sandboxed = value
        case .previewURL(let value):
            let url = value.isEmpty ? nil : URL(string: value)
            guard script.previewURL != url else { return false }
            script.previewURL = url
        }
        return true
    }
}

struct LibraryScriptEditorIdentity: Hashable, Sendable {
    let scriptID: UUID
    let createdAt: Date
    let storage: String
    let encryptionKey: Data?
    let schemaVersion: UInt64

    init(owner: LibraryScriptDomainOwner) {
        scriptID = owner.scriptID
        createdAt = owner.scriptCreatedAt
        let configuration = owner.realmConfiguration
        storage = configuration.inMemoryIdentifier.map { "memory:" + $0 }
            ?? configuration.fileURL.map { "file:" + $0.resolvingSymlinksInPath().standardizedFileURL.path }
            ?? "default"
        encryptionKey = configuration.encryptionKey
        schemaVersion = configuration.schemaVersion
    }

    @MainActor
    init?(script: UserScript) {
        guard let owner = LibraryScriptDomainOwner(script: script) else { return nil }
        self.init(owner: owner)
    }
}

/// Transient input admission shared by open editors and their pending commands.
/// Holding the lock through the synchronous mutation prevents an intent from being
/// superseded between its admission check and field assignment; nothing is persisted.
final class LibraryScriptFieldWriteOrdering: @unchecked Sendable {
    private final class WeakOrdering {
        weak var value: LibraryScriptFieldWriteOrdering?
        init(_ value: LibraryScriptFieldWriteOrdering) { self.value = value }
    }
    @MainActor private static var orderings: [LibraryScriptEditorIdentity: WeakOrdering] = [:]
    private let lock = NSLock()
    private var intents: [LibraryScriptField: UUID] = [:]

    @MainActor
    static func shared(identity: LibraryScriptEditorIdentity) -> LibraryScriptFieldWriteOrdering {
        orderings = orderings.filter { $0.value.value != nil }
        if let existing = orderings[identity]?.value { return existing }
        let ordering = LibraryScriptFieldWriteOrdering()
        orderings[identity] = WeakOrdering(ordering)
        return ordering
    }

    func issueIntent(field: LibraryScriptField) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let intent = UUID()
        intents[field] = intent
        return intent
    }

    func withAdmission(field: LibraryScriptField, intent: UUID, apply: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard intents[field] == intent else { return }
        apply()
    }
}

struct LibraryScriptFieldCommand: Sendable {
    let owner: LibraryScriptDomainOwner
    let edit: LibraryScriptFieldEdit
    let intent: UUID
    let ordering: LibraryScriptFieldWriteOrdering

    @RealmBackgroundActor
    func write(beforeWrite: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil) async throws {
        try Task.checkCancellation()
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: owner.realmConfiguration)
        try await beforeWrite?()
        try Task.checkCancellation()
        try await realm.asyncWritePreservingOwnership {
            try Task.checkCancellation()
            guard let script = owner.resolve(in: realm) else { return }
            ordering.withAdmission(field: edit.field, intent: intent) {
                guard edit.apply(to: script) else { return }
                script.refreshChangeMetadata(explicitlyModified: true)
            }
        }
    }
}
