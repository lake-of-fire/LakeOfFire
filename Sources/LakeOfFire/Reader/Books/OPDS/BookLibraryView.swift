import SwiftUI
import ReadiumOPDS
import RealmSwift
import RealmSwiftGaps
import Combine

public class BookLibraryModalsModel: ObservableObject {
    @Published var showingEbookCatalogs = false
    @Published var showingAddCatalog = false
    @Published var isImportingBookFile = false
    
    public init() { }
}

struct BookLibrarySheetsModifier: ViewModifier {
    @ObservedObject var bookLibraryModalsModel: BookLibraryModalsModel
    @StateObject private var opdsCatalogsViewModel = OPDSCatalogsViewModel()
    @EnvironmentObject private var readerFileManager: ReaderFileManager
    
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $bookLibraryModalsModel.showingEbookCatalogs) {
                if #available(iOS 16, macOS 13, *) {
                    NavigationStack {
                        OPDSCatalogsView()
                    }
                    .sheet(isPresented: $bookLibraryModalsModel.showingAddCatalog) {
                        AddCatalogView()
                    }
                }
            }
            .environmentObject(opdsCatalogsViewModel)
            .fileImporter(isPresented: $bookLibraryModalsModel.isImportingBookFile, allowedContentTypes: [.epub, .epubZip, .directory]) { result in
                Task { @MainActor in
                    switch result {
                    case .success(let url):
                        do {
                            guard let importedFileURL = try await readerFileManager.importFile(fileURL: url, restrictToReaderContentMimeTypes: true) else {
                                print("Couldn't import \(url.absoluteString)")
                                return
                            }
                        } catch {
                            print("Couldn't import \(url.absoluteString): \(error)")
                            return
                        }
                    case .failure(let error):
                        print(error)
                    }
                }
            }
    }
}

public extension View {
    func bookLibrarySheets(bookLibraryModalsModel: BookLibraryModalsModel) -> some View {
        modifier(BookLibrarySheetsModifier(bookLibraryModalsModel: bookLibraryModalsModel))
    }
}

fileprivate struct EditorsPicksView: View {
    @ObservedObject var viewModel: BookLibraryViewModel
    
    var body: some View {
        if let errorMessage = viewModel.errorMessage {
            VStack(alignment: .leading, spacing: 10) {
                Text("Error: \(errorMessage)")
                    .foregroundColor(.red)
                Button("Retry") {
                    Task {
                        await viewModel.fetchAllData()
                    }
                }
            }
        } else {
            ForEach(viewModel.editorsPicks) { pick in
                Text(pick.title)
            }
        }

    }
}

@available(macOS 13.0, iOS 16.0, *)
public struct BookLibraryView: View {
    @StateObject private var viewModel = BookLibraryViewModel()
    @SceneStorage("bookFileEntrySelection") private var entrySelection: String?
    
    @EnvironmentObject private var bookLibraryModalsModel: BookLibraryModalsModel
    @EnvironmentObject private var readerFileManager: ReaderFileManager
 
    public var body: some View {
        List {
            Section("Editor's Picks") {
                EditorsPicksView(viewModel: viewModel)
            }
//
//            Button("Catalogs") {
//                // Implementation remains unchanged
//            }
            
            // Section for User Library can be implemented similarly
            Section {
                if let files = readerFileManager.ebookFiles {
                    ReaderContentListItems(contents: files, entrySelection: $entrySelection, alwaysShowThumbnails: false, sortOrder: .createdAt)
                }
            } header: {
                VStack(alignment: .leading) {
                    Text("My Books")
                    Button {
                        bookLibraryModalsModel.isImportingBookFile.toggle()
                    } label: {
                        Label("Add EPUB", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
        .navigationTitle("Books")
        .refreshable { await viewModel.fetchAllData() }
        .task(id: readerFileManager.ubiquityContainerIdentifier) {
            try? await readerFileManager.refreshAllFilesMetadata()
        }
    }
    
    public init() { }
}



@MainActor
class BookLibraryViewModel: ObservableObject {
    @Published var editorsPicks: [Book] = []
    @Published var errorMessage: String?
    private var cancellables = Set<AnyCancellable>()
    
    func fetchAllData() async {
        // Simulate fetching "Editor's Picks" data
        editorsPicks = [Book(title: "Editor's Pick 1"), Book(title: "Editor's Pick 2")]
        // No need to update catalogs here, as they are managed directly by Realm and observed via notificationToken
    }
}

struct Book: Identifiable {
    let id = UUID()
    let title: String
}
