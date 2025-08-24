import SwiftUI
import RealmSwift
import FilePicker
import UniformTypeIdentifiers
import OPML
import SwiftUIWebView
import LakeKit
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
    let categoryID: UUID
    let libraryConfiguration: LibraryConfiguration
    @Binding var selectedFeed: Feed?
    
    @State private var loadedCategory: FeedCategory? = nil
    
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif
    
    // Ensure selection only applies to feeds in this category
    private var effectiveSelectedFeed: Binding<Feed?> {
        Binding(
            get: {
                if let feed = selectedFeed,
                   let cid = loadedCategory?.id,
                   feed.categoryID == cid { return feed }
                return nil
            },
            set: { newValue in
                selectedFeed = newValue
            }
        )
    }
    
    var body: some View {
        Group {
            if let category = loadedCategory {
                LibraryCategoryView(
                    category: category,
                    libraryConfiguration: libraryConfiguration,
                    selectedFeed: effectiveSelectedFeed
                )
            } else {
                LoadingLibraryView()
            }
        }
        .task(id: categoryID) { @MainActor in
            let categories = Array(libraryConfiguration.getCategories() ?? [])
            self.loadedCategory = categories.first(where: { $0.id == categoryID })
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
enum ContentPaneRoute: Hashable {
    case userScripts
    case contentCategory(UUID)
}

@available(iOS 16.0, macOS 13.0, *)
private struct SidebarColumn: View {
    @EnvironmentObject private var viewModel: LibraryManagerViewModel
    @Binding var contentRoute: ContentPaneRoute?
    @Binding var sidebarPath: NavigationPath
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif
    var body: some View {
        NavigationStack(path: $sidebarPath) {
            LibraryCategoriesView()
#if os(iOS)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        if horizontalSizeClass == .compact {
                            DismissButton {
                                viewModel.isLibraryPresented = false
                            }
                        }
                    }
                }
#endif
        }
        .navigationDestination(for: FeedCategory.self) { category in
            Color.clear.onAppear {
                contentRoute = .contentCategory(category.id)
                sidebarPath = NavigationPath()
            }
        }
        .navigationDestination(for: LibraryRoute.self) { _ in
            Color.clear.onAppear {
                contentRoute = .userScripts
                sidebarPath = NavigationPath()
            }
        }
#if os(macOS)
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
#endif
    }
}

@available(iOS 16.0, macOS 13.0, *)
private struct LoadingLibraryView: View {
    var body: some View {
        VStack {
            Spacer()
            ProgressView("Loading Library…").padding()
            Spacer()
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
private struct SelectContentPlaceholderView: View {
    var body: some View {
        VStack {
            Spacer(minLength: 0)
            Text("Select a category or User Scripts")
                .foregroundStyle(.secondary)
                .font(.callout)
            Spacer(minLength: 0)
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
private struct SelectDetailPlaceholderView: View {
    var body: some View {
        VStack {
            Spacer()
            Text("Select a feed or script to edit.")
                .multilineTextAlignment(.center)
                .padding().padding()
                .foregroundColor(.secondary)
                .font(.callout)
            Spacer()
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
private struct ContentRouteSwitcher: View {
    @EnvironmentObject private var viewModel: LibraryManagerViewModel
    @Binding var contentRoute: ContentPaneRoute?
    
    var body: some View {
        Group {
            switch contentRoute {
            case .userScripts:
                LibraryScriptsListView(selectedScript: $viewModel.selectedScript)
                    .navigationTitle("User Scripts")
            case .contentCategory(let categoryID):
                if let libraryConfiguration = viewModel.libraryConfiguration {
                    LibraryCategoryViewContainer(
                        categoryID: categoryID,
                        libraryConfiguration: libraryConfiguration,
                        selectedFeed: $viewModel.selectedFeed
                    )
                } else {
                    LoadingLibraryView()
                }
            case .none:
                SelectContentPlaceholderView()
            }
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
private struct ContentColumn: View {
    @Binding var contentRoute: ContentPaneRoute?
    @Binding var middlePath: NavigationPath
    @Binding var detailPath: NavigationPath
    @EnvironmentObject private var viewModel: LibraryManagerViewModel
    
    var body: some View {
        NavigationStack(path: $middlePath) {
            ContentRouteSwitcher(contentRoute: $contentRoute)
        }
        .navigationDestination(for: FeedCategory.self) { category in
            Color.clear.onAppear {
                contentRoute = .contentCategory(category.id)
                middlePath = NavigationPath()
            }
        }
        .navigationDestination(for: LibraryRoute.self) { _ in
            Color.clear.onAppear {
                contentRoute = .userScripts
                middlePath = NavigationPath()
            }
        }
        .navigationDestination(for: Feed.self) { feed in
            Color.clear.onAppear {
                viewModel.selectedFeed = feed
                viewModel.selectedScript = nil
                detailPath = NavigationPath()
                detailPath.append(feed)
            }
        }
        .navigationDestination(for: UserScript.self) { script in
            Color.clear.onAppear {
                viewModel.selectedScript = script
                viewModel.selectedFeed = nil
                detailPath = NavigationPath()
                detailPath.append(script)
            }
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
private struct DetailColumn: View {
    @Binding var detailPath: NavigationPath
    
    var body: some View {
        NavigationStack(path: $detailPath) {
            SelectDetailPlaceholderView()
        }
#if os(macOS)
        .navigationDestination(for: Feed.self) { feed in
            ScrollView { LibraryFeedView(feed: feed) }
        }
#else
        .navigationDestination(for: Feed.self) { feed in
            LibraryFeedView(feed: feed)
        }
#endif
#if os(macOS)
        .navigationDestination(for: UserScript.self) { script in
            ScrollView { LibraryScriptForm(script: script) }
        }
#else
        .navigationDestination(for: UserScript.self) { script in
            LibraryScriptForm(script: script)
        }
#endif
    }
}

@available(iOS 16.0, macOS 13.0, *)
public struct LibraryManagerView: View {
    @EnvironmentObject private var viewModel: LibraryManagerViewModel
    
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var middlePath = NavigationPath()
    @State private var detailPath = NavigationPath()
    @State private var contentRoute: ContentPaneRoute? = nil
    @State private var sidebarPath = NavigationPath()
    
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif
    @AppStorage("appTint") private var appTint: Color = Color("AccentColor")
    
    @State private var libraryCategoryViewModel: LibraryCategoryViewModel?
    
    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarColumn(contentRoute: $contentRoute, sidebarPath: $sidebarPath)
        } content: {
            ContentColumn(contentRoute: $contentRoute, middlePath: $middlePath, detailPath: $detailPath)
        } detail: {
            DetailColumn(detailPath: $detailPath)
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: viewModel.selectedFeed) { feed in
            Task { @MainActor in
                if feed != nil {
                    viewModel.selectedScript = nil
                }
            }
        }
        .onChange(of: viewModel.selectedScript) { script in
            Task { @MainActor in
                if script != nil {
                    viewModel.selectedFeed = nil
                }
            }
        }
    }
    
    public init() {
    }
}
