import SwiftUI
import RealmSwift
import SwiftUIWebView
import RealmSwiftGaps
import RealmSwift
import SwiftUtilities
import Combine
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent

@available(iOS 16.0, macOS 13.0, *)
struct WebFeedMenuAddButtons: View {
    let userCategories: [LibraryWebFeedCategorySnapshot]?
    let url: URL
    let title: String
    
    @EnvironmentObject private var libraryViewModel: LibraryManagerViewModel
    
    @Environment(\.openWindow) var openWindow
    
    var body: some View {
        ForEach(LibraryWebFeedAddChoice.choices(for: userCategories)) { choice in
            Button {
                add(to: choice.destination)
            } label: {
                Label(choice.title, systemImage: "plus")
            }
        }
    }

    @MainActor
    private func add(to destination: LibraryFeedCreationDestination) {
        // Admit the destination in the button action, before starting a task.
        guard let task = libraryViewModel.add(rssURL: url, title: title, destination: destination, didPublish: { _ in
#if os(macOS)
            openWindow(id: "user-library")
#else
            libraryViewModel.isLibraryPresented = true
#endif
        }) else { return }
        Task { @MainActor in
            do {
                _ = try await task.value
            } catch is CancellationError {
                // A retired command does not present the Library.
            } catch {
                print("Failed to add web feed: \(error)")
            }
        }
    }
    
    init(userCategories: [LibraryWebFeedCategorySnapshot]?, url: URL, title: String) {
        self.userCategories = userCategories
        self.url = url
        self.title = title
    }
}

@available(iOS 16.0, macOS 13.0, *)
public struct WebFeedButton<C: ReaderContentProtocol>: View {
    @ObservedObject var readerContent: C
    
    @EnvironmentObject private var libraryViewModel: LibraryManagerViewModel
    public var body: some View {
        ObservedWebFeedButton(
            readerContent: readerContent,
            libraryViewModel: libraryViewModel,
            libraryState: libraryViewModel.webFeedButtonLibraryState
        )
        .id(ObjectIdentifier(libraryViewModel))
    }

    public init(readerContent: C) {
        self.readerContent = readerContent
    }
}

@available(iOS 16.0, macOS 13.0, *)
@MainActor
private struct ObservedWebFeedButton<C: ReaderContentProtocol>: View {
    @ObservedObject var readerContent: C
    @ObservedObject var libraryViewModel: LibraryManagerViewModel
    @ObservedObject var libraryState: WebFeedButtonLibraryState
    @State private var presentationID = UUID()

    var body: some View {
        let rssURLs = Array(readerContent.rssURLs)
        let rssTitles = Array(readerContent.rssTitles)

        Menu {
            Group {
                if libraryState.hasFailed {
                    Button("Reload Library") {
                        libraryState.retry()
                    }
                }
                if let selection = libraryState.feed(matching: rssURLs) {
                    Button("Edit Feed in Library…") {
                        libraryViewModel.selectExistingWebFeed(
                            resolving: { libraryState.resolve(selection) },
                            didPublish: { libraryViewModel.isLibraryPresented = true }
                        )
                    }
                } else if !rssURLs.isEmpty {
                    ForEach(Array(rssURLs.indices), id: \.self) { idx in
                        let url = rssURLs[idx]
                        let title = idx < rssTitles.count ? rssTitles[idx] : url.absoluteString
                        if rssURLs.count == 1 {
                            WebFeedMenuAddButtons(
                                userCategories: libraryState.userCategories,
                                url: url,
                                title: title
                            )
                        } else {
                            Menu("Add Feed \"\(title)\"") {
                                WebFeedMenuAddButtons(
                                    userCategories: libraryState.userCategories,
                                    url: url,
                                    title: title
                                )
                            }
                        }
                    }
                    Divider()
                    Button("Manage Library Categories…") {
                        libraryViewModel.manageLibraryCategories()
                    }
                }
            }
            .labelStyle(.titleAndIcon)
        } label: {
            Label("RSS Feed", systemImage:  "dot.radiowaves.up.forward")
        }
        .disabled(rssURLs.isEmpty)
        .fixedSize()
        .onAppear {
            libraryState.beginObservation(for: presentationID)
        }
        .onDisappear {
            libraryState.endObservation(for: presentationID)
        }
    }
}

@available(iOS 16, macOS 13.0, *)
public extension ReaderContentProtocol {
    @MainActor
    var webFeedButtonView: some View {
        WebFeedButton(readerContent: self)
    }
}
