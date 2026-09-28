import SwiftUI
import SwiftUtilities
import SwiftUIDownloads
import LakeImage
import Pow
import LakeOfFireContent

fileprivate struct BookGridCellContent: View {
    let imageURL: URL?
    let title: String
    let author: String?
    let publicationDate: Date?
    var onSelected: ((Bool) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            if let imageURL = imageURL {
                Button {
                    buttonPress()
                } label: {
                    BookThumbnail(imageURL: imageURL)
                }
                .buttonStyle(BookButtonStyle())
                .padding(.bottom, 8)
            }

            Button {
                buttonPress()
            } label: {
                VStack(alignment: .leading) {
                    Text(title)
                        .font(.headline)
                    Text("\(author ?? "")\(author != nil && publicationDate != nil ? " • " : "")\(publicationDate != nil ? String(Calendar.current.component(.year, from: publicationDate!)) : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private func buttonPress() {
        Task { @MainActor in
            onSelected?(true)
        }
    }
}

@MainActor
fileprivate struct DownloadableBookGridCell: View {
    let imageURL: URL?
    let title: String
    let author: String?
    let publicationDate: Date?
    var onSelected: ((Bool) -> Void)? = nil
    @ObservedObject var downloadable: Downloadable

    @State private var importState = BookDownloadImportState()
    @State private var importOperation = BookDownloadOperation()
    @State private var presentedError: String?
    @State private var isErrorPresented = false

    @ObservedObject private var downloadController = DownloadController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            BookGridCellContent(imageURL: imageURL, title: title, author: author, publicationDate: publicationDate) { _ in
                buttonPress()
            }
            HidingDownloadButton(
                downloadable: downloadable,
                downloadText: "Get",
                downloadedText: importState.isImported ? "In Library" : "Downloaded") { _ in
                    await MainActor.run { buttonPress() }
                }
                .font(.caption)
                .textCase(.uppercase)
                .foregroundStyle(.primary)
                .modifier {
                    if #available(macOS 13, iOS 16, *) {
                        $0
                            .fontWeight(.bold)
                    } else { $0 }
                }
                .padding(.bottom, 2)
            if importState.errorMessage != nil {
                Button("Retry Import") { buttonPress() }
                    .accessibilityIdentifier("BookLibrary.RetryImport.\(title)")
            }
        }
        .task(id: downloadable.isFinishedDownloading) { @MainActor in
            await refreshDownloadable()
        }
        .onDisappear { importOperation.cancel() }
        .alert("Book Error", isPresented: $isErrorPresented) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(presentedError ?? "")
        }
    }

    private func buttonPress() {
        importOperation.start(operation: {
            let wasAlreadyDownloaded = await downloadable.existsLocally()
            guard !Task.isCancelled else { return nil }
            if !wasAlreadyDownloaded {
                await downloadController.ensureDownloaded([downloadable])
            }
            guard !Task.isCancelled else { return nil }
            let result = await ReaderFileImportOperation.perform(.success(downloadable.localDestination)) { _ in
                try await ReaderFileManager.shared.ensureImported(downloadable: downloadable)
            }
            return (result, wasAlreadyDownloaded)
        }, publish: { result in
            if receiveImportResult(result.0) {
                onSelected?(result.1)
            }
        })
    }

    private func refreshDownloadable() async {
        await importOperation.refresh(operation: {
            guard !importState.isImported,
                  await downloadable.existsLocally(), !Task.isCancelled else { return nil }
            return await ReaderFileImportOperation.perform(.success(downloadable.localDestination)) { _ in
                try await ReaderFileManager.shared.ensureImported(downloadable: downloadable)
            }
        }, publish: { result in
            _ = receiveImportResult(result)
        })
    }

    private func receiveImportResult(_ result: ReaderFileImportResult) -> Bool {
        guard result != .cancelled else { return false }
        let didImport = importState.receive(result)
        presentedError = importState.errorMessage
        isErrorPresented = presentedError != nil
        return didImport
    }
}

fileprivate struct BookButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
        //            .padding(.vertical, 12)
        //            .padding(.horizontal, 64)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .conditionalEffect(
                .pushDown,
                condition: configuration.isPressed)
    }
}

struct BookGridCell: View {
    let imageURL: URL?
    let title: String
    let author: String?
    let publicationDate: Date?
    let downloadURL: URL?
    var onSelected: ((Bool) -> Void)? = nil

    @State private var downloadable: Downloadable?
    //    @StateObject private var viewModel = ReaderContentCellViewModel<C>()

    init(imageURL: URL?, title: String, author: String?, publicationDate: Date?, downloadURL: URL?, onSelected: ((Bool) -> Void)? = nil) {
        self.imageURL = imageURL
        self.title = title
        self.author = author
        self.publicationDate = publicationDate
        self.downloadURL = downloadURL
        self.onSelected = onSelected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let downloadable = downloadable {
                DownloadableBookGridCell(imageURL: imageURL, title: title, author: author, publicationDate: publicationDate, onSelected: onSelected, downloadable: downloadable)
            } else {
                BookGridCellContent(imageURL: imageURL, title: title, author: author, publicationDate: publicationDate, onSelected: onSelected)
            }
        }
        .task { @MainActor in
            await refreshDownloadable()
        }
    }

    private func refreshDownloadable() async {
        if let downloadURL = downloadURL {
            if downloadable?.url != downloadURL || downloadable?.name != title {
                downloadable = try? await ReaderFileManager.shared.downloadable(url: downloadURL, name: title)
            }
        }
    }
}
