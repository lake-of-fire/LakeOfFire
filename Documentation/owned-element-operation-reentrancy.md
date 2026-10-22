# Reentrant element-operation replacement

## Failure

`beginOwnedElementOperation` previously finished the old operation before
installing its replacement. Cleanup is an external callback: it can synchronously
start another operation for the same element or request that its current operation
finish. The outer call then installed its older replacement over that later
operation (or over the explicit finish). The nested operation could remain active
but unreachable through `finishOwnedElementOperation`; later cleanup would target
the wrong owner.

The EPUB viewer uses this helper for navigation-button spinner/icon/label cleanup.
This is a reproduced helper ownership defect, not evidence of a customer Unmark
incident, a native reading-state mutation, or an end-to-end navigation failure.

## Repair

Capture the predecessor, install the replacement, then finish the captured
predecessor. Cleanup can now retire the in-progress replacement or install its
successor without the returning outer call overwriting that decision. A superseded
call returns its own inactive handle, never another caller's active handle.

The existing finish path still detaches its slot before invoking cleanup; cleanup
remains best-effort and idempotent. Invalid input is rejected before changing any
owner. Different elements remain independent. No extra generation, retained map,
queue, listener, timer, authority, persistence, or wire format is introduced.

## Focused execution

Run from this repository:

```sh
node --test Tests/JavaScript/owned-element-operation.test.mjs
```

Node 22.16.0 on Linux executed the complete production module and all ten tests.
The original source bytes were checked against Git blob
`2b78dd13fc03477c5e0ce6e5c78c14ccc326b3ba` before editing.

- Original source plus unchanged expanded tests: 6 passed, 4 failed, exit 1.
- Repaired source plus the same tests: 10 passed, 0 failed, exit 0.
- Both runs: 0 skipped, 0 cancelled.

The three pre-existing tests are preserved. Seven additions exercise reentrant
successor admission, explicit cancellation, a successor that immediately finishes,
throwing cleanup, independent elements, ordinary finish reentry, and invalid
replacement input. No assertion inspects production source strings.

The tests use plain element identities and controlled cleanup callbacks. Real DOM
lifecycle, WebKit, native Realm, the assembled Reader, and release qualification
were not run. Reader dependency pins and automated workflow configuration are
unchanged.
