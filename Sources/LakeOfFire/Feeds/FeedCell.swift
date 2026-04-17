import SwiftUI
import RealmSwift
import LakeImage

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
    
    @ViewBuilder
    private var titleLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if feed.title.isEmpty {
                Text("Untitled Feed")
                    .foregroundColor(.secondary)
            } else {
                Text(feed.title)
                    .foregroundColor(feed.isArchived ? .secondary : nil)
            }
            if showsAudioIndicator {
                Image(systemName: "headphones")
                    .font(.headline.weight(.regular))
                    .foregroundColor(.secondary)
                    .padding(.leading, 10)
            }
            if showsUnreadIndicator {
                Image(systemName: "circle.fill")
                    .font(.headline.weight(.regular))
                    .imageScale(.small)
                    .foregroundColor(.accentColor)
                    .padding(.leading, 10)
            }
        }
    }
    
    public var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading) {
                HStack(spacing: horizontalSpacing) {
                    LakeImage(feed.iconUrl)
                        .saturation(feed.isArchived ? 0 : 1)
                        .opacity(feed.isArchived ? 0.8 : 1)
                        .cornerRadius(scaledIconHeight / 5, antialiased: true)
                        .frame(width: scaledIconHeight, height: scaledIconHeight)
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
