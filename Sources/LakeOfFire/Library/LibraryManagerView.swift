import SwiftUI
import RealmSwift
import FilePicker
import UniformTypeIdentifiers
import SwiftUIWebView
import LakeKit
import RealmSwiftGaps
import SwiftUtilities

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
                            DismissButton {
                                viewModel.isLibraryPresented = false
                            }
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
    @Binding var middlePath: NavigationPath
    @Binding var detailPath: NavigationPath
    @EnvironmentObject private var viewModel: LibraryManagerViewModel
    
    var body: some View {
        NavigationStack(path: $middlePath) {
            ContentRouteSwitcher(contentRoute: $contentRoute)
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
private struct DetailColumn: View {
    @Binding var detailPath: NavigationPath
    @EnvironmentObject private var viewModel: LibraryManagerViewModel
    
    var body: some View {
        NavigationStack(path: $detailPath) {
            Group {
                if let feed = viewModel.selectedFeed {
#if os(macOS)
                    ScrollView { LibraryFeedView(feed: feed) }
#else
                    LibraryFeedView(feed: feed)
#endif
                } else if let script = viewModel.selectedScript {
#if os(macOS)
                    ScrollView { LibraryScriptForm(script: script) }
#else
                    LibraryScriptForm(script: script)
#endif
                } else {
                    SelectDetailPlaceholderView()
                }
            }
        }
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
