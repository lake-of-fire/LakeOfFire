import LakeOfFireWeb
import SwiftUI
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireReader
import LakeOfFireContent
import LakeOfFireCore
import RealmSwift
import Combine
import OPML
import UniformTypeIdentifiers
import CoreTransferable
import RealmSwiftGaps
import LakeKit

public enum LibraryRoute: Hashable, Codable {
    case userScripts
}

public enum LibrarySidebarDestination: Hashable {
    case userScripts
    case category(UUID)
}

@available(iOS 16.0, macOS 13.0, *)
struct OPMLExportShareItem: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(
            exportedContentType: UTType(exportedAs: "public.opml", conformingTo: .xml)
        ) { item in
            item.data
        }
        .suggestedFileName("ManabiReaderUserLibrary.opml")
    }
}

//
//extension Array<LibraryRoute>: RawRepresentable {
////extension LibraryRoute: RawRepresentable {
////public extension Array<LibraryRoute> {
//    public init?(rawValue: String) {
//        guard let data = rawValue.data(using: .utf8),
//              let result = try? JSONDecoder().decode([Element].self, from: data)
//        else {
//            return nil
//        }
//        self = result
//    }
//
//    public var rawValue: String {
//        guard let data = try? JSONEncoder().encode(self),
//              let result = String(data: data, encoding: .utf8)
//        else {
//            return "[]"
//        }
//        return result
//    }
//}
struct LibraryManagerViewModelEnvironmentModifier: ViewModifier {
    @available(iOS 16, macOS 13, *)
    struct ActiveLibraryManagerViewModelEnvironmentModifier: ViewModifier {
        @ObservedObject private var libraryViewModel = LibraryManagerViewModel.shared
        
        func body(content: Content) -> some View {
            content
                .environmentObject(libraryViewModel)
        }
    }
    
    func body(content: Content) -> some View {
        if #available(iOS 16, macOS 13, *) {
            content
                .modifier(ActiveLibraryManagerViewModelEnvironmentModifier())
        } else {
            content
        }
    }
}

public extension View {
    func libraryManagerViewModelEnvironment() -> some View {
        modifier(LibraryManagerViewModelEnvironmentModifier())
    }
}

struct LibraryManagerSheetModifier: ViewModifier {
    let isActive: Bool
    
    @available(iOS 16, macOS 13, *)
    struct ActiveLibrarySheetModifier: ViewModifier {
        let isActive: Bool
        
        @ObservedObject private var libraryViewModel = LibraryManagerViewModel.shared
        
        func body(content: Content) -> some View {
            content
                .sheet(isPresented: $libraryViewModel.isLibraryPresented.gatedBy(isActive)) {
                    if #available(iOS 16.4, macOS 13.1, *) {
                        LibraryManagerView()
#if os(iOS)
                            .presentationDragIndicator(.visible)
#endif
#if os(macOS)
                            .frame(minWidth: 650, minHeight: 500)
#endif
                    }
                }
        }
    }
    
    func body(content: Content) -> some View {
        if #available(iOS 16, macOS 13, *) {
            content
                .modifier(ActiveLibrarySheetModifier(isActive: isActive))
        } else {
            content
        }
    }
}

public extension View {
    func libraryManagerSheet(isActive: Bool) -> some View {
        modifier(LibraryManagerSheetModifier(isActive: isActive))
    }
}

@available(iOS 16.0, macOS 13.0, *)
@MainActor
public class LibraryManagerViewModel: NSObject, ObservableObject {
    public static let shared = LibraryManagerViewModel()
    
    @Published public var isLibraryPresented = false
    
    @Published private var preparedOPMLExport: (opml: OPML, fileURL: URL, data: Data)?
    var exportedOPML: OPML? { preparedOPMLExport?.opml }
    var exportedOPMLFileURL: URL? { preparedOPMLExport?.fileURL }
    var exportedOPMLShareItem: OPMLExportShareItem? {
        preparedOPMLExport.map { OPMLExportShareItem(data: $0.data) }
    }
    @Published var opmlExportFailed = false
    
//    @AppStorage("LibraryManagerViewModel.presentedCategories") var presentedCategories = [LibraryRoute]()
    @Published var selectedFeed: Feed?
    
    private var exportOPMLTask: Task<Void, Never>?
    private var reprepareOPMLTask: Task<Void, Never>?
    private var exportOPMLGeneration = 0
    private var opmlExportUIRegistrations = Set<UUID>()
    // Each successful generation has a readiness-checked file and immutable
    // share bytes. Retired files remain available while export UI is mounted.
    private var retiredOPMLExportFileURLs = Set<URL>()
    // A write can create bytes before throwing. Those bytes were never
    // published to ShareLink, so they need no UI lifetime; retain only cleanup
    // ownership until removal succeeds or reports that the path is already gone.
    private var failedOPMLExportFileURLs = Set<URL>()
