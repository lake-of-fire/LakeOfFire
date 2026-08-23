import BigSyncKit
import RealmSwift

func configureLakeOfFireMutationTrackingForTesting(
    _ configuration: inout Realm.Configuration
) {
    let objectTypes = configuration.objectTypes ?? []
    if !objectTypes.contains(where: {
        $0.className() == BigSyncPendingMutation.className()
    }) {
        configuration.objectTypes = objectTypes + [BigSyncPendingMutation.self]
    }
    BigSyncMutationTracking.install(
        configurations: [configuration],
        excludedClassNames: []
    )
}
