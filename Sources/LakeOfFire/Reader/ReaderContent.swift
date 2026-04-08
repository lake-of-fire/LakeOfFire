import SwiftUI
import Combine

private func logReaderLoad(_ message: String) {
    debugPrint("# READERLOAD \(message)")
}

@MainActor
public class ReaderContent: ObservableObject {
    @Published public var content: (any ReaderContentProtocol)? {
        didSet {
            syncLocationBarTitle()
            syncContentTitle()
        }
    }// = ReaderContentLoader.unsavedHome
    @Published public var pageURL = URL(string: "about:blank")! { didSet { syncLocationBarTitle() } }
    @Published public var locationBarTitle: String?
    @Published public var isReaderProvisionallyNavigating = false
    @Published public var isRenderingReaderHTML = false
    public let contentTitleSubject = PassthroughSubject<String, Never>()
    public private(set) var contentTitle: String = ""
    
    private var loadingTask: Task<(any ReaderContentProtocol)?, Error>?

    public init() {
    }

    private func syncLocationBarTitle() {
        guard pageURL.absoluteString != "about:blank" else {
            locationBarTitle = nil
            return
        }
        guard let content,
              content.url.matchesReaderURL(pageURL) else {
            locationBarTitle = nil
            return
        }
        let trimmedTitle = content.locationBarTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        locationBarTitle = (trimmedTitle?.isEmpty == false) ? trimmedTitle : nil
    }

    private func syncContentTitle() {
        let newTitle = content?.title ?? ""
        guard contentTitle != newTitle else { return }
        contentTitle = newTitle
        guard !newTitle.isEmpty else { return }
        contentTitleSubject.send(newTitle)
    }
    
    @MainActor
    internal func load(url: URL) async throws {
        let resolvedContentURL = ReaderContentLoader.getContentURL(fromLoaderURL: url) ?? url
        let displayURL = resolvedContentURL
        logReaderLoad(
            "stage=readerContent.load.begin requestURL=\(url.absoluteString) resolvedContentURL=\(resolvedContentURL.absoluteString) currentPageURL=\(pageURL.absoluteString) currentContentURL=\(content?.url.absoluteString ?? "nil") hasLoadingTask=\(loadingTask != nil)"
        )

        if let loadingTask, pageURL.matchesReaderURL(url) {
            logReaderLoad(
                "stage=readerContent.load.reuseLoadingTask requestURL=\(url.absoluteString) pageURL=\(pageURL.absoluteString)"
            )
            _ = try await loadingTask.value
            return
        }

        if let existingContent = content, existingContent.url.matchesReaderURL(resolvedContentURL) {
            if !pageURL.matchesReaderURL(url) {
                logReaderLoad(
                    "stage=readerContent.load.reuseExistingContent requestURL=\(url.absoluteString) existingContentURL=\(existingContent.url.absoluteString) displayURL=\(displayURL.absoluteString)"
                )
                pageURL = displayURL
            }
            return
        }

        logReaderLoad(
            "stage=readerContent.load.clearState requestURL=\(url.absoluteString) newPageURL=\(displayURL.absoluteString)"
        )
        content = nil
        pageURL = displayURL
        
        loadingTask?.cancel()
        loadingTask = Task { @MainActor [weak self] in
            try Task.checkCancellation()
            let content = try await ReaderViewModel.getContent(forURL: url, countsAsHistoryVisit: true) ?? ReaderContentLoader.unsavedHome
            guard content.url.matchesReaderURL(resolvedContentURL) else {
                logReaderLoad(
                    "stage=readerContent.load.mismatchedContent requestURL=\(url.absoluteString) resolvedContentURL=\(resolvedContentURL.absoluteString) returnedContentURL=\(content.url.absoluteString)"
                )
                debugPrint("Warning: Mismatched URL in ReaderContent.load:", url.absoluteString, content.url)
                return nil
            }
            self?.content = content
            logReaderLoad(
                "stage=readerContent.load.contentResolved requestURL=\(url.absoluteString) contentURL=\(content.url.absoluteString) contentType=\(String(describing: type(of: content))) key=\(content.compoundKey)"
            )
            return content
        }
        let loadedContent = try await loadingTask?.value
        loadingTask = nil
        let finalContentURL = loadedContent.flatMap { $0 }?.url.absoluteString ?? content?.url.absoluteString ?? "nil"
        logReaderLoad(
            "stage=readerContent.load.finish requestURL=\(url.absoluteString) pageURL=\(pageURL.absoluteString) contentURL=\(finalContentURL)"
        )
    }
    
    @MainActor
    public func getContent() async throws -> (any ReaderContentProtocol)? {
        if let content {
            logReaderLoad(
                "stage=readerContent.getContent.cached pageURL=\(pageURL.absoluteString) contentURL=\(content.url.absoluteString) key=\(content.compoundKey)"
            )
            return content
        }
        logReaderLoad(
            "stage=readerContent.getContent.awaitLoadingTask pageURL=\(pageURL.absoluteString) hasLoadingTask=\(loadingTask != nil)"
        )
        return try await loadingTask?.value
    }

    @MainActor
    public func updateContentTitle(_ newTitle: String) async {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let content else { return }
        guard trimmed != content.title else { return }

        contentTitle = trimmed
        contentTitleSubject.send(trimmed)

        do {
            let contentURL = content.url
            try await ReaderContentLoader.updateContent(url: contentURL) { object in
                guard object.title != trimmed else { return false }
                object.title = trimmed
                return true
            }
        } catch {
            debugPrint("# READER contentTitle.update.failed", error.localizedDescription)
        }
    }
}
