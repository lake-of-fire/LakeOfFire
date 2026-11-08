# Preserve managed transcript primary keys

Main base a6d6f82b3156b7faaeeb59dce2ae1eb3021cfdf3.
Donor Lake #113 head 367775198f6b402cb5708896a44469abf788ccd3.

Main setWebVTT called updateCompoundKey, which unconditionally assigned the
persisted primary key. Core ReaderWebMediaCoordinator.persistTranscript calls
setWebVTT on an existing managed row inside its write. Realm's managed primary-key
setter rejects assignment after insertion; no runtime crash has been reproduced
in this pass. SDK source reference: realm/realm-swift v20.0.5,
Realm/RLMAccessor.mm makeSetter and willChange primary-key guards.

Adapt the donor's managed-identity safeguards without its broader parser or
language normalization. updateCompoundKey computes/assigns keys only for unmanaged
rows. setWebVTT rejects a managed key/identity-field mismatch before payload or
metadata mutations, using a new immutableIdentity codec error. Matching managed
rows can update their transcript without assigning their key. Existing public
identity fields remain mutable; this is not comprehensive model immutability.
A direct updateCompoundKey call on a managed mismatch is deliberately a no-op,
matching the donor's nonthrowing API. The stricter setWebVTT boundary rejects it.

The new public enum case may require downstream exhaustive switches to add a
case/default. No existing signature or Realm schema changes; the key algorithm
and original main's language spelling remain. No migration or repair of existing
inconsistent rows, account/store fencing or transaction-wrapper change.

Four authored tests (three using real Realm) cover unmanaged recomputation, managed same-key
payload update, direct managed key-update no-op, and mismatch rejection before
payload/metadata mutation. Each uses a unique in-memory Realm with only
MediaTranscript in its schema. Native compilation and all tests remain UNRUN.
The test target already depends directly on RealmSwift and LakeOfFireContent;
generated Xcode membership and full Core caller execution remain unqualified.

Fresh main/donor and #533/#534 scopes checked, plus bounded immutable/transcript
identity PR searches. This changes different methods from allocation/UTF-8
drafts. Core #1195 treats codec errors as cache misses during reading only; this
new error is thrown by writing, whose existing failure behavior remains.

No pins, native builds, CI dispatch, deployment, production changes or retries
of denied/uncertain operations.
