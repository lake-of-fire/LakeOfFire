# Captured eBook serving handler composition — 2026-10-11

Compared #138 5e1fa49f72e0d32a5c6c19bcf92252edfd40abaf with retained #50 47c3307ef93e91dd3295ab31704a5446705d43ed. Read and composed actual handler differences; did not replace the newer main file wholesale.

## Source changes

- Capture package access synchronously at scheme-task receipt before detached work or cache/processing awaits. Registration replacement and lease withdrawal are checked again immediately before terminal response publication.
- Bound entries, descriptors and processed-section source bytes use the retained immutable package. Legacy reads remain explicit for a store that has never activated sessions; malformed, foreign and withdrawn capabilities cannot fall back.
- Add entry-session asset routing and carry the selected rendition in entries JSON. Include package-session identity in process-request deduplication and generated resource base URLs.
- Preserve current main processor signatures, payload representation, sidecar/cache implementation, fonts and task-completion ownership. Completion-proof/payload admission and their paired Core adapter are a separate unresolved difference, not silently overwritten here.

## Additional review finding

The retained #50 handler's no-processor /process-text response omitted the final package-read validation. This composition applies validation there too. A session withdrawn after receipt but before terminal publication must not publish that raw response. Authored a real-handler regression source for this path, plus handler store-replacement isolation. Added these to the six retained real-handler cases (eight total). These are source-correlated findings: no runtime reproduction has been executed.

All Swift UNCOMPILED, all tests UNRUN, including these WKWebView-host tests. No native launch, build, generation, CI, pin change or deployment. Tests create synthetic temporary packages only. Reader's explicit native test list must register EbookServingHandlerTests.swift before later qualification.

The optional Core/environment/session activation and matching JavaScript loader remain unwired. Existing legacy initialization is unchanged in this chunk. No end-to-end completion or release-readiness claim; #50 remains open. Next bounded action is wiring the loader/environment against the current main architecture, with cache/persistence completion admission traced before activating owned sessions.
