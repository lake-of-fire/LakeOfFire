import SwiftUI
import LakeOfFireContent

@MainActor
func readerContentSelectedForDeletion<C: ReaderContentProtocol>(
    contents: [C],
    selectedKeys: Set<String>
) -> [C] {
    guard !selectedKeys.isEmpty else { return [] }
    return contents.filter {
        !$0.isInvalidated && !$0.isDeleted && selectedKeys.contains($0.compoundKey)
    }
}

/// File-status results belong to the selected physical row and URL, rather than
/// to a primary key that a replacement row or edited URL can reuse.
@MainActor
final class ReaderContentDeleteEligibilityModel: ObservableObject {
    typealias EligibilityReader = @MainActor @Sendable (URL) async -> ReaderFileDeleteEligibility

    @MainActor
    private struct Selection {
        let file: ContentFile
        let key: String
        let url: URL
        let createdAt: Date
        let backingURL: URL

        init?(file: ContentFile) {
            guard !file.isInvalidated, !file.isDeleted else { return nil }
            let url = file.url
            guard let backingURL = ReaderFileManager.shared.canonicalReaderBackingURL(for: url) else {
                return nil
            }
            self.file = file
            self.key = file.compoundKey
            self.url = url
            self.createdAt = file.createdAt
            self.backingURL = backingURL
        }

        func matches(_ current: ContentFile) -> Bool {
            guard !file.isInvalidated, !current.isInvalidated,
                  !file.isDeleted, !current.isDeleted else { return false }
            return (file === current || file.isSameObject(as: current))
                && current.compoundKey == key
                && current.url == url
                && current.createdAt == createdAt
        }
    }

    private struct Result {
        let selection: Selection
        let eligibility: ReaderFileDeleteEligibility
    }

    @Published private var results: [String: Result] = [:]
    private let readEligibility: EligibilityReader
    private var refreshTask: Task<Void, Never>?
    private var activeRefreshID: UUID?

    init(readEligibility: @escaping EligibilityReader = {
        await ReaderFileManager.shared.deleteEligibility(forReaderBackingURL: $0)
    }) {
        self.readEligibility = readEligibility
    }

    deinit {
        refreshTask?.cancel()
    }

    func isDeletionDisabled<C: ReaderContentProtocol>(
        contents: [C],
        selectedKeys: Set<String>
    ) -> Bool {
        let selected = readerContentSelectedForDeletion(contents: contents, selectedKeys: selectedKeys)
        guard !selected.isEmpty else { return true }
        return selected.compactMap { $0 as? ContentFile }.contains { file in
            guard let result = results[file.compoundKey], result.selection.matches(file) else {
                return true
            }
            return result.eligibility != .allowed
        }
    }

    @discardableResult
    func refresh<C: ReaderContentProtocol>(
        contents: [C],
        selectedKeys: Set<String>
    ) -> Task<Void, Never>? {
        // A cancelled list load must not revoke a newer active selection.
        guard !Task.isCancelled else { return nil }
        let selections = readerContentSelectedForDeletion(contents: contents, selectedKeys: selectedKeys)
            .compactMap { $0 as? ContentFile }
            .compactMap { Selection(file: $0) }
        cancelRefresh()
        guard !selections.isEmpty else {
            results = [:]
            return nil
        }

        let refreshID = UUID()
        let readEligibility = readEligibility
        activeRefreshID = refreshID
        let task = Task { @MainActor [weak self] in
            defer { self?.finishRefresh(refreshID) }
            var nextResults: [String: Result] = [:]
            for selection in selections {
                guard !Task.isCancelled, self?.activeRefreshID == refreshID else { return }
                guard selection.matches(selection.file) else { continue }
                let eligibility = await readEligibility(selection.backingURL)
                guard !Task.isCancelled, self?.activeRefreshID == refreshID else { return }
                guard selection.matches(selection.file) else { continue }
                nextResults[selection.key] = Result(selection: selection, eligibility: eligibility)
            }
            guard !Task.isCancelled, self?.activeRefreshID == refreshID else { return }
            // An earlier file can retire while a later file's status is pending.
            self?.results = nextResults.filter { $0.value.selection.matches($0.value.selection.file) }
        }
        refreshTask = task
        return task
    }

    func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        activeRefreshID = nil
    }

    private func finishRefresh(_ refreshID: UUID) {
        guard activeRefreshID == refreshID else { return }
        refreshTask = nil
        activeRefreshID = nil
    }
}
