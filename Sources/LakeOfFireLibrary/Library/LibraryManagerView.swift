import LakeOfFireWeb
import SwiftUI
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireReader
import LakeOfFireContent
import LakeOfFireCore
import RealmSwift
import FilePicker
import UniformTypeIdentifiers
import OPML
import SwiftUIWebView
import FaviconFinder
import DebouncedOnChange
import OpenGraph
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

@available(iOS 16.0, macOS 13, *)
struct LibraryScriptForm: View {
    let script: UserScript
    
    var body: some View {
        Form {
            LibraryScriptFormSections(script: script)
                .disabled(!script.isUserEditable)
        }
        .formStyle(.grouped)
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct LibraryCategoryViewContainer: View {
    let category: FeedCategory
    let libraryConfiguration: LibraryConfiguration
    @Binding var selectedFeed: Feed?
    
    var body: some View {
        LibraryCategoryView(
            category: category,
            libraryConfiguration: libraryConfiguration,
            selectedFeed: $selectedFeed
        )
        .task(id: selectedFeed?.categoryID) { @MainActor in
            if selectedFeed?.categoryID != category.id {
                selectedFeed = nil
            }
            //                        let feedsToDeselect = viewModel.selectedFeed.filter { $0.category != category }
            //                        feedsToDeselect.forEach {
            //                            viewModel.selectedFeed.remove($0)
            //                        }
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
public struct LibraryManagerView: View {
    @EnvironmentObject private var viewModel: LibraryManagerViewModel
    
    @State private var columnVisibility = LibraryManagerView.initialColumnVisibility
    @State private var compactColumn = CompactLibraryColumn.sidebar
    
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif
    @AppStorage("appTint") private var appTint: Color = Color("AccentColor")
    
    @State private var libraryCategoryViewModel: LibraryCategoryViewModel?
    
    public var body: some View {
        splitView
        .navigationSplitViewStyle(.balanced)
        .onChange(of: viewModel.selectedSidebarDestination) { destination in
            Task { @MainActor in
                switch destination {
                case .none:
                    viewModel.selectedFeed = nil
                    viewModel.selectedScript = nil
                    compactColumn = .sidebar
                case .some(.userScripts):
                    viewModel.selectedFeed = nil
                    compactColumn = .content
                case .some(.category(let categoryID)):
                    viewModel.selectedScript = nil
                    if viewModel.selectedFeed?.categoryID != categoryID {
                        viewModel.selectedFeed = nil
                    }
                    compactColumn = .content
                }
            }
        }
        .onChange(of: viewModel.selectedFeed) { feed in
            Task { @MainActor in
                if feed != nil {
                    viewModel.selectedScript = nil
                    compactColumn = .detail
                } else if viewModel.selectedScript == nil {
                    compactColumn = viewModel.selectedSidebarDestination == nil ? .sidebar : .content
                }
            }
        }
        .onChange(of: viewModel.selectedScript) { script in
            Task { @MainActor in
                if script != nil {
                    viewModel.selectedFeed = nil
                    compactColumn = .detail
                } else if viewModel.selectedFeed == nil {
                    compactColumn = viewModel.selectedSidebarDestination == nil ? .sidebar : .content
                }
            }
        }
        .task { @MainActor in
            columnVisibility = .all
            if viewModel.selectedFeed != nil || viewModel.selectedScript != nil {
                compactColumn = .detail
            } else if viewModel.selectedSidebarDestination == nil {
                compactColumn = .sidebar
            } else {
                compactColumn = .content
            }
        }
    }

    private static var initialColumnVisibility: NavigationSplitViewVisibility {
        .all
    }

    @ViewBuilder
    private var splitView: some View {
        if #available(iOS 17, macOS 14, *) {
            NavigationSplitView(
                columnVisibility: $columnVisibility,
                preferredCompactColumn: Binding(
                    get: { compactColumn.navigationSplitViewColumn },
                    set: { compactColumn = CompactLibraryColumn($0) }
                ),
                sidebar: {
                    sidebarView
                },
                content: {
                    contentView
                },
                detail: {
                    detailView
                }
            )
        } else {
            NavigationSplitView(
                columnVisibility: $columnVisibility,
                sidebar: {
                    sidebarView
                },
                content: {
                    contentView
                },
                detail: {
                    detailView
                }
            )
        }
    }

    @ViewBuilder
    private var sidebarView: some View {
        LibraryCategoriesView()
#if os(iOS)
            .toolbar {
                ToolbarItem(placement: dismissToolbarPlacement) {
                    if horizontalSizeClass == .compact {
                        if #available(iOS 26, *) {
                            Button(role: .close) {
                                viewModel.isLibraryPresented = false
                            }
                            .tint(.primary)
                        } else {
                            Button {
                                viewModel.isLibraryPresented = false
                            } label: {
                                Text("Done")
                                    .bold()
                            }
                            .tint(.primary)
                        }
                    }
                }
            }
#endif
#if os(macOS)
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
#endif
    }

    @ViewBuilder
    private var contentView: some View {
        switch viewModel.selectedSidebarDestination {
        case .some(.category(let categoryID)):
            if let libraryConfiguration = viewModel.libraryConfiguration,
               let category = libraryConfiguration.getCategories()?.first(where: { $0.id == categoryID }) {
                LibraryCategoryViewContainer(
                    category: category,
                    libraryConfiguration: libraryConfiguration,
                    selectedFeed: $viewModel.selectedFeed
                )
            } else {
                contentPlaceholder("Select a category to edit feeds, or open user scripts.")
            }
        case .some(.userScripts):
            LibraryScriptsListView(selectedScript: $viewModel.selectedScript)
                .navigationTitle("User Scripts")
        case .none:
            contentPlaceholder("Select a category to edit feeds, or open user scripts.")
        }
    }

    @ViewBuilder
    private func contentPlaceholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .multilineTextAlignment(.center)
                .padding()
                .foregroundColor(.secondary)
                .font(.callout)
            Spacer()
        }
    }

    @ViewBuilder
    private var detailView: some View {
        VStack {
            if let feed = viewModel.selectedFeed {
#if os(macOS)
                ScrollView {
                    LibraryFeedView(feed: feed)
                    //                                .id("library-manager-feed-view-\(feed.id.uuidString)") // Because it's hard to reuse form instance across feed objects. ?
                }
#else
                LibraryFeedView(feed: feed)
                //                            .id("library-manager-feed-view-\(feed.id.uuidString)") // Because it's hard to reuse form instance across feed objects. ?
#endif
            }
            if let script = viewModel.selectedScript {
#if os(macOS)
                ScrollView {
                    LibraryScriptForm(script: script)
                    //                                .id("library-manager-script-view-\(script.id.uuidString)") // Because it's hard to reuse form instance across script objects. ?
                }
#else
                LibraryScriptForm(script: script)
                //                            .id("library-manager-script-view-\(script.id.uuidString)") // Because it's hard to reuse form instance across script objects. ?
#endif
            }
        }
#if os(macOS)
        .textFieldStyle(.roundedBorder)
#endif
        //                .fixedSize(horizontal: false, vertical: true)
        //            }
        .toolbar {
#if os(iOS)
            ToolbarItem(placement: dismissToolbarPlacement) {
                if #available(iOS 26, *) {
                    Button(role: .close) {
                        viewModel.isLibraryPresented = false
                    }
                    .tint(.primary)
                } else {
                    Button {
                        viewModel.isLibraryPresented = false
                    } label: {
                        Text("Done")
                            .bold()
                    }
                    .tint(.primary)
                }
            }
#endif
        }
    }
    
    public init() {
    }
}

private enum CompactLibraryColumn {
    case sidebar
    case content
    case detail

    @available(iOS 17, macOS 14, *)
    var navigationSplitViewColumn: NavigationSplitViewColumn {
        switch self {
        case .sidebar:
            return .sidebar
        case .content:
            return .content
        case .detail:
            return .detail
        }
    }

    @available(iOS 17, macOS 14, *)
    init(_ column: NavigationSplitViewColumn) {
        switch column {
        case .sidebar:
            self = .sidebar
        case .content:
            self = .content
        case .detail:
            self = .detail
        default:
            self = .sidebar
        }
    }
}

#if os(iOS)
@available(iOS 16.0, macOS 13.0, *)
private extension LibraryManagerView {
    var dismissToolbarPlacement: ToolbarItemPlacement {
        if #available(iOS 26, *) {
            return .cancellationAction
        } else {
            return .confirmationAction
        }
    }
}
#endif
