# Inventory presence at metadata admission — October 6, 2026

## Reviewed boundary

Lake base `e5157aab215286a34a2b4b970ef5c37012401405` preserves the completed deletion-coordination and browser-fixture work. The manager is byte-identical to Reader #286's selection at `7d142f429443e5e08640976dcdfd6196dff39223`.

Directory enumeration, resource inspection and asynchronous URL mapping precede the independent metadata transaction. Before this change, a mapped path could disappear before that transaction and still reach `setMetadata`. The latter can create a row or clear `isDeleted`, explicitly refreshing its mutation metadata. The logical consequence is a phantom ContentFile or a replaced deletion-journal generation; selected drive/Realm/initialization identity alone does not prevent that history.

## Correction

Inside the existing owned write, resolve the retained drive-relative path and require current filesystem presence before looking up or mutating its ContentFile. Reuse the existing throwing presence helper: explicit absence skips that entry; inspection errors still propagate and retain transaction failure behavior. Return the existing MetadataScanResult rather than IDs alone so per-file absence propagates `isComplete = false` to the root inventory. A partial scan must not authorize unrelated orphan tombstones. Healthy siblings remain eligible, and legitimate same-path reimports present at admission still revive normally.

The mutation/journal implementation, existing actor/queue/selection fences, schema and public APIs are unchanged. This adds no retry policy or ownership system. It does not make the filesystem and Realm one atomic snapshot or prevent every external change after an inspection. No measured performance claim is made for the extra per-candidate inspection.

## Native regressions authored

`ReaderFileInventoryAdmissionTests` contains six methods using the actual manager, filesystem, Realm and mutation journal. Only the asynchronous URL-mapping boundary is held. Scenarios cover public deletion followed by stale scan completion, disappearance before first indexing, conservative orphan retention and subsequent complete cleanup, healthy siblings, legitimate reimport, and preserving an already-deleted row's journal generation. No mock Realm is substituted in these tests. All fixtures use unique temporary storage and explicit objectTypes including BigSyncPendingMutation.

Native build, discovery and execution have **not** run in this review. The counterexample above is source analysis, not a claimed measured native failure. The tests must be registered and run in the actual owning Reader/Lake graph.

## Executed source checks

Hosted source-preparation run `37555466430`, job `112580553177`, completed successfully. It parsed the complete original manager, complete revised manager and complete new native test file; all three parser exits were zero. Parsing does not resolve native framework imports or typecheck the assembled app and executes **zero test methods**.

Artifact `11454770353` SHA-256 `ed4ca54d6072bbd8276d9aab01be73c42a3636d1003c7a425826aa5d1d1a82eb` was downloaded and checked byte-for-byte against the locally reviewed full source and tests. The temporary preparer stored only one hash-checked immutable source blob and changed no Git ref. It and its write-enabled workflow are removed from this final tree; source selection uses the normal branch tool separately.

Exact inputs:

- Original manager: `0f50121aa93b4ff2c958f37bbcd28ac5e4b41481`
- Revised manager: `a796b227c4688d40243ccd424370d4677a7f65e8`
- Native test file: `ce54ec6235c39c9ca64cbf91f7a567f6ee606701`

`git diff --check` passes. Existing queue CI does not qualify the changed manager. No earlier native, controlled, JavaScript, signed or release evidence is relabelled onto this change.

## Integration

Add the six method identities to both Reader native inventories and the new file to the existing ManabiReaderTests source list, update only the Lake selection and relevant source hashes, and preserve every other newer dependency pin. Run current provenance checks, actual GetTestList discovery, the new class, and the adjacent library-boundary/initialization/inventory/import owners.

Mac UI, signed Mac journeys, performance and application Release remain owner-deferred. Authentic released-Realm provenance and genuine second-account evidence remain separate unresolved gates. No protected target merge, production file/Realm/CloudKit mutation, deployment or release authorization.
