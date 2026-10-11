# Preserve imported script activation state — 2026-10-11

Exact reviewed parent: Lake #138 `d2ef2b51555ab835d2fd33614104665c33122ed1`.

The exporter emits each user script's isArchived flag, and active-script descriptor selection excludes archived scripts. The importer initially applied the requested flag (defaulting to true when absent) but then unconditionally reset an archived script to false. Its hasChanges check likewise treated every archived script as changed even when the OPML requested that state. Thus a disabled exported script became enabled after import, and repeated imports could keep journaling it.

Removed those two unconditional archived-state branches. The existing explicit attribute comparison/application is now authoritative. Deleted imported records still revive as before; explicit false remains enabled, explicit true stays disabled, and omitted archive state uses the existing true default.

Added a real export-to-file/import-into-second-Realm round-trip regression for one enabled and one disabled script, then repeat-import checks for preserved state, references, row count and the disabled script's unchanged modification date. The membership regression also asserts the omitted-attribute default. LibraryCapturedMutationPortTests now has four methods. They are UNCOMPILED/UNRUN; no runtime reproduction or passing result is claimed.

This follows the previous duplicate-selection and script-membership repairs. Source and existing execution-filter contract corroboration only. No builds, tests, native apps, CI, generators, pins, merges, closures, deployment or production changes. Root #384's file/module registration exists at `90a668a63b9549a11c4d7f1f70cef1f236f5848e`; its cumulative method count needs the one-method increment recorded separately.

## Distribution compatibility source check — 10:44 UTC

Inspected both shipped website OPML sources at manabi master `7d34412932248c9ed55c48f2875ac5c814f6b47e`: [legacy defaults](https://github.com/lake-of-fire/manabi/blob/7d34412932248c9ed55c48f2875ac5c814f6b47e/manabi/static/reader/manabi-reader-defaults.opml) and [v2 defaults](https://github.com/lake-of-fire/manabi/blob/7d34412932248c9ed55c48f2875ac5c814f6b47e/manabi/static/reader/manabi-reader-defaults.v2.opml). Both script outlines in each file (Matcha cleanup and NHK consent) explicitly set isArchived="false", so honoring the importer attribute keeps those bundled scripts enabled. This is repository-source evidence, not a claim about the currently served deployment or every external OPML file.
