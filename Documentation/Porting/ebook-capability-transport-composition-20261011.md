# eBook capability transport composition — 2026-10-11

Compared #138 5490c5883c6e1854e177207d8866988b9b37ce31 with retained #50 47c3307ef93e91dd3295ab31704a5446705d43ed.

Moved the existing base64/path/direct-section transport helpers out of EbookURLSchemeHandler.swift into their owning EbookEntryPathTransport.swift, preserving the main capability-provenance helper in EbookPackageCapability.swift. Composed #50's optional package-session selectors and entry-session path encoding/decoding. Missing capability and malformed/duplicate/valueless capability are distinct; header/query values must agree; a bound document cannot borrow another document's session or downgrade to a legacy asset path. Existing literal percent/Unicode/traversal behavior and newer direct-section selector regression remain intact.

Did not restore #50's unused ebookPackageSourceURL helper. Its overlapping source-provenance checks remain owned by the real ebookPackageCapabilitySourceURL route helper and existing capability suite. Added eight focused session identity methods to the existing transport suite (9 to 17 methods), including legacy absence through the real route helper. The older source and tests remain unchanged as historical evidence.

Swift UNCOMPILED; all tests UNRUN. No native execution, generation, build, CI, dependency pins or deployment. This is parser/encoding preparation: the scheme handler still lacks captured session reads and entry-session routing; no session is activated and Core/JS loader integration remains open. Next bounded action is the handler's synchronous receipt capture and final completion validation, retaining the newer processing/completion architecture. #50 remains open.
