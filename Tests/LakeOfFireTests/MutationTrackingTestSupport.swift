import BigSyncKit
import LakeOfFireContent
import RealmSwift

func configureLakeOfFireMutationTrackingForTesting(
    _ configuration: inout Realm.Configuration
) {
    var objectTypes = configuration.objectTypes ?? []
    if !objectTypes.contains(where: {
        $0.className() == BigSyncPendingMutation.className()
    }) {
        objectTypes.append(BigSyncPendingMutation.self)
    }
    if !objectTypes.contains(where: {
        $0.className() == LibraryOPMLImportLease.className()
    }) {
        objectTypes.append(LibraryOPMLImportLease.self)
    }
    configuration.objectTypes = objectTypes
    BigSyncMutationTracking.install(
        configurations: [configuration],
        excludedClassNames: [
            LibraryOPMLImportLease.className(),
            ReaderFilePostprocessorDebt.className(),
            ReaderFileLegacyRootRelocationReceipt.className(),
        ]
    )
}
