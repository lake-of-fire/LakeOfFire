# Invalid OPML boolean values — 2026-10-11

At Lake #138 `7450e30f8c7813ee005c6791ca0c61c0f7f6d29e`, attributeBoolValue returned false for every present value other than exactly "true". In particular isArchived="invalid" bypassed the script importer's disabled-by-default fallback and enabled a script.

The optional parser now recognizes only the existing serialized literals "true" and "false"; unknown values return nil, allowing each caller's declared default to apply. This preserves both literal values and missing-attribute behavior. The real-import fixture now includes an invalid archive flag and asserts it remains disabled. Existing round-trip coverage includes explicit true/false. Suite count stays five, all UNCOMPILED/UNRUN.

Reviewed the current importer call sites: their existing defaults remain unchanged for injection flags, archived/commented state, reader defaults and feed metadata. Both bundled website default OPML sources at `7d34412932248c9ed55c48f2875ac5c814f6b47e` use lowercase true/false for script settings. This does not broaden the parser to accept numeric or case-folded alternatives.

No builds, tests, native launch, CI, pins, merges, closures or deployments. Root registration and 40-file/490-method source counts are unchanged.
