# Retained hotfix import/MIME regression coverage

Lake #50 already contains the runtime behavior from hotfix-side #55 and #56 in main-native form:

- import storage derives source kind from filesystem type, rejects non-file/non-directory sources, compares directories with the recursive manifest, treats symlink destinations as occupied/different, checks both directory and file occupancy, and never equates file and directory entries;
- reader-file package responses already use ReaderPackageEntrySource MIME metadata and text encoding instead of synthesizing image/<extension>.

The main integration already had substantial coverage for directory manifests, identical directory reuse, file→directory mismatch, dangling destination links, source-link rejection, deterministic EPUB/XML/SVG metadata and unknown binary fallback.

This qualification increment retains three exact hotfix regression edges that were still missing:
1. an occupied **non-dangling** destination symlink whose target bytes match the source must not be reused;
2. a directory source must not reuse an occupied regular file with the same basename;
3. JPG/JPEG/PNG/WebP metadata must resolve to canonical MIME values through the same source API used by ReaderFileURLSchemeHandler.

No production file changes. The targeted workflow runs the real import-storage native fixture in Debug and Release and the real package-source MIME test in Debug and Release on macOS/Swift 6.2.1.
