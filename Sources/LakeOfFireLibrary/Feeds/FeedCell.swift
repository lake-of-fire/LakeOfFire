import SwiftUI
import RealmSwift
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent
import LakeOfFireContentUI

private struct FeedCellNewBadge: View {
    var body: some View {
        Text("NEW")
            .font(.caption2)
            .fontWeight(.semibold)
            .textCase(.uppercase)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .modifier {
                if #available(iOS 16, macOS 14, *) {
                    $0.baselineOffset(-0.5)
                } else { $0 }
            }
            .background(
                Capsule().fill(
                    Color(
                        red: 0x1d / 255.0,
                        green: 0x46 / 255.0,
                        blue: 0x75 / 255.0
                    )
                )
            )
    }
}

public struct FeedCell: View {
    @ObservedRealmObject var feed: Feed
    var includesDescription = true
    var horizontalSpacing: CGFloat = 10
    
    @ScaledMetric(relativeTo: .headline) private var scaledIconHeight: CGFloat = 40

    private var showsAudioIndicator: Bool {
        feed.firstEntryHasAudio
    }

    private var showsUnreadIndicator: Bool {
        feed.hasEntriesNewerThanLastViewedAt
    }

    private var titleText: Text {
        if feed.title.isEmpty {
            return Text("Untitled Feed")
                .foregroundColor(.secondary)
        }
        if feed.isArchived {
            return Text(feed.title)
                .foregroundColor(.secondary)
        }
        return Text(feed.title)
    }
    
    public var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading) {
                HStack(alignment: .top, spacing: horizontalSpacing) {
                    ReaderContentSourceIconImage(
                        sourceIconURL: feed.iconUrl,
                        iconSize: scaledIconHeight
                    )
                    .saturation(feed.isArchived ? 0 : 1)
                    .opacity(feed.isArchived ? 0.8 : 1)
                    .padding(4)
                    VStack(alignment: .leading, spacing: 6) {
                        titleText
                            .font(.headline.bold())

                        HStack(spacing: 8) {
                            if showsUnreadIndicator {
                                FeedCellNewBadge()
                            }
                            if showsAudioIndicator {
                                Image(systemName: "headphones")
                                    .font(.subheadline.weight(.regular))
                                    .foregroundColor(.secondary)
                            }
                        }

                        if includesDescription, let markdownDescription = feed.markdownDescription, !markdownDescription.isEmpty {
                            Text(markdownDescription)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .lineLimit(Int.max)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tag(feed.id.uuidString)
    }
    
    public init(feed: Feed, includesDescription: Bool = true, horizontalSpacing: CGFloat = 10) {
        self.feed = feed
        self.includesDescription = includesDescription
        self.horizontalSpacing = horizontalSpacing
    }
}
