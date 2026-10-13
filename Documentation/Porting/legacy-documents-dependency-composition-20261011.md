# Legacy Documents migration dependency composition, 2026-10-11

Reviewed retained Lake #50 at 642250f9dee22b0460871006e803ae57151f5c12 and current Lake #138 at 3f6ef77b9fe50fbe1a52ee864ca2aa649bd6eeeb. Fresh Core #183 remains e71646312b548e694dd878ffc79410f063347f4f.

Core's current stacked StartupManabiReaderCore implementation already calls ReaderLegacyDocumentsMigration.shared.migrate, then requires a current iCloud identity/root and a successful Documents inventory refresh before publishing completion. The helper was absent from #138. This carries the reviewed helper and its 28 native cases from #50 without duplicating or changing Core's migration producer.

The helper preserves collided files/directories as whole recovered items rather than merging or overwriting packages. It uses coordinated descriptor-relative exclusive rename, validates root/destination/source identity, rejects top-level symlinks/special files, checks cancellation and leaves partial committed moves retryable. It does not fall back to copy-and-delete.

All 28 test bodies and the full helper were reviewed. Tests cover collision preservation, package indivisibility, hidden descendants, repeat/partial migration, cancellation, symlink/type boundaries, identity/metadata preservation and Unicode/filename bounds. All UNCOMPILED/UNRUN. No user files were migrated; no app/test/build was run.

This is one required Lake counterpart to the existing Core stack, not a new migration rollout or validated dependency tuple. Root test registration is required separately; current dependency pins remain untouched. Native owned-serving/cache and reading-authority schema composition remain open.
