import SwiftUI
import BigSyncKit
import RealmSwiftGaps
import RealmSwift

@MainActor
fileprivate class FeedCategoryButtonsViewModel: ObservableObject {
    @Published var libraryConfiguration: LibraryConfiguration? {
        didSet {
            Task.detached { @RealmBackgroundActor [weak self] in
                guard let self = self else { return }
                let libraryConfiguration = try await LibraryConfiguration.shared
                objectNotificationToken?.invalidate()
                objectNotificationToken = libraryConfiguration
                    .observe { [weak self] change in
                        guard let self = self else { return }
                        switch change {
                        case .change(_, _), .deleted:
                            Task { @MainActor [weak self] in
                                self?.objectWillChange.send()
                            }
                        case .error(let error):
                            print("An error occurred: \(error)")
                        }
                    }
            }
        }
    }
    
    @RealmBackgroundActor private var objectNotificationToken: NotificationToken?

    init() {
        Task.detached { @RealmBackgroundActor [weak self] in
            let libraryConfigurationRef = try await ThreadSafeReference(to: LibraryConfiguration.shared)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let realm = try await Realm(configuration: LibraryDataManager.realmConfiguration)
                guard let libraryConfiguration = realm.resolve(libraryConfigurationRef) else { return }
                self.libraryConfiguration = libraryConfiguration
            }
        }
    }
    
    deinit {
        Task.detached { @RealmBackgroundActor [weak self] in
            self?.objectNotificationToken?.invalidate()
        }
    }
}

public struct FeedCategoryButtons: View {
    @Binding var categorySelection: String?
    var font = Font.title3
    var isCompact = false
    
    @StateObject private var viewModel = FeedCategoryButtonsViewModel()
    
    @ObservedResults(FeedCategory.self, configuration: ReaderContentLoader.feedEntryRealmConfiguration, where: { $0.isDeleted == false && $0.isArchived == false }) private var categories
    
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif
    
    private var gridColumns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    private var isConsideredCompact: Bool {
#if os(iOS)
        return isCompact || horizontalSizeClass == .compact
#else
        return isCompact
#endif
    }
    
    public var body: some View {
        if isCompact {
            VStack(spacing: 5) {
                if let categories = viewModel.libraryConfiguration?.categories {
                    ForEach(categories) { category in
                        FeedCategoryButton(category: category, categorySelection: $categorySelection, font: font, isCompact: isCompact)
                    }
                }
            }
        } else {
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 8) {
                if let categories = viewModel.libraryConfiguration?.categories {
                    ForEach(categories) { category in
                        FeedCategoryButton(category: category, categorySelection: $categorySelection, font: font, isCompact: isCompact)
                    }
                }
            }
        }
    }
    
    public init(categorySelection: Binding<String?>, font: Font = Font.title3, isCompact: Bool = false) {
        _categorySelection = categorySelection
        self.font = font
        self.isCompact = isCompact
    }
}

public struct FeedCategoryButton: View {
    let category: FeedCategory
    @Binding var categorySelection: String?
    var font = Font.title3
    var isCompact = false
//    @SceneStorage("SidebarView.categorySelection") var categorySelection: String?
    
    public var body: some View {
        Button(action: {
            categorySelection = category.id.uuidString
        }) {
            FeedCategoryButtonLabel(category: category, font: font, isCompact: isCompact)
        }
        .buttonStyle(ReaderCategoryButtonStyle())
    }
    
    public init(category: FeedCategory, categorySelection: Binding<String?>, font: Font = Font.title3, isCompact: Bool) {
        self.category = category
        _categorySelection = categorySelection
        self.font = font
        self.isCompact = isCompact
    }
}

struct ReaderCategoryButtonStyle: ButtonStyle {
    func makeBody(configuration: Self.Configuration) -> some View {
        configuration.label
//            .clipped()
//#if os(iOS)
//            .clipShape(Capsule())
//#else
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
//#endif
            .buttonStyle(.borderless)
        //            .buttonStyle(.plain)
//            .brightness(-0.1)
            .scaleEffect(configuration.isPressed ? 0.994 : 1.0)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.easeOut(duration: 0.05), value: configuration.isPressed)
//            .overlay(
//                RoundedRectangle(cornerRadius: 6, style: .continuous)
//                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
//            )
    }
}

public struct FeedCategoryButtonLabel: View {
    let category: LakeOfFire.FeedCategory
    var font = Font.title3
    var isCompact = false
    
#if os(iOS)
    @ScaledMetric(relativeTo: .largeTitle) private var scaledCategoryHeight: CGFloat = 40
#else
    @ScaledMetric(relativeTo: .largeTitle) private var scaledCategoryHeight: CGFloat = 20
#endif
    
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif
    
    public var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Group {
                if category.title.isEmpty {
                    Text("Untitled Category")
                        .fontWeight(.bold)
                        .font(font)
                        .foregroundColor(.secondary)
                } else {
                    Text(category.title)
                        .fontWeight(.bold)
                        .font(font)
                        .foregroundColor(.white)
                }
            }
            .shadow(color: .black.opacity(0.25), radius: 30, x: 0, y: 0)
            .shadow(color: .black.opacity(0.896), radius: 3, x: 0, y: 0)
            Spacer()
        }
        .frame(minHeight: isCompact ? nil : scaledCategoryHeight, alignment: .leading)
        //            .frame(maxWidth: isInSidebar || horizontalSizeClass == .compact ? .infinity : 190)
        .frame(maxWidth: .infinity)
#if os(iOS)
        .frame(idealHeight: isCompact || horizontalSizeClass == .compact ? scaledCategoryHeight : scaledCategoryHeight * 2.3)
#else
        .frame(idealHeight: isCompact ? nil : scaledCategoryHeight * 2.3)
#endif
        //            .padding(.horizontal, scaledCategoryHeight * 0.36)
        .overlay(Color.white.opacity(0.0000001)) // Weird macOS hack...
        .background {
            FeedCategoryImage(category: category)
            //                            .frame(maxHeight: isInSidebar ? scaledCategoryHeight : 110)
                .allowsHitTesting(false)
        }
        .multilineTextAlignment(.leading)
    }
    
    public init(category: LakeOfFire.FeedCategory, font: Font = Font.title3, isCompact: Bool, scaledCategoryHeight: CGFloat? = nil) {
        self.category = category
        self.font = font
        self.isCompact = isCompact
    }
}
