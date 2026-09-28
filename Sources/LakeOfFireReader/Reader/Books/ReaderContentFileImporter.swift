import SwiftUI
import LakeOfFireContent

/// Keep the picker and its error handling identical for Books and app callers.
/// Presentation belongs to this host, not a persisted app-global error string.
@MainActor
private struct ReaderContentFileImporterModifier: ViewModifier {
    @Binding var isPresented: Bool
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $isPresented,
                allowedContentTypes: ReaderFileManager.shared.readerContentMimeTypes
            ) { selection in
                Task { @MainActor in
                    let result = await ReaderFileImportOperation.perform(selection) { selectedURL in
                        try await ReaderFileManager.shared.importFile(fileURL: selectedURL, fromDownloadURL: nil)
                    }
                    if case .failed(let message) = result { errorMessage = message }
                }
            }
            .alert("Import Failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }
}

public extension View {
    @MainActor
    func readerContentFileImporter(isPresented: Binding<Bool>) -> some View {
        modifier(ReaderContentFileImporterModifier(isPresented: isPresented))
    }
}
