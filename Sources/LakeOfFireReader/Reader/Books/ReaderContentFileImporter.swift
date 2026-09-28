import SwiftUI
import LakeOfFireContent

/// Keep the picker and its error handling identical for Books and app callers.
/// The existing app-level error presenter owns the errorMessage storage key.
@MainActor
private struct ReaderContentFileImporterModifier: ViewModifier {
    @Binding var isPresented: Bool
    @AppStorage("errorMessage") private var errorMessage = ""

    func body(content: Content) -> some View {
        content.fileImporter(
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
    }
}

public extension View {
    @MainActor
    func readerContentFileImporter(isPresented: Binding<Bool>) -> some View {
        modifier(ReaderContentFileImporterModifier(isPresented: isPresented))
    }
}
