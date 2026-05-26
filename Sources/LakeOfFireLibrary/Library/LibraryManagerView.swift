import SwiftUI
import RealmSwift
import FilePicker
import UniformTypeIdentifiers
import SwiftUIWebView
import LakeKit
import RealmSwiftGaps
import SwiftUtilities
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent

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
            LibraryCategoriesView(contentRoute: $contentRoute)
#if os(iOS)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        if horizontalSizeClass == .compact {
                            Button("Done") {
                                viewModel.isLibraryPresented = false
                            }
                            .bold()
                        }
                    }
                }
#endif
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
                if let libraryConfiguration = viewModel.libraryConfiguration,
                   let category = Array(libraryConfiguration.getCategories() ?? []).first(where: { $0.id == categoryID }) {
                    LibraryCategoryView(
                        category: category,
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
    @Binding var detailPath: NavigationPath
    @EnvironmentObject private var viewModel: LibraryManagerViewModel
    
    var body: some View {
        NavigationStack(path: $detailPath) {
            ContentRouteSwitcher(contentRoute: $contentRoute)
                .navigationDestination(for: Feed.self) { feed in
                    detailFormContainer {
                        LibraryFeedView(feed: feed)
                    }
                }
                .navigationDestination(for: UserScript.self) { script in
                    detailFormContainer {
                        LibraryScriptForm(script: script)
                    }
                }
        }
    }

    @ViewBuilder
    private func detailFormContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
#if os(macOS)
        ScrollView {
            content()
        }
        .textFieldStyle(.roundedBorder)
#else
        content()
#endif
    }
}

@available(iOS 16.0, macOS 13.0, *)
public struct LibraryManagerView: View {
    @EnvironmentObject private var viewModel: LibraryManagerViewModel
    
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var detailPath = NavigationPath()
    @State private var contentRoute: ContentPaneRoute? = nil
    @State private var sidebarPath = NavigationPath()
    
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif
    @AppStorage("appTint") private var appTint: Color = Color("AccentColor")
    
    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarColumn(contentRoute: $contentRoute, sidebarPath: $sidebarPath)
        } detail: {
            ContentColumn(contentRoute: $contentRoute, detailPath: $detailPath)
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: contentRoute) { _ in
            detailPath = NavigationPath()
            viewModel.selectedFeed = nil
            viewModel.selectedScript = nil
        }
        .onChange(of: viewModel.selectedFeed) { feed in
            Task { @MainActor in
                if feed != nil {
                    viewModel.selectedScript = nil
                    syncDetailNavigationPath()
                } else if viewModel.selectedScript == nil {
                    detailPath = NavigationPath()
                }
            }
        }
        .onChange(of: viewModel.selectedScript) { script in
            Task { @MainActor in
                if script != nil {
                    viewModel.selectedFeed = nil
                    syncDetailNavigationPath()
                } else if viewModel.selectedFeed == nil {
                    detailPath = NavigationPath()
                }
            }
        }
    }

    private func syncDetailNavigationPath() {
        var path = NavigationPath()
        if let feed = viewModel.selectedFeed {
            path.append(feed)
        } else if let script = viewModel.selectedScript {
            path.append(script)
        }
        detailPath = path
    }
    
    public init() {
    }
}
