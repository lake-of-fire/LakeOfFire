# Mark/Unmark transport diagnostics must not interrupt settlement

## Defect

The initial command transport catch formats its error before calling `finish`.
A page-realm thrown value need not be an ordinary Error: its `message` accessor
or string conversion can throw, and a null-prototype object has no usable
primitive conversion. A second formatting exception escaped `request`, leaving
its already-installed pending entry and observation timer alive without
returning the command promise. A synchronous accepted native terminal could
also be obscured from the caller by this later diagnostic exception.

The control-message catch independently called `String(error)` without guarding
conversion. During a status timer, this exception prevented the existing loop
from scheduling its next observation. During Cancel, it escaped before the
normal observation refresh. Neither exception establishes the native outcome of
an already-submitted command.

These are controlled failures at the coordinator's existing transport seams,
not evidence that standard WKWebView errors normally have throwing accessors,
measured customer incidents, or corruption of durable reading records.

## Repair

Use one module-private best-effort transport description helper. Preserve the
existing initial-post message/fallback policy; use a diagnostic fallback for
control errors. Accessor and conversion failures cannot escape this helper.
No new pending state, timer, retry loop, native field, Undo permission, queue,
Realm writer, or mutation replay is introduced.

Initial posting errors still follow the existing no-enqueue settlement contract.
An already accepted native result still wins. Errors while polling or cancelling
remain diagnostic: the original operation stays observable, and native can
still report that its commit won. A formatting callback that closes the Reader
retains the existing unknown-outcome close result instead of manufacturing a
new failure for that retired request.

## Focused evidence

The same 14 cases in `Tests/JavaScript/native-mark-read-transport-errors.test.mjs`
run against both complete production coordinator versions, importing the actual
Book state, producer-evidence and UUID modules. All baseline/dependency files
were checked against their Git blob identities. No implementation extraction,
module-loader substitutions or stubbed imports are used.

Node 22.16.0 Linux:

- Baseline `a4e923d7979f03bc45d0951bd3a5eedea320ee68`: 3 passed / 11 failed.
- Corrected `24207d67b23517e1322c3698bbece811f8888740`: 14 passed / 0 failed.
- Neither run skipped or cancelled cases. Source/test syntax and diff whitespace
  checks pass. Repeated Mark/Unmark/error variants are cases, not 11 product bugs.

```sh
node --test --test-reporter=tap Tests/JavaScript/native-mark-read-transport-errors.test.mjs
```

Native transport, terminal timing, control errors and observation scheduling are
controlled test collaborators. This is not a full workflow, DOM/WKWebView,
Realm, native test target, application or physical-device run.

## Composition

Base: LakeOfFire `v3-hotfix` at `997c442ebdaa53c7c18fc8e75fa33e105e4242bf`.
The helper and two catch changes are independent of #218's pre-dispatch guard,
#219's recovery preparation settlement, #220's restored-terminal observation,
and #222's bulk-cancellation roster. Preserve all those changes when composing
the shared coordinator. No existing PR head or application dependency pin is
changed by this narrow fix. Keep draft pending integrated native acceptance.
