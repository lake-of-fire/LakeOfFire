import Foundation
import RealmSwift
import RealmSwiftGaps
import LakeOfFireContent

struct LibraryScriptDomainSelection: Hashable, Sendable {
    let id: UUID
    let createdAt: Date
}

struct LibraryScriptDomainOwner: Sendable {
    let scriptID: UUID
    let scriptCreatedAt: Date
    let realmConfiguration: Realm.Configuration
    let storageAdmission: RealmStorageAdmission

    @MainActor
    init?(script: UserScript) {
        guard !script.isInvalidated else { return nil }
        scriptID = script.id
        scriptCreatedAt = script.createdAt
        realmConfiguration = script.realm?.configuration ?? LibraryDataManager.realmConfiguration
        storageAdmission = RealmBackgroundActor.shared.captureStorageAdmission(for: realmConfiguration)
    }

    @RealmBackgroundActor
    func resolve(in realm: Realm) throws -> UserScript? {
        guard storageAdmission.matchesCurrentStorageIdentity({
            RealmBackgroundActor.shared.realmCacheKey(for: realmConfiguration)
        }) else {
            throw RealmBackgroundActorError.realmFileChangedDuringOpen
        }
        guard let script = realm.object(ofType: UserScript.self, forPrimaryKey: scriptID),
              script.createdAt == scriptCreatedAt, !script.isDeleted, script.isUserEditable else { return nil }
        return script
    }

    enum Mutation: Sendable {
        case add
        case delete([LibraryScriptDomainSelection])
    }

    @RealmBackgroundActor
    func write(
        _ mutation: Mutation,
        beforeWrite: (@RealmBackgroundActor @Sendable () async -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: realmConfiguration, storageAdmission: storageAdmission
        )
        await beforeWrite?()
        try Task.checkCancellation()
        try await realm.asyncWritePreservingOwnership {
            try Task.checkCancellation()
            guard let script = try resolve(in: realm) else { return }
            let now = Date()
            switch mutation {
            case .add:
                let domain = UserScriptAllowedDomain()
                realm.add(domain)
                domain.refreshChangeMetadata(explicitlyModified: true, at: now)
                script.allowedDomainIDs.append(domain.id)
            case .delete(let selections):
                let selectedDates = selections.reduce(into: [UUID: Date]()) { $0[$1.id] = $1.createdAt }
                let removedIDs = Set(script.allowedDomainIDs).intersection(selectedDates.keys).filter { domainID in
                    guard let domain = realm.object(ofType: UserScriptAllowedDomain.self, forPrimaryKey: domainID)
                    else { return true } // Remove the selected link if acknowledged cleanup removed its row.
                    return domain.createdAt == selectedDates[domainID]
                }
                guard !removedIDs.isEmpty else { return }
                for domainID in removedIDs {
                    if let domain = realm.object(ofType: UserScriptAllowedDomain.self, forPrimaryKey: domainID),
                       !domain.isDeleted {
                        domain.isDeleted = true
                        domain.refreshChangeMetadata(explicitlyModified: true, at: now)
                    }
                }
                for index in script.allowedDomainIDs.indices.reversed()
                    where removedIDs.contains(script.allowedDomainIDs[index]) {
                    script.allowedDomainIDs.remove(at: index)
                }
            }
            script.refreshChangeMetadata(explicitlyModified: true, at: now)
        }
    }
}

/// UI and pending writes share an incarnation-scoped identity, without persisted field clocks.
struct UserScriptAllowedDomainIdentity: Hashable, Sendable {
    let scriptID: UUID
    let scriptCreatedAt: Date
    let domainID: UUID
    let domainCreatedAt: Date
    let storage: String
    let encryptionKey: Data?
    let schemaVersion: UInt64
}

fileprivate final class UserScriptAllowedDomainWriteOrdering: @unchecked Sendable {
    private struct Scope: Hashable {
        let domainID: UUID
        let domainCreatedAt: Date
        let storage: String
        let encryptionKey: Data?
        let schemaVersion: UInt64
    }
    private final class WeakOrdering {
        weak var value: UserScriptAllowedDomainWriteOrdering?
        init(_ value: UserScriptAllowedDomainWriteOrdering) { self.value = value }
    }
    @MainActor private static var orderings: [Scope: WeakOrdering] = [:]
    private let lock = NSLock()
    private var currentIntent: UUID?

    @MainActor
    static func shared(identity: UserScriptAllowedDomainIdentity) -> UserScriptAllowedDomainWriteOrdering {
        orderings = orderings.filter { $0.value.value != nil }
        // Two admitted scripts may refer to the same domain row. Its input order
        // belongs to that row, while each command still validates its own script.
        let scope = Scope(
            domainID: identity.domainID, domainCreatedAt: identity.domainCreatedAt,
            storage: identity.storage, encryptionKey: identity.encryptionKey, schemaVersion: identity.schemaVersion
        )
        if let existing = orderings[scope]?.value { return existing }
        let ordering = UserScriptAllowedDomainWriteOrdering()
        orderings[scope] = WeakOrdering(ordering)
        return ordering
    }

    func issueIntent() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let intent = UUID()
        currentIntent = intent
        return intent
    }

    func withAdmission(intent: UUID, apply: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard currentIntent == intent else { return }
        apply()
    }
}

struct UserScriptAllowedDomainEdit: Sendable {
    let owner: LibraryScriptDomainOwner
    let domainID: UUID
    let domainCreatedAt: Date
    let text: String
    let intent: UUID
    fileprivate let ordering: UserScriptAllowedDomainWriteOrdering

    @RealmBackgroundActor
    func write(beforeWrite: (@RealmBackgroundActor @Sendable () async -> Void)? = nil) async throws {
        try Task.checkCancellation()
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: owner.realmConfiguration, storageAdmission: owner.storageAdmission
        )
        await beforeWrite?()
        try Task.checkCancellation()
        try await realm.asyncWritePreservingOwnership {
            try Task.checkCancellation()
            guard let script = try owner.resolve(in: realm), script.allowedDomainIDs.contains(domainID),
                  let domain = realm.object(ofType: UserScriptAllowedDomain.self, forPrimaryKey: domainID),
                  domain.createdAt == domainCreatedAt, !domain.isDeleted else { return }
            ordering.withAdmission(intent: intent) {
                guard domain.domain != text else { return }
                domain.domain = text
                domain.refreshChangeMetadata(explicitlyModified: true)
            }
        }
    }
}

/// Captured synchronously from the rendered script; hydration is a snapshot, never an edit.
struct UserScriptAllowedDomainEditor: Sendable {
    let owner: LibraryScriptDomainOwner
    let domainID: UUID
    let domainCreatedAt: Date
    let initialText: String
    let identity: UserScriptAllowedDomainIdentity
    private let ordering: UserScriptAllowedDomainWriteOrdering

    var selection: LibraryScriptDomainSelection {
        LibraryScriptDomainSelection(id: domainID, createdAt: domainCreatedAt)
    }

    @MainActor
    init?(script: UserScript, domainID: UUID) {
        guard let owner = LibraryScriptDomainOwner(script: script), !script.isDeleted,
              script.allowedDomainIDs.contains(domainID),
              let domain = script.realm?.object(ofType: UserScriptAllowedDomain.self, forPrimaryKey: domainID),
              !domain.isInvalidated, !domain.isDeleted else { return nil }
        self.owner = owner
        self.domainID = domainID
        domainCreatedAt = domain.createdAt
        initialText = domain.domain
        let configuration = owner.realmConfiguration
        identity = UserScriptAllowedDomainIdentity(
            scriptID: owner.scriptID, scriptCreatedAt: owner.scriptCreatedAt,
            domainID: domainID, domainCreatedAt: domain.createdAt,
            storage: owner.storageAdmission.scopeIdentity,
            encryptionKey: configuration.encryptionKey, schemaVersion: configuration.schemaVersion
        )
        ordering = .shared(identity: identity)
    }

    @MainActor
    func makeEdit(_ text: String) -> UserScriptAllowedDomainEdit {
        UserScriptAllowedDomainEdit(
            owner: owner, domainID: domainID, domainCreatedAt: domainCreatedAt, text: text,
            intent: ordering.issueIntent(), ordering: ordering
        )
    }
}
