import SwiftUI
import RealmSwift
import SwiftUIDownloads
import SwiftUtilities
import SwiftUIBackports
import RealmSwiftGaps
import SwiftUIWebView

public enum LightModeTheme: String, CaseIterable, Identifiable {
    case white
    case beige
    
    public var id: String { self.rawValue }
}
public enum DarkModeTheme: String, CaseIterable, Identifiable {
    case gray
    case black
    
    public var id: String { self.rawValue }
}

struct ReaderSettingsForm: View {
    @ScaledMetric(relativeTo: .body) private var defaultFontSize: CGFloat = Font.pointSize(for: Font.TextStyle.body) + 4
    @AppStorage("readerFontSize") private var readerFontSize: Double?
    @AppStorage("lightModeTheme") private var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") private var darkModeTheme: DarkModeTheme = .black
    @AppStorage("appTint") private var appTint = Color.accentColor
    
    var body: some View {
        Form {
            Section("Display") {
                Stepper("Font Size: \(Int(round(readerFontSize ?? defaultFontSize))) px", value: Binding(get: { CGFloat(readerFontSize ?? defaultFontSize) }, set: { readerFontSize = Double($0) }), in: 5...160)
                Picker("Light Mode Theme", selection: $lightModeTheme) {
                    ForEach(LightModeTheme.allCases) { theme in
                        Text(theme.rawValue.capitalized).tag(theme)
                    }
                }
                Picker("Dark Mode Theme", selection: $darkModeTheme) {
                    ForEach(DarkModeTheme.allCases) { theme in
                        Text(theme.rawValue.capitalized).tag(theme)
                    }
                }
            }
        }
        .groupedFormStyleIfAvailable()
    }
}

public struct DataSettingsForm: View {
    @State private var isPresentingUnsavedRSSFeedEntryDeletionAlert: Bool = false
    @State private var isPresentingUnsavedReadingHistoryDeletionAlert: Bool = false
    
    @AppStorage("developerToolsEnabled") private var developerToolsEnabled = false
    
    public var body: some View {
        Form {
            Section("Local & iCloud Data") {
                GroupBox("Downloads") {
                    ForEach(Array(DownloadController.shared.assuredDownloads)) { downloadable in
                        DownloadProgress(download: downloadable, retryAction: {
                            Task { @MainActor in
                                await DownloadController.shared.ensureDownloaded([downloadable])
                            }
                        }, redownloadAction: {
                            Task { @MainActor in
                                await DownloadController.shared.download(downloadable)
                            }
                        })
                        .padding(5)
                        Divider()
                    }
                }
                Button("Clear Unsaved Web History") {
                    isPresentingUnsavedReadingHistoryDeletionAlert = true
                }
                .confirmationDialog("Clear Unsaved Web History?", isPresented: $isPresentingUnsavedReadingHistoryDeletionAlert) {
                    Button("Clear Unsaved Web History", role: .destructive) {
                        Task { @RealmBackgroundActor in
                             let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.historyRealmConfiguration)
//                            await realm.asyncRefresh()
                            try await realm.asyncWrite {
                                for record in realm.objects(HistoryRecord.self).where({ !$0.isDeleted }) {
                                    record.isDeleted = true
                                    record.refreshChangeMetadata(explicitlyModified: true)
                                }
                            }
//                            realm.refresh() // ?
                        }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This will delete your reading and web history, excluding pages you saved as bookmarks. This data is persisted on your device and in your personal iCloud account and is not otherwise shared online without any explicit share action.")
                }
                
                Button("Clear Unsaved RSS Feed Entries") {
                    isPresentingUnsavedRSSFeedEntryDeletionAlert = true
                }
                .confirmationDialog("Clear Unsaved RSS Feed Entries?", isPresented: $isPresentingUnsavedRSSFeedEntryDeletionAlert) {
                    Button("Clear Unsaved RSS Feed Entries", role: .destructive) {
                        Task { @RealmBackgroundActor in
                            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: LibraryDataManager.realmConfiguration) 
//                            await realm.asyncRefresh()
                            try await realm.asyncWrite {
                                for entry in realm.objects(FeedEntry.self).where({ !$0.isDeleted }) {
                                    entry.isDeleted = true
                                    entry.refreshChangeMetadata(explicitlyModified: true)
                                }
                            }
//                            realm.refresh() // ?
                        }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This will delete RSS feed entries that have not been saved. This data is persisted on your device and in your personal iCloud account and is not shared online without any explicit share action.")
                }
                
                /*
                if #available(iOS 16, macOS 13, *) {
                    Divider()
                    Toggle("Developer Tools", isOn: $developerToolsEnabled)
                }
                 */
            }
        }
        .groupedFormStyleIfAvailable()
    }
    
    public init() { }
}

struct ReaderSettings: View {
    @Binding var isPresented: Bool
    
    @SceneStorage("settingsTabSelection") private var settingsTabSelection = 0
    
    var body: some View {
        HStack {
            Picker("", selection: $settingsTabSelection) {
                Text("Web").tag(0)
                Text("Data").tag(2)
                //            Text("Debug").tag(1)
            }
            .pickerStyle(SegmentedPickerStyle())
            
#if os(iOS)
            Button {
                isPresented = false
            } label: {
                DismissalButtonLabel()
            }
#endif
        }
        .padding(.top, 12)
        .padding(.trailing, 12)
#if os(iOS)
        .padding(.leading, 12)
#endif
        Group {
            let height: CGFloat = 575
            if settingsTabSelection == 0 {
                ReaderSettingsForm()
                    .frame(idealWidth: 450, maxWidth: 520, minHeight: 290, idealHeight: height)
            }
            if settingsTabSelection == 2 {
                DataSettingsForm()
                    .frame(idealWidth: 450, maxWidth: 520, minHeight: 260, idealHeight: height)
            }
        }
#if os(macOS)
        .padding()
#endif
        .scrollContentBackgroundIfAvailable(.hidden)
#if os(macOS)
        Spacer()
#endif
    }
}

struct ReaderSettingsPopoverConditionalModifier: ViewModifier {
    @Binding var isPresented: Bool
    
    func body(content: Content) -> some View {
        if #available(iOS 16, macOS 13, *) {
            content.modifier(ReaderSettingsPopoverModifier(isPresented: $isPresented))
        } else {
            content.modifier(LegacyReaderSettingsPopoverModifier(isPresented: $isPresented))
        }
    }
}

public extension View {
    func readerSettingsPopover(isPresented: Binding<Bool>) -> some View {
        modifier(ReaderSettingsPopoverConditionalModifier(isPresented: isPresented))
    }
}

@available(iOS 16.0, macOS 13.0, *)
struct ReaderSettingsPopoverModifier: ViewModifier {
    @Binding var isPresented: Bool
    
    @State private var detentSelection = PresentationDetent.medium
    @ScaledMetric(relativeTo: .body) private var bodyFontSize: CGFloat = Font.pointSize(for: Font.TextStyle.body)
    
    func body(content: Content) -> some View {
        content
            .popover(isPresented: $isPresented) {
                ReaderSettings(isPresented: $isPresented)
                    .padding(.top, 3)
                //                        .padding(.horizontal, 5)
                    .presentationDetents([.medium, .large], selection: $detentSelection)
#if os(iOS)
                    .largestUndimmedDetent(identifier: .medium, selection: detentSelection)
#endif
            }
    }
}

struct LegacyReaderSettingsPopoverModifier: ViewModifier {
    @Binding var isPresented: Bool
    
    @ScaledMetric(relativeTo: .body) private var bodyFontSize: CGFloat = Font.pointSize(for: Font.TextStyle.body)
    
    func body(content: Content) -> some View {
        content
            .popover(isPresented: $isPresented) {
                ReaderSettings(isPresented: $isPresented)
                    .padding(.top, 5)
            }
    }
}
