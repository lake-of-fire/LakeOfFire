import SwiftUI
import RealmSwift
import LakeImage

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
    @ScaledMetric(relativeTo: .caption2) private var scaledNewBadgeHeight: CGFloat = 19
    
    private var showsAudioIndicator: Bool {
        feed.firstEntryHasAudio
    }

    private var showsUnreadIndicator: Bool {
        feed.hasEntriesNewerThanLastViewedAt
    }

    private var showsStatusRow: Bool {
        showsUnreadIndicator || showsAudioIndicator
    }

    private var showsDescription: Bool {
        includesDescription && !(feed.markdownDescription?.isEmpty ?? true)
    }

    private var shouldCenterTitleWithIcon: Bool {
        !showsStatusRow && !showsDescription
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
                HStack(alignment: shouldCenterTitleWithIcon ? .center : .top, spacing: horizontalSpacing) {
                    LakeImage(feed.iconUrl)
                        .saturation(feed.isArchived ? 0 : 1)
                        .opacity(feed.isArchived ? 0.8 : 1)
                        .cornerRadius(scaledIconHeight / 5, antialiased: true)
                        .frame(width: scaledIconHeight, height: scaledIconHeight)
                        .padding(4)
                    VStack(alignment: .leading, spacing: 6) {
                        titleText
                            .font(.headline.bold())

                        if showsStatusRow {
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
                            .frame(height: scaledNewBadgeHeight)
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
