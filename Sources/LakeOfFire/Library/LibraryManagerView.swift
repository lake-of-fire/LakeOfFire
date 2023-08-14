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
struct LibraryScriptFormSections: View {
    @ObservedRealmObject var script: UserScript
    
    @ScaledMetric(relativeTo: .body) private var textEditorHeight = 200
    @ScaledMetric(relativeTo: .body) private var readerPreviewHeight = 350
    @ScaledMetric(relativeTo: .body) private var compactReaderPreviewHeight = 270
    
    //    @State private var readerContent: (any ReaderContentModel) = ReaderContentLoader.unsavedHome
    @State private var webState = WebViewState.empty
    @State private var webNavigator = WebViewNavigator()
    @StateObject private var webViewModel = ReaderViewModel(realmConfiguration: LibraryDataManager.realmConfiguration, systemScripts: [])
    @StateObject private var readerModeViewModel = ReaderViewModel(realmConfiguration: LibraryDataManager.realmConfiguration, systemScripts: [])
    
    @State private var scriptTitle = ""
    @State private var scriptText = ""
    @AppStorage("LibraryScriptFormSections.isPreviewReaderMode") private var isPreviewReaderMode = true
    @AppStorage("LibraryScriptFormSections.isWordWrapping") private var isWordWrapping = true
    
    @State var webViewUserScripts =  LibraryConfiguration.shared.activeWebViewUserScripts
    @State var webViewSystemScripts = LibraryConfiguration.shared.systemScripts
    
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif
    
    private func unfrozen(_ script: UserScript) -> UserScript {
        return script.isFrozen ? script.thaw() ?? script : script
    }
    
    private var unfrozenScript: UserScript {
        return unfrozen(script)
    }
    
    private var computedReaderPreviewHeight: CGFloat {
#if os(iOS)
        if horizontalSizeClass == .compact {
            return compactReaderPreviewHeight
        }
#endif
        return readerPreviewHeight
    }
    
    var body: some View {
        if let opmlURL = script.opmlURL, LibraryConfiguration.opmlURLs.contains(opmlURL)  {
            Section("Synchronized") {
                Text("Manabi Reader manages this User Script for you.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        
        Section("User Script") {
            Toggle("Enabled", isOn: Binding(get: { !script.isArchived }, set: { isEnabled in
                safeWrite(script) { $1.isArchived = !isEnabled }}))
            TextField("Script Title", text: $scriptTitle, prompt: Text("Enter user script title"))
#if os(macOS)
            LabeledContent("Execution Options") {
                Toggle("Inject At Document Start", isOn: $script.injectAtStart)
                Toggle("Main Frame Only", isOn: $script.mainFrameOnly)
                Toggle("Sandboxed", isOn: $script.sandboxed)
            }
#else
            Toggle("Inject At Document Start", isOn: $script.injectAtStart)
            Toggle("Main Frame Only", isOn: $script.mainFrameOnly)
            Toggle("Sandboxed", isOn: $script.sandboxed)
#endif
        }
        .disabled(!script.isUserEditable)
        if let opmlURL = script.opmlURL {
            Section("Synchronization") {
                if LibraryConfiguration.opmlURLs.contains(opmlURL) {
                    Text("Manabi Reader manages and actively improves this user script for you.")
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Synchronized with: \(opmlURL.absoluteString)")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        Section(header: Text("Allowed Domains"), footer: Text("Top-level hostnames of domains this script is allowed to run on. No support for wildcards or subdomains. All subdomains are matched against their top-level parent domain. Leave empty for access to all domains.").font(.footnote).foregroundColor(.secondary)) {
            ForEach(script.allowedDomains.where({ $0.isDeleted == false })) { (domain: UserScriptAllowedDomain) in
                let domain = domain.isFrozen ? domain.thaw() ?? domain : domain
                UserScriptAllowedDomainCell(domain: domain)
                    .disabled(!script.isUserEditable)
                    .deleteDisabled(!script.isUserEditable)
                    .contextMenu {
                        if script.isUserEditable {
                            Button(role: .destructive) {
                                safeWrite(script) { _, script in
                                    if let idx = script.allowedDomains.index(of: domain) {
                                        script.allowedDomains.remove(at: idx)
                                    }
                                }
                            } label: {
                                Text("Delete")
                            }
                            .tint(.red)
                        }
                    }
            }
            .onDelete(perform: $script.allowedDomains.remove)
            
            Button {
                $script.allowedDomains.append(UserScriptAllowedDomain())
            } label: {
                Label("Add Domain", systemImage: "plus.circle")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if script.allowedDomains.isEmpty {
                Label("Granted access to all web domains", systemImage: "exclamationmark.triangle.fill")
            }
        }
        
        Section(header: Text("JavaScript"), footer: Text("This JavaScript will run on every page load. It has access to the DOM and runs in a sandbox independent of other user and system scripts. User Script execution order is not guaranteed. Use Safari Developer Tools to inspect.").font(.footnote).foregroundColor(.secondary)) {
            CodeEditor(text: $scriptText, isWordWrapping: isWordWrapping)
                .frame(idealHeight: textEditorHeight)
            //            Toggle("Word Wrap", isOn: $isWordWrapping)
        }
        .task {
            Task { @MainActor in
                scriptTitle = script.title
                scriptText = script.script
            }
        }
        .onChange(of: scriptTitle, debounceTime: 0.1) { text in
            Task.detached {
                await safeWrite(script) { _, script in
                    script.title = text
                }
            }
        }
        .onChange(of: scriptText, debounceTime: 0.75) { scriptText in
            Task.detached {
                await safeWrite(script) { _, script in
                    script.script = scriptText
                }
            }
        }
        .onChange(of: script.script, debounceTime: 1.5) { _ in
            Task { @MainActor in
                refresh(forceRefresh: true)
            }
        }
        
        Section {
            HStack {
                TextField("Preview URL", text: Binding(
                    get: { script.previewURL?.absoluteString ?? "" },
                    set: { url in
                        guard script.previewURL?.absoluteString != url else { return }
                        safeWrite(script) { _, script in
                            script.previewURL = URL(string: url)
                        }
                    }), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in
                        safeWrite(script) { _, script in
                            script.previewURL = URL(string: (strings.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? URL(string: "about:blank")!
                        }
                    }
                }
                Button {
                    refresh(forceRefresh: true)
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .labelStyle(.iconOnly)
            }
            if script.previewURL != nil {
                Toggle("Reader Mode", isOn: $isPreviewReaderMode)
                /*
                 GroupBox("Reader Mode") {
                 if !readerModeViewModel.content.isReaderModeAvailable {
                 Text("Reader Mode currently unavailable for this URL.")
                 .foregroundColor(.secondary)
                 .padding(5)
                 }
                 Reader(readerViewModel: readerModeViewModel, state: $readerState, action: $readerAction, wordTrackingStats: .constant(nil), isPresentingReaderSettings: .constant(false), forceReaderModeWhenAvailable: true)
                 .frame(width: readerModeViewModel.content.isReaderModeAvailable ? computedReaderPreviewHeight : 0, height: readerModeViewModel.content.isReaderModeAvailable ? nil : 0)
                 .clipShape(RoundedRectangle(cornerRadius: 8))
                 .onAppear {
                 refresh()
                 }
                 }
                 GroupBox("Web Original") {
                 Reader(readerViewModel: webViewModel, state: $webState, action: $webAction, wordTrackingStats: .constant(nil), isPresentingReaderSettings: .constant(false))
                 .clipShape(RoundedRectangle(cornerRadius: 8))
                 .frame(idealHeight: readerPreviewHeight)
                 }*/
                Group {
                    if isPreviewReaderMode {
                        Reader(
                            readerViewModel: readerModeViewModel,
                            forceReaderModeWhenAvailable: false,
                            /*persistentWebViewID: "library-script-preview-\(script.id.uuidString)",*/
                            bounces: false)
                    } else {
                        WebView(
                            config: WebViewConfig(userScripts: [script.webViewUserScript]),
                            navigator: webNavigator,
                            state: $webState,
                            bounces: false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(idealHeight: readerPreviewHeight)
                .task {
                    refresh()
                }
                //                .onAppear {
                //                    refresh()
                //                }
            } else {
                Text("Enter URL to view preview.")
                    .foregroundColor(.secondary)
            }
        }
        .listRowSeparator(.hidden, edges: .all)
        .onChange(of: script.previewURL, debounceTime: 0.5) { url in
            guard let url = url else { return }
            refresh(url: url)
        }
    }
    
    private func refresh(url: URL? = nil, forceRefresh: Bool = false) {
        Task { @MainActor in
            guard let url = url ?? script.previewURL else { return }
            if webState.pageURL != url || forceRefresh {
                webNavigator.load(URLRequest(url: url))
            }
            if readerModeViewModel.state.pageURL != url || forceRefresh {
                readerModeViewModel.navigator.load(URLRequest(url: url))
            }
        }
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
struct LibraryScriptsListView: View {
    @Binding var selectedScript: UserScript?
    
    @ObservedRealmObject private var libraryConfiguration: LibraryConfiguration = .shared
    
#if os(iOS)
    @ScaledMetric(relativeTo: .largeTitle) private var scaledCategoryHeight: CGFloat = 50
#else
    @ScaledMetric(relativeTo: .largeTitle) private var scaledCategoryHeight: CGFloat = 32
#endif
    
    func unfrozen(_ category: FeedCategory) -> FeedCategory {
        return category.isFrozen ? category.thaw() ?? category : category
    }
    
    var addScriptButtonPlacement: ToolbarItemPlacement {
#if os(iOS)
        return .bottomBar
#else
        return .automatic
#endif
    }
    
    var body: some View {
        ScrollViewReader { scrollProxy in
            List(selection: $selectedScript) {
                ForEach(libraryConfiguration.userScripts) { script in
                    VStack(alignment: .leading) {
                        Group {
                            if script.title.isEmpty {
                                Text("Untitled Script")
                                    .foregroundColor(.secondary)
                            } else {
                                Text(script.title)
                            }
                        }
                        .foregroundColor(script.isArchived ? .secondary : .primary)
                        Group {
                            if script.isArchived {
                                Text("Disabled")
                                    .foregroundColor(.secondary)
                            } else {
                                if let opmlURL = script.opmlURL, LibraryConfiguration.opmlURLs.contains(opmlURL) {
                                    Text("Official Manabi Reader system script")
                                        .bold()
                                } else {
                                    if script.allowedDomains.isEmpty {
                                        Label("Granted access to all web domains", systemImage: "exclamationmark.triangle.fill")
                                    }
                                }
                            }
                        }
                        .font(.caption)
                    }
                    .tag(script)
                    //                    .listRowSeparator(.hidden)
                    .deleteDisabled(!script.isUserEditable)
                    .moveDisabled(!script.isUserEditable)
                    //                    .id("library-sidebar-\(script.id.uuidString)")
                }
                .onMove(perform: $libraryConfiguration.userScripts.move)
                .onDelete(perform: deleteScript)
            }
#if os(iOS)
            .listStyle(.insetGrouped)
#endif
#if os(macOS)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 0) {
                    addScriptButton(scrollProxy: scrollProxy)
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
                ToolbarItem(placement: addScriptButtonPlacement) {
                    addScriptButton(scrollProxy: scrollProxy)
                }
            }
#endif
        }
    }
    
    func addScriptButton(scrollProxy: ScrollViewProxy) -> some View {
        Button {
            let script = LibraryDataManager.shared.createEmptyScript(addToLibrary: true)
            Task { @MainActor in
                scrollProxy.scrollTo("library-sidebar-\(script.id.uuidString)")
            }
        } label: {
            Label("Add Script", systemImage: "plus.circle")
                .labelStyle(.titleAndIcon)
        }
        .keyboardShortcut("n", modifiers: [.command])
    }
    
    func deleteScript(_ script: UserScript) {
        if !script.isUserEditable || (script.isArchived && script.opmlURL != nil) {
            return
        }
        
        safeWrite(libraryConfiguration) { realm, libraryConfiguration in
            guard let script = realm?.object(ofType: UserScript.self, forPrimaryKey: script.id) else { return }
            if let idx = libraryConfiguration.userScripts.firstIndex(of: script) {
                libraryConfiguration.userScripts.remove(at: idx)
            }
        }
        
        safeWrite(script) { _, script in
            if script.isArchived, let opmlURL = script.opmlURL, !LibraryConfiguration.opmlURLs.contains(opmlURL) {
                script.isDeleted = true
            } else if script.isArchived && script.opmlURL == nil {
                script.isDeleted = true
            } else if !script.isArchived {
                script.isArchived = true
            }
        }
    }
    
    func deleteScript(at offsets: IndexSet) {
        for offset in offsets {
            let script = libraryConfiguration.userScripts[offset]
            guard script.isUserEditable else { continue }
            deleteScript(script)
        }
    }
    
    func restoreScript(_ script: UserScript) {
        guard script.isUserEditable else { return }
        safeWrite(script) { _, script in
            script.isArchived = false
        }
        safeWrite(libraryConfiguration) { realm, libraryConfiguration in
            guard let script = realm?.object(ofType: UserScript.self, forPrimaryKey: script.id) else { return }
            if !libraryConfiguration.userScripts.contains(script) {
                libraryConfiguration.userScripts.append(script)
            }
        }
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
struct LibraryCategoriesView: View {
    @StateObject var viewModel = LibraryManagerViewModel.shared
    
    @ObservedRealmObject private var libraryConfiguration: LibraryConfiguration = .shared
    
    @AppStorage("appTint") private var appTint: Color = .accentColor
    
    @ObservedResults(FeedCategory.self, configuration: LibraryDataManager.realmConfiguration, where: { $0.isDeleted == false }) private var categories
    private var archivedCategories: [FeedCategory] {
        Array(categories.filter({ $0.isArchived || !libraryConfiguration.categories.contains($0) }))
    }
    
#if os(macOS)
    @State private var savePanel: NSSavePanel?
    @State private var window: NSWindow?
#endif

    var addButtonPlacement: ToolbarItemPlacement {
#if os(iOS)
        return .bottomBar
#else
        return .automatic
#endif
    }
    
    var body: some View {
        ScrollViewReader { scrollProxy in
            List {
                Section(header: Text("Import and Export"), footer: Text("Imports and exports use the OPML file format, which is optimized for RSS reader compatibility. The User Scripts category is supported for importing/exporting. User Library exports exclude Manabi Reader system-provided data.").font(.footnote).foregroundColor(.secondary)) {
                    ShareLink(item: viewModel.exportedOPMLFileURL ?? URL(string: "about:blank")!, message: Text(""), preview: SharePreview("Manabi Reader User Feeds OPML File", image: Image(systemName: "doc"))) {
                        Text("Share User Library…")
                            .frame(maxWidth: .infinity)
                    }
                    .labelStyle(.titleAndIcon)
                    .disabled(viewModel.exportedOPML == nil)
#if os(macOS)
                    Button {
                        savePanel = savePanel ?? NSSavePanel()
                        guard let savePanel = savePanel else { return }
                        savePanel.allowedContentTypes = [UTType(exportedAs: "public.opml")]
                        savePanel.allowsOtherFileTypes = false
                        savePanel.prompt = "Export OPML"
                        savePanel.title = "Export OPML"
                        savePanel.nameFieldLabel = "Export to:"
                        savePanel.message = "Choose a location for the exported OPML file."
                        savePanel.isExtensionHidden = false
                        savePanel.nameFieldStringValue = "ManabiReaderUserLibrary.opml"
                        guard let window = window else { return }
                        savePanel.beginSheetModal(for: window) { result in
                            if result == NSApplication.ModalResponse.OK, let url = savePanel.url, let opml = viewModel.exportedOPML {
                                Task { @MainActor in
//                                    let filename = url.lastPathComponent
                                    do {
                                        try opml.xml.write(to: url, atomically: true, encoding: String.Encoding.utf8)
                                    }
                                    catch let error as NSError {
                                        NSApplication.shared.presentError(error)
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("Export User Library…", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .background(WindowAccessor(for: $window))
                    .disabled(viewModel.exportedOPML == nil)
#endif
                    FilePicker(types: [UTType(exportedAs: "public.opml"), .xml], allowMultiple: true, afterPresented: nil, onPicked: { urls in
                        Task.detached {
                            LibraryDataManager.shared.importOPML(fileURLs: urls)
                        }
                    }, label: {
                        Label("Import User Library…", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    })
                    
                }
                .labelStyle(.titleOnly)
                .tint(appTint)
                Section("Extensions") {
                    NavigationLink(value: LibraryRoute.userScripts, label: {
                        Label("User Scripts", systemImage: "wrench.and.screwdriver")
                    })
                }
                Section("Library") {
                    ForEach(libraryConfiguration.categories) { category in
                        NavigationLink(value: category) {
                            FeedCategoryButtonLabel(category: category, font: .headline, isCompact: true)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .listRowSeparator(.hidden)
                        .deleteDisabled(!category.isUserEditable)
                        .moveDisabled(!category.isUserEditable)
                        .contextMenu {
                            if category.isUserEditable {
                                Button {
                                    deleteCategory(category)
                                } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                            }
                        }
//                        .id("library-sidebar-\(category.id.uuidString)")
                    }
                    .onMove(perform: $libraryConfiguration.categories.move)
                    .onDelete(perform: deleteCategory)
                }
                Section("Archive") {
                    ForEach(archivedCategories) { category in
                        NavigationLink(value: category) {
                            FeedCategoryButtonLabel(category: category, font: .headline, isCompact: true)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .saturation(0)
                        }
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .leading) {
                            Button {
                                restoreCategory(category)
                            } label: {
                                Label("Restore", systemImage: "plus")
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deleteCategory(category)
                            } label: {
                                Text("Delete")
                            }
                            .tint(.red)
                        }
                        .contextMenu {
                            if category.isUserEditable {
                                Button {
                                    restoreCategory(category)
                                } label: {
                                    Label("Restore", systemImage: "plus")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    deleteCategory(category)
                                } label: {
                                    Text("Delete")
                                }
                                .tint(.red)
                            }
                        }
//                        .id("library-sidebar-\(category.id.uuidString)")
                    }
                    .onDelete(perform: { deleteCategory(at: $0) })
                }
            }
            .listStyle(.sidebar)
#if os(macOS)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 0) {
                    addCategoryButton(scrollProxy: scrollProxy)
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
                ToolbarItem(placement: addButtonPlacement) {
                    addCategoryButton(scrollProxy: scrollProxy)
                }
            }
#endif
        }
    }
    
    func addCategoryButton(scrollProxy: ScrollViewProxy) -> some View {
        Button {
            let category = LibraryDataManager.shared.createEmptyCategory(addToLibrary: true)
            Task { @MainActor in
                scrollProxy.scrollTo("library-sidebar-\(category.id.uuidString)")
            }
        } label: {
            Label("Add User Category", systemImage: "plus.circle")
                .labelStyle(.titleAndIcon)
        }
    }

    func deleteCategory(_ category: FeedCategory) {
        if !category.isUserEditable || (category.isArchived && category.opmlURL != nil) {
            return
        }
        
        safeWrite(libraryConfiguration) { realm, libraryConfiguration in
            guard let category = realm?.object(ofType: FeedCategory.self, forPrimaryKey: category.id) else { return }
            if let idx = libraryConfiguration.categories.firstIndex(of: category) {
                libraryConfiguration.categories.remove(at: idx)
            }
        }
        
        safeWrite(category) { _, category in
            if category.isArchived && !LibraryConfiguration.opmlURLs.map({ $0 }).contains(category.opmlURL) {
                category.isDeleted = true
            } else if !category.isArchived {
                category.isArchived = true
            }
        }
    }
    
    func deleteCategory(at offsets: IndexSet) {
        for offset in offsets {
            let category = libraryConfiguration.categories[offset]
            guard category.isUserEditable else { continue }
            deleteCategory(category)
        }
    }
    
    func restoreCategory(_ category: FeedCategory) {
        guard category.isUserEditable else { return }
        safeWrite(category) { _, category in
            category.isArchived = false
        }
        safeWrite(libraryConfiguration) { realm, libraryConfiguration in
            guard let category = realm?.object(ofType: FeedCategory.self, forPrimaryKey: category.id) else { return }
            if !libraryConfiguration.categories.contains(category) {
                libraryConfiguration.categories.append(category)
            }
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
public struct LibraryManagerView: View {
    @Binding var isPresented: Bool
//    @ObservedRealmObject var libraryConfiguration: LibraryConfiguration
    @ObservedObject var viewModel: LibraryManagerViewModel
    
    @ObservedRealmObject private var libraryConfiguration = LibraryConfiguration.shared
    
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
