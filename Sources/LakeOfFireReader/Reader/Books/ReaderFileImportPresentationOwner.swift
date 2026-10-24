import Combine
import Foundation
import LakeOfFireContent

/// Owns presentation only. Retiring a picker cancels its waiter; it never
/// removes a file that the selected importer may already have committed.
@MainActor
final class ReaderFileImportPresentationOwner: ObservableObject {
    struct Lifetime: Equatable, Sendable {
        fileprivate let id = UUID()
    }

    struct Picker: Identifiable, Equatable, Sendable {
        let id = UUID()
        fileprivate let lifetime: Lifetime
    }

    struct Failure: Identifiable, Equatable, Sendable {
        let id = UUID()
        let picker: Picker
        let message: String
    }

    typealias Importer = @MainActor (URL) async throws -> URL?

    private struct PendingPicker {
        let picker: Picker
        let importing: Importer
        let permitsPresentation: @MainActor () -> Bool
        var hasAcceptedSelection = false
    }

    private struct Attempt: Equatable {
        let id = UUID()
        let picker: Picker
    }

    let objectWillChange = ObservableObjectPublisher()

    private(set) var lifetime: Lifetime? = Lifetime()
    private(set) var failure: Failure?
    private var pendingPicker: PendingPicker?
    private var pickerIsVisible = false
    private var attempt: Attempt?
    private var task: Task<Void, Never>?

    var picker: Picker? { pendingPicker?.picker }
    var isImporting: Bool { attempt != nil }

    deinit { task?.cancel() }

    /// A new mounted lifetime cannot admit a retained callback from the old one.
    func activate() {
        guard lifetime == nil else { return }
        lifetime = Lifetime()
        publishChange()
    }

    func retire(lifetime capturedLifetime: Lifetime?) {
        guard let capturedLifetime, lifetime == capturedLifetime else { return }
        let previousTask = task
        lifetime = nil
        pendingPicker = nil
        pickerIsVisible = false
        failure = nil
        attempt = nil
        task = nil
        previousTask?.cancel()
        publishChange()
    }

    /// Called when the public presentation binding requests a new picker,
    /// before that picker is rendered. Capture the importer with this request.
    @discardableResult
    func beginPicker(
        permitsPresentation: @escaping @MainActor () -> Bool = { true },
        importing: @escaping Importer
    ) -> Picker? {
        guard !Task.isCancelled, let lifetime else { return nil }
        let previousPicker = pendingPicker?.picker
        guard permitsPresentation(), !Task.isCancelled,
              self.lifetime == lifetime, pendingPicker?.picker == previousPicker else { return nil }
        let previousTask = task
        let picker = Picker(lifetime: lifetime)
        pendingPicker = PendingPicker(
            picker: picker,
            importing: importing,
            permitsPresentation: permitsPresentation
        )
        pickerIsVisible = true
        failure = nil
        attempt = nil
        task = nil
        previousTask?.cancel()
        publishChange()
        return picker
    }

    func isCurrent(_ picker: Picker) -> Bool {
        guard matches(picker), let permitsPresentation = pendingPicker?.permitsPresentation,
              permitsPresentation() else { return false }
        // A caller-supplied admission check may synchronously replace the host.
        return matches(picker)
    }

    private func matches(_ picker: Picker) -> Bool {
        lifetime == picker.lifetime && pendingPicker?.picker == picker
    }

    func isPickerPresented(_ picker: Picker) -> Bool {
        isCurrent(picker) && pickerIsVisible
    }

    /// SwiftUI can dismiss its Bool binding before delivering the result.
    /// Hiding must retain admission for that result; a new picker or retired
    /// host, rather than Bool false alone, revokes it.
    @discardableResult
    func hidePicker(_ picker: Picker) -> Bool {
        guard isCurrent(picker) else { return false }
        if pickerIsVisible {
            pickerIsVisible = false
            publishChange()
        }
        return isCurrent(picker)
    }

    /// One picker can deliver at most one accepted selection. An old result is
    /// rejected before it can replace or cancel the current import.
    @discardableResult
    func accept(
        _ selection: Result<URL, Error>,
        from picker: Picker
    ) -> Task<Void, Never>? {
        guard !Task.isCancelled, isCurrent(picker),
              var pendingPicker, !pendingPicker.hasAcceptedSelection else { return nil }
        pendingPicker.hasAcceptedSelection = true
        self.pendingPicker = pendingPicker
        pickerIsVisible = false

        let importing = pendingPicker.importing
        let attempt = Attempt(picker: picker)
        self.attempt = attempt
        let startedTask = Task { @MainActor [weak self] in
            defer { self?.finish(attempt) }
            guard !Task.isCancelled, self?.owns(attempt) == true,
                  self?.isCurrent(attempt.picker) == true else { return }
            let result = await ReaderFileImportOperation.perform(selection, importing: importing)
            guard !Task.isCancelled else { return }
            self?.receive(result, for: attempt)
        }
        task = startedTask
        publishChange()
        return startedTask
    }

    func isErrorPresented(_ error: Failure) -> Bool {
        isCurrent(error.picker) && failure?.id == error.id
    }

    /// Both the alert Bool setter and its button use this exact identity.
    func dismissError(_ error: Failure) {
        guard isErrorPresented(error) else { return }
        failure = nil
        publishChange()
    }

    private func owns(_ attempt: Attempt) -> Bool {
        self.attempt == attempt && matches(attempt.picker)
    }

    private func receive(_ result: ReaderFileImportResult, for attempt: Attempt) {
        guard owns(attempt), isCurrent(attempt.picker), owns(attempt) else { return }
        switch result {
        case .imported:
            failure = nil
        case .failed(let message):
            failure = Failure(picker: attempt.picker, message: message)
        case .cancelled:
            return
        }
        publishChange()
    }

    private func finish(_ attempt: Attempt) {
        guard owns(attempt) else { return }
        self.attempt = nil
        task = nil
        publishChange()
    }

    private func publishChange() {
        // Commit ownership before notifying synchronous Combine observers.
        // Reentrant observers may install a successor, so no caller writes
        // older presentation state after this notification.
        objectWillChange.send()
    }
}
