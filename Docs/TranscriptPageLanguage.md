# Declared transcript language

`TranscriptPageAsset.makeHTML` and `fromWebVTT` accept a defaulted `languageIdentifier` rendering argument. Omitting it preserves the existing English root metadata. Explicit empty, whitespace-only or malformed input becomes `und`; this does not guess from transcript text or the device locale.

Rendering trims surrounding whitespace, replaces underscores with hyphens and lowercases ASCII tags. It accepts a bounded BCP 47-shaped subset: a 2–8 ASCII letter primary subtag, followed by nonempty 1–8 ASCII alphanumeric subtags, up to 64 characters total after trimming and separator replacement. This is not IANA registry validation or complete BCP 47 validation: unknown but well-shaped tags remain intact, private-use-only and grandfathered single-letter prefixes are rejected, and some structurally invalid extension sequences can pass. It intentionally does not perform Locale alias canonicalization. The result also passes through HTML attribute escaping.

This affects only the rendered root `lang` attribute. It does not change VTT storage, cue parsing, timestamps, transcript keys, URL routing, acquisition language policy, speech locales or asset ownership. Existing `:lang(ja)` styling can consume declared Japanese metadata; mounted behavior has not been verified.

`TranscriptPageLanguageTests` exercises the actual builder and factory, exact HTML equivalence except for root metadata, default compatibility, Japanese/region/script/underscore forms, unknown/invalid/injection values, raw VTT preservation and identity/timestamp preservation. It belongs to the existing `LakeOfFireTests` package target. These newly authored tests have not been compiled or run.

Paired consumer: ManabiReaderCore's presenter must forward its existing `languageCode` to this argument. Apply/select this Lake API before the Core caller change. No stored language property or playback-owner stack is required.
