# Feed refresh request-admission port — 2026-10-11

## Exact source

- Destination parent: Lake #149 `67a8a84387b4d9d78cfc0caa91eee6e32a25ba62`.
- Source: remote Reader v3-hotfix `8008cf2d84fb4aa331f4b226775cc38270925311`, selecting Lake `036d4193078016db0becdf91b86dd34fb1d579e0`.
- Related review: https://github.com/lake-of-fire/LakeOfFire/pull/149#issuecomment-6111535200

The hotfix already carries feed refresh generations and original-URL validation. The newer upstream parser/persistence implementation and retained #50 lacked these checks. This focused draft adapts that missing behavior without copying the older parseAsync callback layout or replacing newer payload/mirror handling.

## Changed behavior

Feed.fetch captures its URL and a per-feed request lease before transport. It retires only its own lease and checks cancellation, deletion, URL and generation after transport/retry and before persistence. RSS, Atom and metadata paths carry the original URL and lease into persistence.

The shared writer-admission function re-resolves the feed and validates cancellation, current URL, nondeleted state and current request generation. It runs inside ownership-preserving transactions for metadata/validators, Atom collections and shared entry/orphan upserts. Rejected writes throw CancellationError rather than reporting a successful refresh. Mirror dispatch also checks admission before each existing mirror operation.

The registry implementation is retained from the hotfix in a dedicated source file. Main's synchronous parser, common upsert, payload preservation, body-only mirror updates, source metadata and module boundaries remain intact.

## Tests and membership

Eight new behavioral test methods: same-feed supersession, stale completion not retiring a newer lease, independent feed requests, and real-Realm writer admission for a current request, changed URL, deleted feed, newer request and retired request. The Realm cases invoke the same production admission function inside a transaction and inspect persisted freshness/ETag values.

Sources are discovered by the existing LakeOfFireContent target; tests by the existing Tests/LakeOfFireTests package target. Root Xcode test membership/discovery is not claimed.

All tests are UNCOMPILED / UNRUN. No build, native test, generation, launch or workflow dispatch was performed. Source readback is not runtime qualification.

## Deliberately unresolved

This is one missing hotfix behavior, not complete feed/widget qualification.

- The registry is keyed by Feed UUID. Captured physical-store/account generation, same-ID reincarnation and URL A→B→A without a new request remain separate admission concerns.
- The legacy timestamp does not record durable originating URL. Already-completed freshness/validators can survive later URL edits; the Core widget producer must not treat this port as proof that every timestamp belongs to the current URL.
- Entry/collection commits and mirrored reader-content writes span transactions. Pre-dispatch validation does not establish final admission inside every downstream mirror write after suspension, nor make the whole refresh atomic.
- Do not advance Reader's dependency pin or close broader port PRs based on this draft. Extend the origin/store admission coherently, add controlled suspended-fetch/late-writer tests, register the intended root tests, and qualify the assembled tuple when execution is authorized.
- Unfinished media/transcript work is excluded from hotfix release scope. Existing upstream fields were preserved; none was newly introduced here.

No schema, production setting, dependency pin or historical evidence was changed.
