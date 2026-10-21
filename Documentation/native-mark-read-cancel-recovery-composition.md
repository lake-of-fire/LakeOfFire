# Retain Cancel intent while composing terminal recovery

## Integration gap

Two reviewed EPUB candidates contain complementary coordinator behavior.
Lake #210 at `b72cc11b75cdd1a0c9732fe532cfbd4038ae28fe` keeps the #224
`cancellationRequested` outcome field. Its Viewer uses that field to suppress
optional automatic page movement when Cancel loses the race to a native
commit. The committed outcome must remain truthful and may still be displayed.

Lake #213 at `92759d845c64d6287c59847ecfbb2840cc40a052` contains newer initial
admission, terminal recovery, native outcome-expiry acknowledgement, transport
settlement and serialization corrections. That coordinator does not emit the
Cancel-intent field. Selecting it wholesale on #210 would silently remove an
input required by the already-composed Viewer. Leaving #210 unchanged retains
its older return-to-reader and transport gaps instead.

This is selective integration of existing fixes, not nineteen newly discovered
product defects. No shipping regression or customer incidence is claimed.

## Composition

Use the complete current #213 coordinator while retaining #210's original
three-line cancellation capture immediately after the pending slot is consumed
in `finish`. Capturing before renderer/cleanup callbacks ensures synchronous
Cancel completion cannot lose that original intent. It changes neither native
success/failure nor presentation permission.

All other #210 files remain untouched. In particular the Viewer retains its
coverage-withdrawal, navigation-intent, minimum animation and consume-before-
movement checks; package-processing provenance and native source remain as on
#210. This is not a merge of the peer PR's complete test/document history and
does not repin either assembled Reader candidate.

The coordinator keeps the newer existing recovery protocol: a terminal while
hidden retains its exact observation capability; return resumes status-only
observation; canonical native retention loss can acknowledge that capability
without changing locally known truth; native admission starts one read-only
Book recovery. Refused preparation or a failed sample remains a failure rather
than a retry loop. Local first-post failure has no fabricated recovery barrier.
Cancel All owns its original roster, and caller serialization is captured once.

No new mutation message, persisted field, timer cadence, authority mechanism,
Undo deadline or mutation replay is added by this composition.

## Maintained interaction coverage

`Tests/JavaScript/native-mark-read-cancel-recovery-integration.test.mjs` imports
the complete production coordinator and `BookReadingStateController` through
normal module imports, along with the real producer and UUID dependencies.
Native packets, transport/owner callbacks, EventTarget lifecycle and timers are
controlled collaborators. This does not execute native retention or BFCache.

The nineteen cases cover Mark/Unmark, Cancel/no-Cancel and native success/failure
through departure, return, expired-native-outcome acknowledgement and one actual
controller recovery sample. Additional cases cover synchronous Cancel replies,
local post failure during departure, withdrawn first admission, throwing error
formatters, one-shot serialization, callback-created successors during Cancel
All, failed preparation/sample without replay, and foreign or enriched expiry
packets. They observe the stored result separately from optional movement intent.

The fixture supplies the native location/revision required by a History response.
An initial local run omitted that field and failed eight matrix cases; the fixture
was corrected without changing production. That initial failure is not counted
as a new production defect or as a negative control.

## Executed evidence

Linux, Node 22.16.0. Identical final nineteen-case source against each complete
coordinator, with the same real module dependencies:

| Coordinator | Passed | Failed | Skipped/cancelled |
| --- | ---: | ---: | ---: |
| #210 `8628217c` | 3 | 16 | 0 |
| #213 `9b9796d4` | 5 | 14 | 0 |
| Composed `31d4604b` | 19 | 0 | 0 |

The #213 failures include explicit true/false cancellation-contract assertions;
they do not mean every failing scenario has an independent recovery defect.
Both controls exit 1 on behavior assertions, not missing imports or unresolved
tests. The final composed run also includes the twelve unchanged
`ebook-visible-mark-read-commit.test.mjs` cases: **31 passed, zero failures,
zero skips/cancellations**. The nineteen cases are included in 31, not added again.

Production/test syntax and diff-whitespace checks pass. Exact source identities:

- Original #210 coordinator: `8628217cb4dddddab8d4f4a5d3773c5dd689cf95`.
- Latest #213 coordinator: `9b9796d462f53d83ce93ed5359df8eed1211dcce`.
- Composed coordinator: `31d4604b97a15b7b049bb73a0bf5fd716177231d`.
- New test file: `1967d293728da977d828e0e6b10cfd13fc25295d`.

Removing only the three-line cancellation capture from the candidate reproduces
the latest #213 coordinator byte-for-byte. The candidate is not an excerpt-based
replacement. Temporary evidence and negative-control copies remain outside the
tracked repository.

```sh
node --test --test-concurrency=1 \
  Tests/JavaScript/native-mark-read-cancel-recovery-integration.test.mjs \
  Tests/JavaScript/ebook-visible-mark-read-commit.test.mjs
```

## Remaining qualification

Keep draft pending composed Reader/renderer, native transport and outcome
retention, Realm, WKWebView and device testing. These tests exercise the outcome
field consumed by the Viewer, not a real page turn or a native commit. They do
not establish complete-suite success or Apple module compilation.

The separate local complete-subject coverage correction is not included: both
the final page-turn gate and early permanent-withdrawal gate still need that
paired Viewer/module adaptation for sentence-backed subjects. Its old package
must not overwrite this newer coordinator. Rebase only its coverage helper and
matching Viewer/test adaptations; preserve this coordinator's recovery and
cancellation behavior. No shipping branch, app pin or workflow is changed here.
