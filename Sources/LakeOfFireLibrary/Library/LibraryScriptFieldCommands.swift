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
    let scriptRowID: UInt64
    let storage: String
    let encryptionKey: Data?
    let schemaVersion: UInt64

    init(owner: LibraryScriptDomainOwner) {
        scriptID = owner.scriptID
        createdAt = owner.scriptCreatedAt
        scriptRowID = owner.scriptRowID
        let configuration = owner.realmConfiguration
        storage = owner.storageAdmission.scopeIdentity
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
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: owner.realmConfiguration, storageAdmission: owner.storageAdmission
        )
        try await beforeWrite?()
        try Task.checkCancellation()
        try await realm.asyncWritePreservingOwnership {
            try Task.checkCancellation()
            guard let script = try owner.resolve(in: realm) else { return }
            ordering.withAdmission(field: edit.field, intent: intent) {
                guard edit.apply(to: script) else { return }
                script.refreshChangeMetadata(explicitlyModified: true)
            }
        }
    }
}

/// Retains the final commands when their editor binding is replaced or released.
/// Joins every submitted attempt before settling the batch. Final commands without
/// a successful attempt run once through the original owner and shared input-order admission.
struct LibraryScriptFieldRetirement: Sendable {
    let commands: [LibraryScriptFieldCommand]
    let activeWrites: [UUID: Task<Void, Error>]

    // The independent batch retains commands/tasks, never the editor or its new binding.
    // Empty initial bindings and already-settled replacements have no work to retire.
    func start(didFinish: (@RealmBackgroundActor @Sendable () -> Void)? = nil) {
        guard !commands.isEmpty || !activeWrites.isEmpty else { return }
        Task { @RealmBackgroundActor in
            defer { didFinish?() }
            do { try await finish() }
            catch { print("# LIBRARYSCRIPTEDITOR retirement write failed: \(error)") }
        }
    }

    @RealmBackgroundActor
    func finish() async throws {
        var succeededIntents = Set<UUID>()
        // Superseded attempts still belong to this retirement batch. Join them
        // before reporting settlement, but retry only the captured final inputs.
        for (intent, write) in activeWrites {
            do {
                try await write.value
                succeededIntents.insert(intent)
            } catch { /* A matching final command gets one retry below. */ }
        }
        var firstError: Error?
        for command in commands.sorted(by: { $0.edit.field.rawValue < $1.edit.field.rawValue }) {
            guard !succeededIntents.contains(command.intent) else { continue }
            do { try await command.write() }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }
}
