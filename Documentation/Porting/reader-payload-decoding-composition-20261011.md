# Reader payload decoding composition — 2026-10-11

Reviewed current #138 27a4bc463d05129c1335416e0c1046d6df348ce7 against retained #50 642250f9dee22b0460871006e803ae57151f5c12 and #41 af14b895d9d3e1a1fe8c3a00e52c158d6eae211e.

## Composed
The current WebView initializer entry points remain, forwarding to Foundation-owned content and position payload decoders. The newer readability frame-eligibility helper, console/image/direction/navigation/RSS messages and handler architecture are retained.

JSON booleans are distinguished from numeric zero/one by CF runtime type. Fractions are finite and within 0...1, CFI/reason/document URL lengths use the older byte bounds, restore success must agree with terminal state, and optional diagnostic provenance rejects nonfinite/boolean values. Required content strings retain existing rejection behavior, Japanese/ruby/HTML is unchanged, optional defaults are retained, and rejected caption dictionaries no longer dump potentially credential-bearing URLs. These are existing decoder repairs for upstream, not activation of unfinished media/transcript features.

## Producer compatibility correction
The older strict optional-integer decoder was not copied blindly. Both current and older ebook-viewer.js explicitly emit null when page numbers are unavailable. Null optional integers remain absence; malformed present values still reject. The corresponding repair is already published to #50 642250f9dee22b0460871006e803ae57151f5c12. See reading-progress-null-snapshot-20261011.md.

## Tests and limitations
Three owning regression files are carried: content values, macOS-only WebKit decoding, and position/restore values. They contain 45 test methods by source count (three macOS-only). All are UNCOMPILED/UNRUN for this composition. Existing restore-result tests remain untouched. No native host, build, test, project generation, CI dispatch or dependency change.

Shape validation does not authorize a persistence write or establish frame/document ownership. The current handlers are preserved; full receipt/owned-serving and paired Core completion-proof work remain open. The older historical workflow results do not qualify this composed head.

## Next bounded action
Register the three tests in root Tuist and continue native initial-restore/owned-serving composition; do not close #41/#50 as fully contained by this partial work.
