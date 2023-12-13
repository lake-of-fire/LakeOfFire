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
struct LibraryCategoryView: View {
    @ObservedRealmObject var category: FeedCategory
    @Binding var selectedFeed: Feed?
    @StateObject var viewModel = LibraryManagerViewModel.shared
    
#if os(iOS)
    @ScaledMetric(relativeTo: .largeTitle) private var scaledCategoryHeight: CGFloat = 50
#else
    @ScaledMetric(relativeTo: .largeTitle) private var scaledCategoryHeight: CGFloat = 32
#endif
    
    @State private var categoryTitle = ""
    
    func unfrozen(_ category: FeedCategory) -> FeedCategory {
        return category.isFrozen ? category.thaw() ?? category : category
    }
    
    var addFeedButtonPlacement: ToolbarItemPlacement {
#if os(iOS)
        return .bottomBar
#else
        return .automatic
#endif
    }
    
    private func matchingDistinctFeed(category: FeedCategory, feed: Feed) -> Feed? {
        return category.feeds.where { $0.isDeleted == false }.first(where: { $0.rssUrl == feed.rssUrl && $0.id != feed.id })
    }
    
    func duplicationMenu(feed: Feed) -> some View {
        Menu("Duplicate In…") {
            ForEach(LibraryConfiguration.shared.categories.filter({ $0.isUserEditable })) { (category: FeedCategory) in
                if matchingDistinctFeed(category: category, feed: feed) != nil { //}, matchingFeed?.category.id != feed.category.id {
                    Menu(category.title) {
                        Button("Overwrite Existing Feed") {
                            viewModel.duplicate(feed: feed, inCategory: category, overwriteExisting: true)
                        }
                        Button("Duplicate") {
                            viewModel.duplicate(feed: feed, inCategory: category, overwriteExisting: false)
                        }
                    }
                } else {
                    Button {
                        viewModel.duplicate(feed: feed, inCategory: category, overwriteExisting: false)
                    } label: {
                        Text(category.title)
                    }
                }
            }
        }
    }
    
    var body: some View {
        ScrollViewReader { scrollProxy in
            List(selection: $selectedFeed) {
                Section(header: Text("Category"), footer: Text("Enter an image URL to show as the category button background.").font(.footnote).foregroundColor(.secondary)) {
                    ZStack {
                        FeedCategoryImage(category: category)
                            .allowsHitTesting(false)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .frame(maxHeight: scaledCategoryHeight)
                        TextField("Title", text: $categoryTitle, prompt: Text("Enter title"))
                            .lineLimit(1)
                            .multilineTextAlignment(.center)
                            .font(.title3.bold())
                            .foregroundColor(.white)
                            .background { Color.clear }
//                            .backgroundColor(.clear)
                            .padding(.horizontal)
                            .background(.ultraThinMaterial)
                            .padding(.horizontal, 10)
                    }
                    .frame(maxHeight: scaledCategoryHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    
                    TextField("Background Image URL", text: Binding(
                        get: { category.backgroundImageUrl.absoluteString },
                        set: { imageURL in
                            guard category.backgroundImageUrl.absoluteString != imageURL else { return }
                            safeWrite(category) { _, category in
                                unfrozen(category).backgroundImageUrl = URL(string: imageURL) ?? URL(string: "about:blank")!
                            }
                        }), axis: .vertical)
                    .lineLimit(2)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                }
                if let opmlURL = category.opmlURL {
                    Section("Synchronized") {
                        if LibraryConfiguration.opmlURLs.contains(opmlURL) {
                            Text("Manabi Reader manages and actively improves this category for you.")
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Synchronized with: \(opmlURL.absoluteString)")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Section("Feeds") {
                    ForEach(category.feeds.where({ $0.isDeleted == false }).sorted(by: \.title)) { feed in
                        NavigationLink(value: feed) {
                            FeedCell(feed: feed, includesDescription: false, horizontalSpacing: 5)
                        }
                        .deleteDisabled(!feed.isUserEditable)
                        .contextMenu {
                            duplicationMenu(feed: feed)
                            if feed.isUserEditable {
                                Divider()
                                Button(role: .destructive) {
                                    deleteFeed(feed)
                                } label: {
                                    Text("Delete")
                                }
                                .tint(.red)
                            }
                        }
                    }
                    .onDelete(perform: { deleteFeed(at: $0) })
                }
            }
#if os(iOS)
            .listStyle(.insetGrouped)
#endif
#if os(macOS)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 0) {
                    addFeedButton(scrollProxy: scrollProxy)
                        .buttonStyle(.borderless)
                        .padding()
                    Spacer(minLength: 0)
                }
            }
#endif
#if os(iOS)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
                ToolbarItem(placement: addFeedButtonPlacement) {
                    addFeedButton(scrollProxy: scrollProxy)
                }
            }
#endif
            .task {
                Task { @MainActor in
                    categoryTitle = category.title
                }
            }
            .onChange(of: categoryTitle, debounceTime: 0.1) { text in
                Task.detached {
                    await safeWrite(category) { _, category in
                        category.title = text
                    }
                }
            }
        }
    }
    
    func addFeedButton(scrollProxy: ScrollViewProxy) -> some View {
        Button {
            let category = unfrozen(category)
            let feed = LibraryDataManager.shared.createEmptyFeed(inCategory: category)
            Task { @MainActor in
                scrollProxy.scrollTo("library-sidebar-\(feed.id.uuidString)")
            }
        } label: {
            Label("Add Feed", systemImage: "plus.circle")
                .labelStyle(.titleAndIcon)
        }
        .disabled(category.opmlURL != nil)
        .keyboardShortcut("n", modifiers: [.command])
    }

    func deleteFeed(_ feed: Feed) {
        guard feed.isUserEditable else { return }
        safeWrite(feed) { _, feed in
            feed.isDeleted = true
        }
    }
    
    func deleteFeed(at offsets: IndexSet) {
        if category.opmlURL != nil {
            return
        }
        
        for offset in offsets {
            let feed = category.feeds[offset]
            guard feed.isUserEditable else { continue }
            deleteFeed(feed)
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
public struct LibraryManagerView: View {
    @Binding var isPresented: Bool
    @ObservedObject var viewModel: LibraryManagerViewModel
    
    @ObservedResults(FeedCategory.self, configuration: LibraryDataManager.realmConfiguration, where: { $0.isDeleted == false }) private var categories
    @ObservedResults(Feed.self, configuration: LibraryDataManager.realmConfiguration, where: { $0.isDeleted == false }) private var feeds
    
    @State private var columnVisibility = NavigationSplitViewVisibility.doubleColumn
    
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif
    @AppStorage("appTint") private var appTint: Color = Color("AccentColor")
    
    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, sidebar: {
            NavigationStack(path: $viewModel.navigationPath) {
                LibraryCategoriesView(viewModel: viewModel)
                    .navigationDestination(for: FeedCategory.self) { category in
                        LibraryCategoryView(category: category, selectedFeed: $viewModel.selectedFeed)
                            .task {
                                if let feed = viewModel.selectedFeed, feed.category != category {
                                    viewModel.selectedFeed = nil
                                }
                                //                        let feedsToDeselect = viewModel.selectedFeed.filter { $0.category != category }
                                //                        feedsToDeselect.forEach {
                                //                            viewModel.selectedFeed.remove($0)
                                //                        }
                            }
                    }
                    .navigationDestination(for: LibraryRoute.self) { route in
                        // If we have more routes, gotta differentiate them here as a possible TODO.
                        LibraryScriptsListView(selectedScript: $viewModel.selectedScript)
                            .navigationTitle("User Scripts")
                    }
            }
#if os(macOS)
            .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 300)
#endif
#if os(iOS)
            .toolbar {
                if horizontalSizeClass == .compact {
                    ToolbarItem(placement: .confirmationAction) {
                        HStack(spacing: 12) {
                            Button {
                                isPresented = false
                            } label: {
                                Text("Done")
                                    .bold()
                            }
                        }
                    }
                }
            }
#endif
        }, detail: {
            Group {
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
                    VStack {
                        Spacer()
                        Text("Select a category and feed to edit.\nImport or export user feeds (excluding Manabi Reader defaults) via the toolbar.")
                            .multilineTextAlignment(.center)
                            .padding().padding()
                            .foregroundColor(.secondary)
                            .font(.callout)
                        Spacer()
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            //                .fixedSize(horizontal: false, vertical: true)
            //            }
            .toolbar {
#if os(iOS)
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        isPresented = false
                    } label: {
                        Text("Done")
                            .bold()
                    }
                }
#endif
            }
        })
        .navigationSplitViewStyle(.balanced)
        .environmentObject(viewModel)
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
    
    public init(isPresented: Binding<Bool>, viewModel: LibraryManagerViewModel = LibraryManagerViewModel.shared) {
        _isPresented = isPresented
        self.viewModel = viewModel
    }
}
