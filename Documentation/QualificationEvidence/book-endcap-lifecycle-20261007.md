# End of Book activation, recovery and teardown — October 7, 2026

## Source and integration scope

Reviewed Lake #115 at `00063ef4b977a519e9acce42777f005c83b2b911` and its complete
Book-state, action-bridge, producer-evidence, runtime and endcap modules. During
this review #115 merged. The follow-up is based on current `v3-hotfix`
`6175ffa27e354727ed6a4d0a15b02290960c8417`, preserving the inventory/content-loading
changes included by that merge. Comparing the two revisions shows no changes to
any JavaScript input executed here.

One production module changes: `book-endcap.js` (154 additions, 70 removals).
Original Git blob: `de88bbea93df2fe846c7fdc57966ff1b9f3e6ac4`.
Repaired Git blob: `0a3549b288787609ef3ab47afe8299c88a012c7e`.
The other four paths are the Node suite, browser cases/runner and this report.
No original regression assertion is modified.

## Findings and repair

**Activation ownership.** The old `activate()` selected Finish/Restart before
busy rendering, but called its replaceable action handler afterward without
rechecking the account generation, readiness, selected action or visit. A
callback could switch accounts or leave and reenter, letting an old click
obtain the successor's native context. The repaired method brackets handler
lookup with the original admission check. It still accepts a committed result
after ordinary navigation: visit ownership limits dispatch, not an already
submitted command's result.

**Recovery continuity.** An unexpected recovery exception erased the existing
recovery descriptor. In the complete browser composition, a wrapper throws after
native status has succeeded; the next real button click then posts a new
`startBookOver` command on the original implementation. The repaired endcap keeps
the original request and checks its cached/native status instead. Explicit native
rejection still ends recovery. Handlers receive a descriptor copy, and optional
message formatting cannot turn acknowledged navigation failure or pending status
into a new mutation opportunity. Ordered state publications alone select Finished.

**Visibility and disposal.** Destruction formerly called `leave()` before marking
itself destroyed. A visibility observer could reenter and leave the publication
inert with its endcap removed; an observer exception could prevent removal entirely.
Focus restoration could also reenter synchronously, after which the old leave
cleared the successor's restoration target and emitted a stale notification.
Teardown now retires first and removes the original button listener. One visit
record replaces the separate visibility flag and three restoration fields. The
record carries existing accessibility/focus values and identifies the exact visit;
it is not native authority. Same-valued leave-and-return cannot adopt old work.

Rendering is centralized around private view state, including the displayed error
message. Independent optional paint failures cannot escape the void click listener,
strand `busy`, or change accepted command truth. There is no new timer, queue,
automatic retry, producer token, wire field, epoch writer or schema.

## Wider call-site review

Inspected the current paginator and fixed-layout call sites of `enter()` and
`leave()`. Endcap entry is attempted only at the terminal movement boundary;
unsuccessful entry returns no movement rather than falling through to another
physical page turn. Direct navigation ignores the leave return value. These
renderers are source-reviewed, not fully executed by this packet. Their existing
spine, CFI, geometry, page-count and no-read-evidence rules remain unchanged.

## Executed verification

Linux Node 22.16.0 and Chromium 144.0.7559.96. The Node selection consists of ten
complete test files: 48 new cases plus 235 unchanged Book-state, runtime, action,
recovery and endcap cases. The actual endcap and all its imported modules execute;
Node DOM/focus are explicit doubles. Browser execution loads complete production
runtime/controller/bridge/endcap modules with real DOM, iframe Documents, focus,
button clicks and timers. Native endpoints, Core frame projection, paginator and
exceptional callback behavior remain controlled collaborators.

| Final selection | Result |
| --- | --- |
| Node serial | 283 passed; zero failed/skipped/cancelled |
| Node JIT disabled | Same 283 passed |
| Reversed file order, concurrency four | Same 283 passed |
| Original endcap, identical 48 new Node cases | 6 passed; 42 reproduced failures |
| New complete-composition browser scenarios | 22 passed; no page/harness errors |
| Unchanged state / integrity / settlement browser scenarios | 16 / 17 / 18 passed |
| Original endcap, identical 22 browser scenarios | 6 passed; 16 reproduced failures |

Repeated configurations are not additional unique tests. The browser total is
73 distinct scenarios. The failures are related lifecycle/continuation gaps, not
42 independently observed customer bugs. Some tests deliberately inject getters,
render exceptions or wrapper failures; focus-event and visibility-callback cases
use ordinary synchronous browser behavior. No customer incident attribution is made.

Ten independently generated fault variants passed syntax checking and reproduced
13 / 11 / 4 / 1 / 2 / 6 / 1 / 2 / 3 / 1 runtime failures respectively. They cover
dispatch state, callback lookup, paint containment, teardown ordering, visit
identity, retained recovery, descriptor copying, outcome ownership, optional
formatting and original-listener cleanup. None changes test assertions.

Additional review rounds exposed gaps in earlier candidates: the expanded visit
roster had 3 failures, the recovery roster 5, and the formatting roster 3. Those
complete earlier receipts and candidate sources are retained separately; their
passes are not reported as final-revision verification.

## Reproduction

From the Lake checkout, with installed Node and Python Playwright/Chromium:

```sh
node --unhandled-rejections=strict --test Tests/JavaScript/book-endcap-lifecycle.test.mjs
node --unhandled-rejections=strict --jitless --test Tests/JavaScript/book-endcap-lifecycle.test.mjs
python3 Tests/Browser/BookEndcapLifecycle/run.py --output /tmp/endcap-lifecycle.json
```

The browser runner refuses to overwrite an earlier report and blocks all network
requests. `--endcap-source` selects a complete alternative endcap for the original
comparison; the Node equivalent is `LAKE_ENDCAP_SOURCE`. Source hashes, exact
commands, exit statuses and complete receipts are retained in the conversation's
verification packet. No repository/source-text assertions stand in for behavior.

## Acceptance boundary

Keep the follow-up draft pending the complete current Lake/Core workflow and
current Reader composition's hosted/native iOS acceptance. This iteration does
not run Realm/CloudKit, WKWebView, the full Foliate paginator or assembled iOS.
The merged #115's independent 464-case JavaScript and native review retain their
own exact sources; they do not automatically qualify this new endcap revision.
No Reader pin, generated project, source-qualification ledger, production data,
protected branch or release authorization is changed by this patch.
