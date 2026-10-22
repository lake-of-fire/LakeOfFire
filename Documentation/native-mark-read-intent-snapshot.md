# One semantic snapshot for native Mark/Unmark admission

## Defect

The coordinator used two independent serializations of the caller's message:
first for its canonical intent fingerprint, later for the native packet. A
changing desired-state or subject getter, or a nested Book-scope `toJSON`, can
produce different values at these boundaries. The retained fingerprint then
describes a different operation from the one actually sent. A subsequent tap
whose desired state is opposite to that transmitted operation can incorrectly
join its completion instead of receiving `pendingTargetBusy`.

The second serialization ran after coordinator-owned correlation fields were
added. An enumerable root `toJSON` could remove or replace the request ID,
section ID, protocol or observation token. The local request then retained a
different capability from the packet delivered to native, so a reply using the
sent identity could not settle that original pending entry.

These are controlled serialization/API boundary failures. Normal plain-object
messages with stable values do not vary by themselves. The tests do not claim
that ordinary gestures randomly change intent, that native authority checks
were bypassed, or that a native write/data-loss incident occurred.

## Correction

Prepare one plain JSON object before coalescing or admission. Reject a null,
scalar or array serialization result before installing a pending entry or timer.
Use the captured object for both the existing canonical fingerprint and the
packet. Append coordinator-owned transport correlation only after caller
serialization, reassert the original section ID, and retain the existing deep
freeze before dispatch.

No getter or serializer from the caller is read again when constructing the
packet. Equal intents still coalesce irrespective of key order or caller-supplied
transport fields; opposite desired states, different subjects and different
Book passes remain distinct. All existing owner, capacity, original producer,
reply, cancellation, lifecycle, Undo and native transaction checks remain.
There is no new timer, retry, queue, persistent state or mutation authority.

## Focused execution

`Tests/JavaScript/native-mark-read-intent-snapshot.test.mjs` imports the complete
production coordinator and its real Book-state, producer-evidence and UUID
dependencies through ordinary imports. No extracted production implementation,
module-loader replacements or unused-import stubs are involved. Source and
dependency bytes were verified against their Git blob identities.

Node 22.16.0 Linux, identical 13-case selection:

- Original production `a4e923d7979f03bc45d0951bd3a5eedea320ee68`: 4 passed / 9 failed.
- Corrected production `7d3b3bd7fd55dccceb340103550e8e1776c58c21`: 13 passed / 0 failed.
- No skipped or cancelled cases. Complete source/test syntax and diff whitespace
  checks pass. Nine failing case variants are not nine independent product bugs.

Coverage includes Mark and Unmark getters, actual transmitted opposite intent,
changing subject selection, nested chapter-pass serialization, root correlation
replacement, invalid root results, caller mutation after dispatch, canonical
coalescing, failed preparation and close during preparation.

```sh
node --test --test-reporter=tap Tests/JavaScript/native-mark-read-intent-snapshot.test.mjs
```

The transport, native outcomes, owner and timer collaborators are controlled.
This is not native admission/writing, full Reader boot, browser/WKWebView,
Realm, BFCache, UI gesture or device acceptance.

## Integration

Base: LakeOfFire `v3-hotfix` `997c442ebdaa53c7c18fc8e75fa33e105e4242bf`.
One existing production module changes, with 17 added and 5 removed lines.
Preserve #218's first-dispatch guard, #219's preparation-failure settlement,
#220's restored-terminal observation, #222's cancellation roster and #223's
best-effort error formatting when composing this shared module. This patch
changes only semantic preparation and packet construction; it does not include
or replace those independent corrections. No root dependency pin, existing
branch, workflow, schema, production dataset or release is changed. Keep draft
until the selected combination is qualified on the owning platforms.
