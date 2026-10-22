# Page Mark advance must use the latest full native snapshot

## Full publication before the command reply

A visible-page Mark can commit with native snapshot sequence N, while an
independent chapter read publishes a complete snapshot N+1 before the original
Mark reply arrives. The document, account, chapter pass and navigation intent
can all remain current.

The Book state controller correctly refuses to move its ordering watermark
backward to N. Previously, `refreshCommittedVisibleMarkReadState` treated that
refusal as failure of the entire follow-up. `Reader.#submitMarkReadPayload`
assigns the helper's Boolean to `completed.mayAdvance`, so a saved page Mark
could lose optional advance even though newer full state was already available.

Reuse already-ready newer full state only if its own revision still passes the
existing ordering check. Do not lower the watermark, merge the older reply's
subject lists, post a redundant read or consume another pending query. Normal
reply-first behavior still requests a full chapter snapshot.

## Partial receipt after a full publication

The reverse ordering also needs a guard at the final advance predicate:

1. Mark's full chapter state at revision N is successfully published.
2. A later partial Mark/Unmark reply advances the controller watermark to N+1.
3. The shell still caches the full projection and successful-publication marker
   for N while the next complete native sample is pending.
4. The optional page advance checks that cached projection.

Previously `committedVisibleMarkReadStateIsPresented` checked matching full-state
and renderer revisions, the original Mark minimum, and all submitted segments,
but not the newer partial-reply watermark. It could return true for the overtaken
full snapshot. Core's `completeManualReadReplyPublication` explicitly forwards
partial reply sequences to the shell's `noteManualReadSnapshot`; this does not
replace the shell's full chapter state.

Recheck the full projection's own revision through that same ordering gate
before allowing advance evidence. On the real controller this can only retain
the same watermark or reject an older revision; it cannot lower ordering or
publish anything. A subsequent full snapshot at or beyond the partial cut can
restore eligibility, provided its actual successful-publication marker matches
and every originally submitted subject remains read. A full Unmark snapshot
which removed a submitted segment continues to prevent advance.

## Ownership and effects

These helpers establish only reading-state eligibility. The Reader retains its
separate original document, account, pass, page, Mark-generation and navigation
intent checks. The helpers do not navigate, perform a native write, renew Undo,
retry a command or create a timer. Saved native outcomes stay independent of
optional publication and movement.

The defect is reproduced at the production coordinator/controller/predicate
boundary. Actual renderer movement and customer incidence are not established
by these component tests.

## Regression coverage

The new `ebook-mark-snapshot-before-reply.test.mjs` imports the complete request
module and Book state controller with their real producer/UUID dependencies.
It controls message order and publication acceptance, not the implementation.
Coverage includes both response orderings, an overtaken cached full projection,
subsequent complete recovery, intervening Unmark, independently pending reads,
retired ownership, malformed sequences and successful renderer publication.

Run it with the unchanged exact-visible-commit suite:

```sh
node --test --test-reporter=tap \
  Tests/JavaScript/ebook-mark-snapshot-before-reply.test.mjs \
  Tests/JavaScript/ebook-visible-mark-read-commit.test.mjs
```

The existing Book Actions JavaScript roster discovers `.test.mjs` files. No new
runner or duplicate test inventory is required. Full-suite, native Realm,
WKWebView, actual automatic page movement and device checks remain separate.

## Composition

LakeOfFire #213 retains the optional continuation when a full publication is
late. This repair covers publication before the reply and rejects later-stale
full evidence. Preserve #218's first-dispatch guard, #219's preparation-failure
notice and #220's restored-terminal observation when composing this same file.
No dependency pin or assembled integration is selected by this component fix.
