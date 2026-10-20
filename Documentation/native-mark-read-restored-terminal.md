# Restoring a terminal Mark/Unmark observation

## Failure sequence

A native Mark/Unmark may finish after `pagehide`, or its terminal delivery may
race the native reading-state recovery handoff. The command promise must settle
with that native outcome, independently of whether presentation is current.

Previously `finish` removed the request from `pendingByRequestID` and could post
its one History status request while the page was hidden. Native's pending-read
handler requires the current observation document before admitting History
reconciliation, so a departed or not-yet-readmitted document can receive no
handoff. On `pageshow`, `resume` observed only pending commands. The already
terminal request lived in `recoveryByRequestID` instead and was never observed
again. A terminal received immediately after return also detached the lifecycle
listener before retaining its recovery, leaving the same gap on a subsequent
return. Controls could remain blocked behind a recovery whose native command
had already finished.

A second case affects an unavailable native outcome: after it had settled the
original waiter as unknown, the existing duplicate-terminal path accepted only
known success/failure. An exact repeated unavailable status could not acknowledge
the retained recovery barrier, even though it supplied no new command outcome.

## Correction

The existing request coordinator retains lifecycle observation while a terminal
recovery is awaiting native admission. It uses the same `observation` identity,
`timeoutHandle`, and status polling cadence for that original recovery, rather
than creating another timer owner or replaying a mutation. Hidden pages do not
post recovery status. Return observes the retained request ID and token, and an
early or lost status can be observed again while native restores the document.

The existing native `recoverHistoryReadingStatus` call is the handoff: it stops
the status observation before starting/queuing the single read-only attempt.
Successful or failed samples are not automatically retried. Departure pauses
observations; explicit retirement and close cancel their original timer and
release listeners. Original account/chapter ownership is checked around status
posting. A closed, retired, replaced, or already-admitted recovery cannot post.

Exact duplicates of an unavailable terminal may acknowledge only their retained
barrier. They remain unknown, not failed. Protocol/token/history flags and the
strict unavailable-result field allowlist still apply. Known and unknown
outcomes cannot replace each other. The common unavailable-result validator is
used for both first delivery and retained acknowledgement.

Native mutation admission, command payloads, durable outcomes, Undo authority,
read support, and native once-per-observation reconciliation are unchanged.
A repeated status is observation, not another Mark, Unmark, or reading-state
attempt. The native handler remains responsible for admitting and deduplicating
recovery and for final presentation acceptance.

## Regression coverage

`Tests/JavaScript/native-mark-read-restored-terminal.test.mjs` imports the complete
production coordinator. Tests control lifecycle events, timer firing, transport,
and native recovery callbacks. They cover Mark and Unmark success/failure,
hidden terminal delivery, immediate-after-return terminal delivery, repeated
return, a missed/early handoff, native-authorized success/failure, stale ownership,
close during ownership checking, explicit retirement, wrong tokens, and exact
unavailable-result acknowledgement without inventing an outcome.

Run in the repository with its normal dependencies:

```sh
node --test Tests/JavaScript/native-mark-read-restored-terminal.test.mjs
```

## Execution and evidence limits

The publication run used Node 22.16.0 and the complete coordinator, Book state,
producer and UUID modules through their ordinary imports. All dependency bytes
were checked against their Git blob identities. No substitute loader or copied
coordinator was used in this run. The earlier local-only loader checkpoint is
superseded by this stronger component evidence, not added to its test total.

The final new suite has 16 cases: the original 14 plus two return-to-Book-state
journeys, for successful and failed Unmark. Those journeys invoke the actual
recovery adapter and actual Book state controller: the terminal withdraws old
controls, return posts only status, native authorization starts one read, and
its accepted full sample restores controls without replaying the mutation.
Transport, lifecycle, timing and native sample payloads remain controlled.

- Final 16 new cases on the untouched coordinator: 6 passed / 10 failed.
- Same 16 cases on the correction: 16 passed / 0 failed.
- New suite plus the unchanged 13-case recovery-queue suite: 29 passed / 0 failed,
  no skips or cancellations. The same combined roster on baseline is 19/10.
- A separate temporary composition of this patch with the exact production
  hunks from Lake #218 and #219 passes 31 component cases: the same 29 plus
  pre-dispatch retirement and refused-recovery-preparation interaction controls.
  That source and the two temporary controls are not part of this PR. This is
  a hunk-level component check, not full companion-branch or app qualification.

Commands for the maintained repository:

```sh
node --test --test-reporter=tap \
  Tests/JavaScript/native-mark-read-restored-terminal.test.mjs \
  Tests/JavaScript/native-mark-read-recovery-queue.test.mjs
```

These are controlled component results, not measured device incidence or a
native storage corruption claim. Full Node roster, actual browser/BFCache,
Reader/Core assembly, Realm/WKWebView, and device execution remain unrun. Run an
assembled return-while-Unmark-completes journey before release, including native
document re-admission slower than the first restored status request.

## Integration

The change is against LakeOfFire `v3-hotfix` at
`997c442ebdaa53c7c18fc8e75fa33e105e4242bf`. The production input blob was verified as
`a4e923d7979f03bc45d0951bd3a5eedea320ee68` before editing.

LakeOfFire PR #218 changes initial pre-dispatch admission in the same module.
Preserve that guard when composing this separate post-terminal recovery change;
neither fix grants the other's permission. Lake #219 changes preparation-failure
notice settlement in the existing authorized-query body. Preserve both that
settlement and this patch's stop-observation handoff when composing. The shared
nearby comment may require context resolution. Full combined app integration
remains deferred; only the component hunk composition above was executed.
