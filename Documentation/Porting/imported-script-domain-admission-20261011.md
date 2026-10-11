# Reject malformed script-domain encodings — 2026-10-11

Reviewed Lake #138 `888c2ebe84428397d18054b0a84ccf6bb7d2b754` with the actual SwiftUIWebView source at `7c59736d60b4b209ced88f4668937e86f44540bd`.

The importer decoded domain entries with compactMap. Invalid percent encodings were silently dropped. SwiftUIWebView.updateUserScripts admits a script on every domain when allowedDomains is empty, so a nonempty but malformed restriction could become unrestricted execution for an enabled script. This is a source-established boundary failure, not an executed exploit or runtime reproduction.

Added one strict domain decoder shared by validation, change detection and mutation. The importer validates each script's restriction encoding before changing or creating that script. A malformed domain throws CocoaError.fileReadCorruptFile rather than being removed. Missing/empty domain attributes retain their existing intentionally unrestricted semantics. Valid percent encoding, decoded-name deduplication and first-occurrence order remain intact.

The new real-import regression first creates an enabled, restricted script in an isolated Realm, then attempts malformed updates to that ID and malformed creation of another ID. It requires rejection, unchanged source/title/activation/restrictions/modification date, and no new script or domain rows. The owning file now contains five methods, all UNCOMPILED/UNRUN. These are per-script admission guarantees; earlier unrelated entries in a multi-entry OPML import may already have committed.

No tests, builds, native apps, generators, CI, pins, merge, closure or production/deployment action. Reader root source registration already includes the file; the source-count checkpoint needs one additional method.
