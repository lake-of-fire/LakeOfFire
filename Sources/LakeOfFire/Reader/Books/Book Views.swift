import SwiftUI
import SwiftUtilities
import SwiftUIDownloads
import LakeImage
import Pow
import SwiftUtilities

struct BookThumbnail: View { //, Equatable {
    let imageURL: URL
    var limitWidth: Bool = true
    
    @ScaledMetric(relativeTo: .headline) var scaledImageWidth: CGFloat = 100
    @ScaledMetric(relativeTo: .headline) var cellHeight: CGFloat = 140
    
    //    @StateObject private var viewModel = ReaderContentCellViewModel<C>()
    
    var body: some View {
        ZStack {
            Color.clear
                .frame(
                    width: scaledImageWidth,
                    height: cellHeight
                )
            ReaderImage(
                imageURL,
                contentMode: .fit,
                maxWidth: limitWidth ? scaledImageWidth : nil,
                maxHeight: cellHeight,
                cornerRadius: scaledImageWidth / 28
            )
            .frame(
                maxWidth: limitWidth ? scaledImageWidth : .infinity,
                maxHeight: cellHeight,
                alignment: .center
            )
        }
    }
}

struct HorizontalBooks: View {
    let publications: [Publication]
    let isDownloadable: Bool
    var onSelected: ((Publication, Bool) -> Void)? = nil
 
    var body: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(publications) { publication in
                    BookGridCell(
                        imageURL: publication.coverURL,
                        title: publication.title,
                        author: publication.author,
                        publicationDate: publication.publicationDate,
                        downloadURL: isDownloadable ? publication.downloadURL : nil) { wasAlreadyDownloaded in
                            onSelected?(publication, wasAlreadyDownloaded)
                        }
                }
            }
            .modifier {
                if #available(macOS 14, iOS 17, *) {
                    $0
                        .scrollTargetLayout()
                } else { $0 }
            }
        }
        .modifier {
            if #available(macOS 14, iOS 17, *) {
                $0
                    .scrollTargetBehavior(.viewAligned)
            } else { $0 }
        }
    }
}
