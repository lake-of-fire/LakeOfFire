import SwiftUI
import RealmSwift
import RealmSwiftGaps
import LakeOfFireContent

struct UserScriptAllowedDomainCell: View {
    let target: LibraryUserScriptAllowedDomainTarget
    let scriptTarget: LibraryUserScriptEditorTarget
    let realmConfiguration: Realm.Configuration

    var body: some View {
        UserScriptAllowedDomainCellContent(
            target: target,
            scriptTarget: scriptTarget,
            realmConfiguration: realmConfiguration
        )
        .id("\(scriptTarget.scriptID):\(scriptTarget.createdAt.timeIntervalSinceReferenceDate):"
            + "\(target.domainID):\(target.createdAt.timeIntervalSinceReferenceDate):"
            + userScriptEditorConfigurationIdentity(realmConfiguration))
    }
}

private struct UserScriptAllowedDomainCellContent: View {
    let target: LibraryUserScriptAllowedDomainTarget
    let scriptTarget: LibraryUserScriptEditorTarget
    let realmConfiguration: Realm.Configuration

    @State private var domainText = ""
    @State private var editGeneration: UInt64 = 0
    @State private var persistenceErrorMessage: String?
    @State private var persistenceTail: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading) {
            TextField("Domain", text: Binding(
                get: { domainText },
                set: { submit($0) }
            ), prompt: Text("example.com"))
#if os(iOS)
            .textInputAutocapitalization(.never)
#endif
            if let persistenceErrorMessage {
                Text(persistenceErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .task {
            let loadGeneration = editGeneration
            do {
                let loadedText = try await { @RealmBackgroundActor in
                    let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
                    guard let script = realm.object(ofType: UserScript.self, forPrimaryKey: scriptTarget.scriptID),
                          !script.isDeleted, script.createdAt == scriptTarget.createdAt,
                          script.allowedDomainIDs.contains(target.domainID),
                          let domain = realm.object(ofType: UserScriptAllowedDomain.self,
                                                    forPrimaryKey: target.domainID),
                          !domain.isDeleted, domain.createdAt == target.createdAt else {
                        throw RealmBackgroundActorError.unableToResolveObject
                    }
                    return domain.domain
                }()
                try Task.checkCancellation()
                guard loadGeneration == editGeneration else { return }
                domainText = loadedText
                persistenceErrorMessage = nil
            } catch is CancellationError {
            } catch {
                guard loadGeneration == editGeneration else { return }
                persistenceErrorMessage = error.localizedDescription
            }
        }
    }

    private func submit(_ value: String) {
        domainText = value
        editGeneration &+= 1
        let submittedGeneration = editGeneration
        let target = target
        let scriptTarget = scriptTarget
        let configuration = realmConfiguration
        let predecessor = persistenceTail
        // Queue the immutable intent immediately so removing the row cannot discard a debounce.
        persistenceTail = Task { @MainActor in
            await predecessor?.value
            guard submittedGeneration == editGeneration else { return }
            do {
                let result = try await LibraryUserScriptAllowedDomainFieldCommand.setDomain(
                    value,
                    target: target,
                    from: scriptTarget,
                    configuration: configuration
                )
                guard submittedGeneration == editGeneration else { return }
                switch result {
                case .changed, .unchanged:
                    persistenceErrorMessage = nil
                case .superseded:
                    persistenceErrorMessage = "This domain was replaced before it could be saved."
                case .unavailable:
                    persistenceErrorMessage = "This domain is no longer available."
                }
            } catch {
                guard submittedGeneration == editGeneration else { return }
                persistenceErrorMessage = error.localizedDescription
            }
        }
    }
}
