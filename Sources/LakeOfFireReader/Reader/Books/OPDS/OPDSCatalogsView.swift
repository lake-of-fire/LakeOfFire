import SwiftUI
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore
import LakeOfFireOPDS
import RealmSwift
import RealmSwiftGaps

struct OPDSCatalogSnapshot: Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let url: String

    init(_ catalog: OPDSCatalog) {
        id = catalog.id
        title = catalog.title
        url = catalog.url
    }
}

@MainActor
class OPDSCatalogsViewModel: ObservableObject {
    @Published var catalogs: [OPDSCatalogSnapshot] = []
    @Published var errorMessage: String?
    
    @RealmBackgroundActor
    private var notificationToken: NotificationToken?
    
    init() {
        observeCatalogs()
    }
    
    deinit {
        Task { @RealmBackgroundActor [weak notificationToken] in
            notificationToken?.invalidate()
        }
    }
    
    private func observeCatalogs() {
        Task { @RealmBackgroundActor in
            do {
                let realm = try await RealmBackgroundActor.shared.cachedRealm(for: .defaultConfiguration)
                let results = realm.objects(OPDSCatalog.self)
                    .where { !$0.isDeleted }
                notificationToken = results.observe { [weak self] changes in
                    switch changes {
                    case .initial(let catalogs),
                         .update(let catalogs, _, _, _):
                        let snapshots = Array(
                            catalogs.map(OPDSCatalogSnapshot.init)
                        )
                        Task { @MainActor [weak self] in
                            self?.catalogs = snapshots
                        }
                    case .error(let error):
                        Task { @MainActor [weak self] in
                            self?.errorMessage = "Realm error: \(error.localizedDescription)"
                        }
                    }
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.errorMessage =
                        "Error observing catalogs: \(error.localizedDescription)"
                }
            }
        }
    }
    
    func fetchAllData() async {
        do {
            catalogs = try await Self.loadCatalogs()
        } catch {
            errorMessage = "Error loading catalogs: \(error.localizedDescription)"
        }
    }

    @RealmBackgroundActor
    private static func loadCatalogs() async throws -> [OPDSCatalogSnapshot] {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: .defaultConfiguration
        )
        await realm.asyncRefresh()
        return Array(
            realm.objects(OPDSCatalog.self)
                .where { !$0.isDeleted }
                .map(OPDSCatalogSnapshot.init)
        )
    }
    
    @RealmBackgroundActor
    func addCatalog(title: String, url: String) async {
        do {
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: .defaultConfiguration)
            await realm.asyncRefresh()
            try await realm.asyncWrite {
                OPDSCatalog.add(title: title, url: url, to: realm)
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.errorMessage = "Error adding new catalog: \(error.localizedDescription)"
            }
        }
    }
    
    func deleteCatalogs(at offsets: IndexSet) {
        let catalogIDsToDelete = offsets.map { catalogs[$0].id }
        Task { @RealmBackgroundActor [weak self] in
            do {
                let realm = try await RealmBackgroundActor.shared.cachedRealm(
                    for: .defaultConfiguration
                )
                await realm.asyncRefresh()
                try await realm.asyncWrite {
                    for catalog in Array(
                        realm.objects(OPDSCatalog.self)
                            .where { $0.id.in(catalogIDsToDelete) }
                    ) {
                        catalog.softDelete()
                    }
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.errorMessage =
                        "Error deleting catalogs: \(error.localizedDescription)"
                }
            }
        }
    }
}
@available(macOS 13.0, iOS 16, *)
struct OPDSCatalogsView: View {
    @EnvironmentObject private var viewModel: OPDSCatalogsViewModel
    @State private var showingCatalogDetail: OPDSCatalogSnapshot?
    
    @EnvironmentObject private var bookLibraryModalsModel: BookLibraryModalsModel
    
    var body: some View {
        List {
            ForEach(viewModel.catalogs) { catalog in
                Button(catalog.title) {
                    showingCatalogDetail = catalog
                }
                .sheet(item: $showingCatalogDetail) { catalog in
                    NavigationStack {
                        OPDSCatalogDetailView(catalog: catalog)
                    }
                }
            }
            .onDelete(perform: deleteCatalogs)
        }
        .navigationTitle("Ebook Catalogs")
        .toolbar {
            Button("Add") { bookLibraryModalsModel.showingAddCatalog = true }
        }
    }
    
    private func deleteCatalogs(at offsets: IndexSet) {
        viewModel.deleteCatalogs(at: offsets)
    }
}

struct OPDSCatalogDetailView: View {
    let catalog: OPDSCatalogSnapshot
    @State private var publications: [Publication] = []
    @State private var errorMessage: String?
    
    var body: some View {
        List(publications) { publication in
            Text(publication.title)
        }
        .navigationTitle("Catalog Details")
        .onAppear {
            fetchCatalog()
        }
    }
    
    private func fetchCatalog() {
        guard let url = URL(string: catalog.url) else {
            errorMessage = "Invalid catalog URL"
            return
        }
        
        OPDSParser.parseURL(url: url) { parseData, error in
            DispatchQueue.main.async {
                if let feed = parseData?.feed {
                    self.publications = feed.publications.map { Publication(title: $0.metadata.title) }
                } else if let error = error {
                    self.errorMessage = "Failed to fetch catalog data: \(error.localizedDescription)"
                }
            }
        }
    }
}

struct AddCatalogView: View {
    @State private var title = ""
    @State private var url = ""
    @State private var errorMessage: String? = nil
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Catalog Details")) {
                    TextField("Title", text: $title)
                    TextField("URL", text: $url)
                }
                
                if let errorMessage = errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                    }
                }
                
                Section {
                    Button("Add") {
                        Task {
                            await addCatalog(title: title, url: url)
                        }
                    }
                    .disabled(title.isEmpty || url.isEmpty)
                }
            }
            .navigationTitle("Add New Catalog")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if #available(iOS 26, macOS 26, *) {
                        Button(role: .cancel) { dismiss() } label: {
                            Text("Cancel")
                        }
                        .tint(.primary)
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
    }
    
    @RealmBackgroundActor
    private func addCatalog(title: String, url: String) async {
        do {
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: .defaultConfiguration) 
            await realm.asyncRefresh()
            try await realm.asyncWrite {
                OPDSCatalog.add(title: title, url: url, to: realm)
            }
            await MainActor.run { dismiss() }
        } catch {
            await MainActor.run {
                self.errorMessage = "Error adding new catalog: \(error.localizedDescription)"
            }
        }
    }
}
