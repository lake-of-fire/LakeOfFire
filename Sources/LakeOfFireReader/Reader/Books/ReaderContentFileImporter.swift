import SwiftUI
import UniformTypeIdentifiers
import LakeOfFireContent

/// The system picker gets an immutable request identity. A retained result or
/// binding setter cannot become a command for the next picker in the same host.
@MainActor
private struct ReaderContentFileImporterModifier: ViewModifier {
    @Binding var isPresented: Bool
    let presentationID: AnyHashable?
    let permitsPresentation: @MainActor () -> Bool

    func body(content: Content) -> some View {
        content.background {
            // Only import presentation gets a new identity when its caller's
            // host changes; the original content and other modals remain mounted.
            ReaderContentFileImportHost(
                isPresented: $isPresented,
                permitsPresentation: permitsPresentation
            )
            .id(presentationID)
        }
    }
}

@MainActor
private struct ReaderContentFileImportHost: View {
    @Binding var isPresented: Bool
    let permitsPresentation: @MainActor () -> Bool
    @StateObject private var owner = ReaderFileImportPresentationOwner()

    var body: some View {
        let lifetime = owner.lifetime
        let failure = owner.failure

        Color.clear
            .frame(width: 0, height: 0)
            .background {
                if let picker = owner.picker {
                    ReaderContentFilePicker(
                        owner: owner,
                        picker: picker,
                        isPresented: $isPresented,
                        allowedContentTypes: ReaderFileManager.shared.readerContentMimeTypes
                    )
                    .id(picker.id)
                }
            }
            .onAppear {
                owner.activate()
                if isPresented, owner.picker == nil {
                    beginPicker()
                }
            }
            .onChange(of: isPresented) { requestedPresentation in
                // A retained change callback must still describe this binding.
                guard requestedPresentation == isPresented else { return }
                if requestedPresentation {
                    beginPicker()
                } else if let picker = owner.picker {
                    _ = owner.hidePicker(picker)
                }
            }
            .onDisappear {
                owner.retire(lifetime: lifetime)
            }
            .alert("Import Failed", isPresented: Binding(
                get: {
                    guard let failure else { return false }
                    return owner.isErrorPresented(failure)
                },
                set: { presented in
                    guard !presented, let failure else { return }
                    owner.dismissError(failure)
                }
            )) {
                Button("OK", role: .cancel) {
                    if let failure { owner.dismissError(failure) }
                }
            } message: {
                Text(failure?.message ?? "")
            }
    }

    private func beginPicker() {
        let fileManager = ReaderFileManager.shared
        owner.beginPicker(permitsPresentation: permitsPresentation) { selectedURL in
            try await fileManager.importFile(fileURL: selectedURL, fromDownloadURL: nil)
        }
    }
}

@MainActor
private struct ReaderContentFilePicker: View {
    @ObservedObject var owner: ReaderFileImportPresentationOwner
    let picker: ReaderFileImportPresentationOwner.Picker
    @Binding var isPresented: Bool
    let allowedContentTypes: [UTType]

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .fileImporter(
                isPresented: Binding(
                    get: { owner.isPickerPresented(picker) },
                    set: { presented in
                        guard !presented, owner.hidePicker(picker),
                              owner.isCurrent(picker) else { return }
                        isPresented = false
                    }
                ),
                allowedContentTypes: allowedContentTypes
            ) { selection in
                guard owner.accept(selection, from: picker) != nil,
                      owner.isCurrent(picker) else { return }
                isPresented = false
            }
    }
}

public extension View {
    /// The caller may scope the picker to an uninterrupted host activation.
    /// Its predicate must retain that activation's identity, rather than only
    /// checking a Boolean that can become true again after host replacement.
    @MainActor
    func readerContentFileImporter(
        isPresented: Binding<Bool>,
        presentationID: AnyHashable? = nil,
        permitsPresentation: @escaping @MainActor () -> Bool = { true }
    ) -> some View {
        modifier(ReaderContentFileImporterModifier(
            isPresented: isPresented,
            presentationID: presentationID,
            permitsPresentation: permitsPresentation
        ))
    }
}
