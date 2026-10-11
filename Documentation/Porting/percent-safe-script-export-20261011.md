# Percent-safe OPML script round-trip — 2026-10-11

Reviewed Lake #138 `65e3bc673dafc2bef7b2e8450505294bc92f7cb2`.

The exporter used a broad punctuation/symbol character set for percent-encoded script attributes. It allowed a literal percent sign through, while import unconditionally removes percent encoding once. A literal JavaScript string such as "%20" would be interpreted as an escape; malformed sequences such as a percentage or remainder operator could make decoding fail and fall back to an empty script.

The exporter now subtracts "%" from the existing allowed set. Literal percent signs become %25 and are restored by the existing one-pass decoder. The XML serializer still owns XML attribute escaping. No import-format reinterpretation was introduced: already-created external/legacy files with ambiguous unescaped percent sequences cannot be reconstructed reliably by guessing.

Strengthened the actual two-Realm export/import/reimport regression with literal %20, a percentage, the JavaScript remainder operator and Japanese text. It checks exact UTF-8 data equality after both imports in addition to activation state and modification stability. The suite remains four methods and Reader #384's source registration remains sufficient; the cumulative 40-file/489-method source count is unchanged.

Source review only. All Swift/tests remain UNCOMPILED/UNRUN. No build, native launch, CI, generator, dependency pin, merge, closure, deployment or production change.
