import SwiftUI
import RealmSwiftGaps

struct UserScriptAllowedDomainCell: View {
    let editor: UserScriptAllowedDomainEditor

    init(editor: UserScriptAllowedDomainEditor) {
        self.editor = editor
        _domainText = State(initialValue: editor.initialText)
    }

    @State private var domainText: String
    @State private var pendingEdit: UserScriptAllowedDomainEdit?
    @State private var writeTask: Task<Void, Never>?

    var body: some View {
        TextField("Domain", text: Binding(get: { domainText }, set: edit), prompt: Text("example.com"))
#if os(iOS)
            .textInputAutocapitalization(.never)
#endif
            .onDisappear(perform: finishEditing)
    }

    @MainActor
    private func edit(_ text: String) {
        domainText = text
        // Reserve input ownership before debounce or an actor hop, including no-op input.
        let command = editor.makeEdit(text)
        pendingEdit = command
        writeTask?.cancel()
        writeTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
                try await command.write()
                if pendingEdit?.intent == command.intent { pendingEdit = nil }
            } catch is CancellationError {
                // Replacement/disappearance retains the latest command for its owned flush.
            } catch {
                print("# LIBRARYSCRIPTDOMAIN edit failed: \(error)")
            }
        }
    }

    @MainActor
    private func finishEditing() {
        writeTask?.cancel()
        writeTask = nil
        guard let command = pendingEdit else { return }
        pendingEdit = nil
        Task { @RealmBackgroundActor in
            do { try await command.write() }
            catch { print("# LIBRARYSCRIPTDOMAIN retirement write failed: \(error)") }
        }
    }
}
