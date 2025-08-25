import SwiftUI
import RealmSwift
import LakeKit
import RealmSwiftGaps
import SwiftUtilities

struct UserScriptAllowedDomainCell: View {
    let domainID: UUID
    
    init(domainID: UUID) {
        self.domainID = domainID
    }
    
    @State private var domainText: String = ""
    
    var body: some View {
        TextField("Domain", text: $domainText, prompt: Text("example.com"))
#if os(iOS)
            .textInputAutocapitalization(.never)
#endif
            .onChange(of: domainText, debounceTime: 0.3) { domainText in
                let domainID = domainID
                Task { @RealmBackgroundActor in
                    let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration)
                    guard let domain = realm.object(ofType: UserScriptAllowedDomain.self, forPrimaryKey: domainID) else { return }
                    try await realm.asyncWrite {
                        domain.domain = domainText
                    }
                }
            }
            .task(id: domainID) {
                let domainID = domainID
                try? await { @RealmBackgroundActor in
                    let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration)
                    guard let domain = realm.object(ofType: UserScriptAllowedDomain.self, forPrimaryKey: domainID) else { return }
                    let domainText = domain.domain
                    await { @MainActor in
                        self.domainText = domainText
                    }()
                }()
            }
    }
}
