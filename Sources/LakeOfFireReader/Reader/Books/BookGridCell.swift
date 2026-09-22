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

    init(imageURL: URL?, title: String, author: String?, publicationDate: Date?, downloadURL: URL?, onSelected: ((Bool) -> Void)? = nil) {
        self.imageURL = imageURL
        self.title = title
        self.author = author
        self.publicationDate = publicationDate
        self.downloadURL = downloadURL
        self.onSelected = onSelected
    }

    var body: some View {
        BookGridCellContent(
            imageURL: imageURL,
            title: title,
            author: author,
            publicationDate: publicationDate,
            onSelected: onSelected
        )
    }
}
