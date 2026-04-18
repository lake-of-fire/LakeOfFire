import SwiftUI
import RealmSwift
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent
import LakeOfFireContentUI

public struct FeedCell: View {
    @ObservedRealmObject var feed: Feed
    var includesDescription = true
    var horizontalSpacing: CGFloat = 10
    
    @ScaledMetric(relativeTo: .headline) private var scaledIconHeight: CGFloat = 26

    private var showsAudioIndicator: Bool {
        feed.firstEntryHasAudio
    }

    private var showsUnreadIndicator: Bool {
        feed.hasEntriesNewerThanLastViewedAt
    }

    private var titleLabel: Text {
        unreadIndicatorTitleSegment
        + titleText
        + audioIndicatorTitleSegment
    }

    private var unreadIndicatorTitleSegment: Text {
        guard showsUnreadIndicator else { return Text("") }
        return Text(Image(systemName: "circlebadge.fill"))
            .font(.subheadline.weight(.regular))
            .foregroundColor(.accentColor)
            + Text("  ")
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

    private var audioIndicatorTitleSegment: Text {
        guard showsAudioIndicator else { return Text("") }
        return Text("  ")
            + Text(Image(systemName: "headphones"))
                .font(.subheadline.weight(.regular))
                .foregroundColor(.secondary)
    }
    
    public var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading) {
                HStack(spacing: horizontalSpacing) {
                    ReaderContentSourceIconImage(
                        sourceIconURL: feed.iconUrl,
                        iconSize: scaledIconHeight
                    )
                    .saturation(feed.isArchived ? 0 : 1)
                    .opacity(feed.isArchived ? 0.8 : 1)
                    .padding(4)
                    
                    titleLabel
                        .font(.headline.bold())
                    Spacer()
                }
                if includesDescription, let markdownDescription = feed.markdownDescription, !markdownDescription.isEmpty {
                    Text(markdownDescription)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(Int.max)
                }
            }
            Spacer(minLength: 0)
        }
        .tag(feed.id.uuidString)
    }
    
    public init(feed: Feed, includesDescription: Bool = true, horizontalSpacing: CGFloat = 10) {
        self.feed = feed
        self.includesDescription = includesDescription
        self.horizontalSpacing = horizontalSpacing
    }
}
