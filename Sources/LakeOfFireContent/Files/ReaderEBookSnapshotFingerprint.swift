import Foundation

public extension ReaderEBookPackageSnapshot {
    /// Select the package document from this same snapshot before calling.
    /// Parse and serve resources from packageURL while retaining the snapshot;
    /// never restore against live bytes different from those fingerprinted.
    func fingerprint(
        packageDocumentPath: String,
        limits: ReaderEBookFingerprintLimits = .default
    ) throws -> ReaderEBookPackageFingerprint {
        try withExtendedLifetime(self) {
            try validateObservation(observationToken)
            let value = try ReaderEBookPackageFingerprint.readSnapshot(
                at: packageURL, packageDocumentPath: packageDocumentPath, limits: limits
            )
            try validateObservation(observationToken)
            return value
        }
    }
}
