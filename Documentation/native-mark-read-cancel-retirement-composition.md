# Retire completed recovery without losing Cancel intent

## Follow-up to Lake #232

The original #232 composition (`500cdaa5bfa7857114c676775917fff092ba9741`)
keeps the improved terminal-recovery protocol and the original command's
`cancellationRequested` outcome. It still lacks #230's completed-recovery
retirement. An Unmark may finish while hidden, leave the ordinary pending map,
and retain a History recovery notice or query. A subsequent chapter/account
change invokes `cancelAll`, but the original composition visits only unfinished
commands. The obsolete recovery notice can survive, and its local query waiter
can keep waiting for a retired transport.

A same-chapter relocation also retires the original location revision without
calling the projection invalidator. Its next existing status observation used
to stop posting but leave the recovery and notice behind. A failed recovery has
no further automatic polling, so waiting for another timer is not a remedy.

This continuation composes an existing demonstrated correction, not a new
storage bug or sixteen independent defects. It does not establish customer
incidence, a native data loss, or a failed durable Unmark.

## Exact change

Bring the four production hunks from #230 at
`31141e69dcc5f554a6b25dcd94187724d1716d7d` into #232's existing coordinator:

- One `retainRecoveryOwnership` helper checks the configured original recovery
  owner and exact map entry before and after the callback. A withdrawn recovery
  is removed before its existing timer, waiters and notice are released.
- Existing status observation and request admission reuse that helper.
- `cancelAll` captures both original command and completed-recovery rosters
  before calling either kind of owner. New commands or recoveries admitted by
  callbacks do not enter this older sweep.

A current recovery with an empty Book context remains valid. A current failed
sample stays failed; cleanup never retries it. Completed command success/failure
and its original Cancel intent remain unchanged. No command replay, new native
message, timer cadence, queue, Undo permission, writer or persisted field is
introduced. The production delta from #232 is 30 additions and 13 deletions.

The existing #232 cancellation capture remains byte-identical. No Viewer,
Book-state controller, producer, native source, dependency pin or other candidate
branch is replaced. This is a selective source composition, not a merge of all
#230 browser runners and historical documentation.

## Maintained coverage and execution

Import #230's twelve-case `native-mark-read-retired-recovery.test.mjs` unchanged,
then add eight interaction cases to that test owner: Mark/Unmark, native
success/failure, and chapter/account departure while a cancelled command's
read-only recovery is suspended. Each case releases its deliberately held
transport even in the negative control. They require immediate local retirement,
unchanged original outcome/Cancel intent, no additional Cancel/status traffic,
and a later explicit command with its own uncancelled outcome.

The existing nineteen-case `native-mark-read-cancel-recovery-integration` suite
is byte-identical. Linux Node 22.16.0 executes complete production modules with
normal imports and real producer, Book state and UUID dependencies. Native
messages, account/location input, EventTarget lifecycle, timers, and the notice
sink remain controlled collaborators; there are no replacement module loaders
or copied coordinator implementations under test.

| Same final 39 cases | Passed | Failed | Skipped/cancelled | Exit |
| --- | ---: | ---: | ---: | ---: |
| Previous #232 coordinator | 23 | 16 | 0 | 1 |
| Composed coordinator | 39 | 0 | 0 | 0 |

The sixteen failures comprise eight pre-existing retirement failures and eight
new interaction variants. The preliminary 31-case runs are subsets of this
matrix, not additional test totals. Both negative and positive runs finish
normally; failures are notice/wait assertions, not setup or runner timeouts.

```sh
node --test --test-concurrency=1 --test-reporter=tap \
  Tests/JavaScript/native-mark-read-cancel-recovery-integration.test.mjs \
  Tests/JavaScript/native-mark-read-retired-recovery.test.mjs
```

Full production and changed-test syntax checks and diff-whitespace checks pass.
Source inputs were checked against their Git blob identities before editing:

- Previous #232 coordinator: `31d4604b97a15b7b049bb73a0bf5fd716177231d`.
- Composed coordinator: `0e70c376c62739d5d9ae7a0fe49acb9ecc3aa0bd`.
- Imported twelve-case test: `6aba841963be22815a870a7cb406e356a6654be6`.
- Expanded twenty-case test: `f1537eac68747ea224bfed90f8b085cad6ed8a20`.
- Unchanged nineteen-case test: `1967d293728da977d828e0e6b10cfd13fc25295d`.

## Remaining acceptance

Keep draft. This run does not execute the complete Viewer, native transaction or
retention, real account changes, BFCache, Realm, Swift/XCTest, WKWebView or devices.
#230's historical browser counts are not new execution of this composition.
The native read result is controlled in these cases; no durable reading facts
are inferred from a JavaScript success packet alone.

The separate sentence-backed complete-subject coverage correction noted in
#232 remains outside this follow-up. Preserve its paired Viewer/helper work
when composing later; do not replace this coordinator with an older whole-file
variant. No shipping merge, app pin, workflow dispatch, schema, or release change.
