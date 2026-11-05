# EPUB filename identity and namespace review

The package fingerprint must preserve original resource path bytes. However, not every pair of distinct byte paths can safely coexist inside one EPUB. EPUB 3.3 section 4.2.3 requires sibling names to remain unique after canonical normalization and full case folding: https://www.w3.org/TR/epub-33/#sec-container-filenames

The earlier scanner rejected canonically equivalent complete paths, but it missed case aliases and inconsistent spellings of implicit parent directories. Examples include `OPS/a.xhtml` with `ops/b.xhtml`, `Straße/a` with `STRASSE/b`, and a file `Part` alongside `part/chapter.xhtml`. These must not be treated as an unambiguous namespace merely because ZIP enumeration yields distinct complete strings.

The new Foundation-only namespace validator orders canonically folded paths with an explicit component separator, checks adjacent shared ancestors, and rejects alternate spellings and file/parent collisions. It does not materialize every ancestor of a deep path or perform all-pairs scans. Existing count/path/byte budgets apply before this helper. Folding uses a fixed POSIX locale and is used ONLY for collision rejection, never for fingerprint bytes or reading identity.

Ordinary mixed-case names, Japanese resource names and diacritics remain supported when there is no actual folded collision. Case changes between two separate packages still change their revision fingerprint. Empty directory entries remain irrelevant to the frozen v1 resource hash. This is not a full EPUB conformance checker.

15 portable tests passed on Linux Swift 6.2.1 against the production helper, including a deterministic 1,000-namespace comparison against a simple all-pairs reference. Three additional native tests drive the actual scanner through real ZIPFoundation archives; the full macOS suite now contains 61 tests (previous 43 + 15 helper + 3 scanner integration). Consult the PR's exact workflow evidence for native execution; portable tests alone do not establish a scanner or migration pass.

The original caller contract still applies: acquire a coordinated immutable package view, use the same selected OPF as the reader, and revalidate the file/replica observation during enrollment. Namespace rejection must leave existing reading behavior and user data intact. No root pins, canonical Realm schema, or reader-routing activation are changed by this commit.
