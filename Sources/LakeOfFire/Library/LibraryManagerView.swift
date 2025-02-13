import SwiftUI
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
    @ObservedRealmObject var domain: UserScriptAllowedDomain
    
    var body: some View {
        TextField("Domain", text: $domain.domain, prompt: Text("example.com"))
#if os(iOS)
            .textInputAutocapitalization(.never)
#endif
    }
}

@available(iOS 16.0, macOS 13, *)
struct LibraryScriptForm: View {
    let script: UserScript
    
    func unfrozen(_ script: UserScript) -> UserScript {
        return script.isFrozen ? script.thaw() ?? script : script
    }
    
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
    
    @State private var libraryCategoryViewModel: LibraryCategoryViewModel?
    
    var body: some View {
        VStack(spacing: 0) {
            if let libraryCategoryViewModel = libraryCategoryViewModel {
                LibraryCategoryView()
                    .environmentObject(libraryCategoryViewModel)
                    .task {
                        if let feed = libraryCategoryViewModel.selectedFeed, feed.categoryID != category.id {
                            libraryCategoryViewModel.selectedFeed = nil
                        }
                        //                        let feedsToDeselect = viewModel.selectedFeed.filter { $0.category != category }
                        //                        feedsToDeselect.forEach {
                        //                            viewModel.selectedFeed.remove($0)
                        //                        }
                    }
            }
        }
        .task { @MainActor in
            libraryCategoryViewModel = LibraryCategoryViewModel(category: category, libraryConfiguration: libraryConfiguration, selectedFeed: $selectedFeed)
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
public struct LibraryManagerView: View {
    @EnvironmentObject private var viewModel: LibraryManagerViewModel
    
    @State private var columnVisibility = NavigationSplitViewVisibility.doubleColumn
    
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif
    @AppStorage("appTint") private var appTint: Color = Color("AccentColor")
    
    @State private var libraryCategoryViewModel: LibraryCategoryViewModel?
    
    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, sidebar: {
            NavigationStack(path: $viewModel.navigationPath) {
                LibraryCategoriesView()
#if os(iOS)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            if horizontalSizeClass == .compact {
                                Button {
                                    viewModel.isLibraryPresented = false
                                } label: {
                                    Text("Done")
                                        .bold()
                                }
                            }
                        }
                    }
#endif
                    .navigationDestination(for: FeedCategory.self) { category in
                        if let libraryConfiguration = viewModel.libraryConfiguration {
                            LibraryCategoryViewContainer(category: category, libraryConfiguration: libraryConfiguration, selectedFeed: $viewModel.selectedFeed)
                        }
                    }
                    .navigationDestination(for: LibraryRoute.self) { route in
                        // If we have more routes, gotta differentiate them here as a possible TODO.
                        LibraryScriptsListView(selectedScript: $viewModel.selectedScript)
                            .navigationTitle("User Scripts")
                    }
            }
#if os(macOS)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
#endif
        }, detail: {
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
                if viewModel.selectedFeed == nil && viewModel.selectedScript == nil {
                    Spacer()
                    Text("Select a category and feed to edit.\nImport or export user feeds (excluding Manabi Reader defaults) via the toolbar.")
                        .multilineTextAlignment(.center)
                        .padding().padding()
                        .foregroundColor(.secondary)
                        .font(.callout)
                    Spacer()
                }
            }
#if os(macOS)
            .textFieldStyle(.roundedBorder)
#endif
            //                .fixedSize(horizontal: false, vertical: true)
            //            }
            .toolbar {
#if os(iOS)
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        viewModel.isLibraryPresented = false
                    } label: {
                        Text("Done")
                            .bold()
                    }
                }
#endif
            }
        })
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
