import SwiftUI
import ReadiumOPDS
import RealmSwift
import RealmSwiftGaps
import Combine

@MainActor
class OPDSCatalogsViewModel: ObservableObject {
    @Published var catalogs: [OPDSCatalog] = []
    @Published var errorMessage: String?
    private var cancellables = Set<AnyCancellable>()
    
    // Use a Realm notification token to observe changes
    private var notificationToken: NotificationToken?
    
    init() {
        observeCatalogs()
    }
    
    deinit {
        notificationToken?.invalidate()
    }
    
    private func observeCatalogs() {
        do {
            let realm = try! Realm()
            let results = realm.objects(OPDSCatalog.self)
            notificationToken = results.observe { [weak self] (changes: RealmCollectionChange) in
                switch changes {
                case .initial, .update:
                    Task { [weak self] in
                        await self?.fetchAllData() // Refresh data whenever there's a change
                    }
                case .error(let error):
                    self?.errorMessage = "Realm error: \(error.localizedDescription)"
                }
            }
        }
    }
    
    func fetchAllData() async {
        // Simulate fetching "Editor's Picks" data
//        editorsPicks = [Book(title: "Editor's Pick 1"), Book(title: "Editor's Pick 2")]
        // No need to update catalogs here, as they are managed directly by Realm and observed via notificationToken
    }
    
    @RealmBackgroundActor
    func addCatalog(title: String, url: String) async {
        let newCatalog = OPDSCatalog()
        newCatalog.title = title
        newCatalog.url = url
        
        do {
            let realm = try await Realm(actor: RealmBackgroundActor.shared)
            try await realm.asyncWrite {
                realm.add(newCatalog, update: .modified)
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
            let realm = try await Realm(actor: RealmBackgroundActor.shared)
            try? await realm.asyncWrite {
                for catalog in Array(realm.objects(OPDSCatalog.self).where { $0.id.in(catalogIDsToDelete) }) {
                    catalog.isDeleted = true
                }
            }
        }
    }
}
@available(macOS 13.0, iOS 16, *)
struct OPDSCatalogsView: View {
    @EnvironmentObject private var viewModel: OPDSCatalogsViewModel
    @State private var showingCatalogDetail: OPDSCatalog?
    
    @EnvironmentObject private var bookLibraryModalsModel: BookLibraryModalsModel
    
    var body: some View {
        List {
            ForEach(viewModel.catalogs, id: \.self) { catalog in
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
    @ObservedRealmObject var catalog: OPDSCatalog
    @State private var publications: [Book] = []
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
                    self.publications = feed.publications.map { Book(title: $0.metadata.title) }
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
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
    
    @RealmBackgroundActor
    private func addCatalog(title: String, url: String) async {
        let newCatalog = OPDSCatalog()
        newCatalog.title = title
        newCatalog.url = url
        
        do {
            let realm = try await Realm(actor: RealmBackgroundActor.shared)
            try await realm.asyncWrite {
                realm.add(newCatalog, update: .modified)
            }
            await MainActor.run { dismiss() }
        } catch {
            await MainActor.run {
                self.errorMessage = "Error adding new catalog: \(error.localizedDescription)"
            }
        }
    }
}
