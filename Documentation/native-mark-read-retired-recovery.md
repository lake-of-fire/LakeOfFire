# Retiring completed Mark/Unmark recovery on reader departure

## Failure sequence

A Mark or Unmark can finish after the page is hidden. The coordinator settles
its original command promise and removes it from the unfinished-command map,
while retaining a separate History reading-status recovery. That recovery owns
its notice, status observation, and any joined presentation wait.

The EPUB Reader's Book state invalidation calls `cancelAll`. Before this change,
that operation visited only unfinished commands. A chapter or account change
therefore left the completed recovery's old notice and local wait alive. The
status observer could detect the lost owner, but only stopped posting; it did
not retire the record or its notice. Pruning waited until another command was
requested. In particular, an already-failed recovery had no later polling to
clean its notice.

A same-chapter move has another path to the same defect. Book state advances its
location revision and retires its own recovery without calling the projection
invalidator. The coordinator's next existing status observation sees that the
original location is no longer current, but previously left its obsolete notice
and listeners behind.

The native command outcome and display recovery have different lifetimes.
Removing an obsolete notice is not evidence that the saved read change failed,
and neither a replacement chapter nor a return to equal chapter values may
adopt that old recovery.

## Correction

`retainRecoveryOwnership` owns the existing exact-recovery pruning operation.
It asks the configured recovery owner, then checks that the same map entry still
belongs to this call. A retired entry is removed before its waiters, timer and
notice are released through the existing cleanup operations. A callback-created
successor cannot be consumed by the predecessor's cleanup.

Use that helper in all three existing observation paths:

- Request admission retains its old stale-recovery pruning policy, now with a
  fixed entry roster and checks on both sides of the owner callback.
- `cancelAll` captures both unfinished-command and completed-recovery rosters
  before calling either kind of owner. Its original unfinished commands retain
  normal Cancel semantics. Completed commands receive only presentation cleanup.
- The existing recovery status poll retires a recovery when its chapter/account
  predicate rejects it instead of merely stopping transport.

A null Book context is expected during a valid recovery. The configured Reader
predicate already distinguishes that from account, location or physical-document
replacement; the new helper does not infer obsolescence from null alone. A
still-current failed sample remains failed, and current samples are not retried
by `cancelAll`. No new timer, polling cadence, epoch, native message, write,
reservation, Undo deadline or mutation replay is introduced.

## Regression selection

```sh
node --test --test-reporter=tap \
  Tests/JavaScript/native-mark-read-retired-recovery.test.mjs
```

The suite imports the complete production coordinator, actual Book state
controller and existing recovery adapter. Its `onInvalidate -> cancelAll`
connection follows `Reader.open`; its ownership predicate follows the Reader's
captured account/location/scope checks. The suite controls transport, lifecycle
events, timer scheduling and the notice callback rather than pretending to run
the complete Viewer or a native writer.

Cases cover successful and failed completed Unmark, chapter and account changes,
same-chapter relocation, a retained failure notice, an active noncooperative query,
current null-context recovery, failure without automatic retry, ordinary pending
cancellation, callback-created successors, successor queue progress and a return
to equal chapter values. Original command results are retained, obsolete reads
cannot acknowledge the replacement, and only explicitly requested commands are
posted.

The held-query fixture exercises the coordinator's independent local retirement
boundary. The real Book state controller already settles many of its own reads
on relocation; the fixture does not establish that every real native query hangs
or that this bug corrupts stored reading facts.

## Integration and remaining qualification

This narrow change extends the completed-outcome observation work in Lake #220.
Preserve #222's entry-roster policy when composing the overlapping `cancelAll`
method: both rosters must be captured before callbacks. Other shared-module
changes such as #218, #219, #223 and #225 remain independent and must not be lost
by replacing a whole source file with a narrower branch.

The published follow-up is stacked on the composed Lake #213 implementation,
not the narrower #220 source. It retains the integrated initial-dispatch guard,
known local-failure settlement, immutable control envelope, captured semantic
intent, diagnostic containment and full-snapshot ordering. Applying an older
whole-file patch over that composition would drop unrelated corrections.

## Browser notice coverage

The existing `NativeMarkReadRecoveryLifetime` runner accepts an optional local
case module while retaining its original default. Use the retirement cases to
exercise the complete coordinator, Book controller, recovery adapter and notice
presenter against actual Chromium DOM:

```sh
python3 Tests/Browser/NativeMarkReadRecoveryLifetime/run.py \
  --cases Tests/JavaScript/native-mark-read-retired-recovery.browser.mjs \
  --browser /path/to/chromium --output /tmp/fresh-retirement-result.json
```

The cases check actual removal of successful/failed recovery notices on chapter
and account departure, same-chapter status observation, failed recovery without
automatic retry, current empty-context recovery, the existing Cancel button and
late query completion after local retirement. The command outcome and original
request count remain unchanged. The runner loads whole local ES modules offline;
it does not extract production functions or substitute module implementations.
Native messages, owner inputs, timer callbacks and synthetic lifecycle events
remain controlled collaborators. Synthetic pagehide/pageshow is not BFCache.

The full Viewer/renderer assembly, complete maintained JavaScript roster, native
account transitions, Safari/WKWebView, Realm and device qualification remain
separate. Native outcome/Undo truth is not changed by this presentation repair.
