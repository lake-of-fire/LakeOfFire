import Foundation
import RealmSwift
import LakeOfFireContent

/// Resolves the preview on the caller's Realm thread. Publication is synchronous
/// and nonescaping, so no managed accessor crosses an actor or queue boundary.
enum LibraryFeedPreviewLoader {
    static func refresh(
        feedID: UUID,
        configuration: Realm.Configuration,
        publish: (Feed?) -> Void
    ) {
        let realm: Realm
        do {
            realm = try Realm(configuration: configuration)
        } catch {
            // Keep the displayed preview on an open failure. A later edit,
            // reload or feed update can retry through this same boundary.
            print("Failed to open feed Realm while refreshing preview:", error)
            return
        }
        // A successful lookup with no matching feed must still clear the preview.
        publish(realm.object(ofType: Feed.self, forPrimaryKey: feedID))
    }
}
