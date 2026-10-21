# Native EPUB prewarming preserves package text encoding

`EBookProcessingActor.prewarm` read package entries using unconditional UTF-8
replacement decoding. The visible section handler already uses
`ReaderPackageEntrySource.decodeText`, which recognizes UTF-8 and BOM or
byte-pattern identified UTF-16LE/BE.

A UTF-16 XHTML chapter therefore reached the background processor with NULs
and replacement-decoded text instead of the same document received by visible
processing. Background native sentence/segment catalogs and statistics cannot
be assumed to match a chapter derived from a different text input. This is a
source-confirmed input mismatch, not an observed customer incident or evidence
of a failed durable Mark/Unmark transaction.

The correction calls the existing public package decoder. It preserves raw
entry bytes for `ebookProcessDataFingerprint` and request size. Foreground
processing, package identity, cache policy and native write authority do not
change. In particular, background actor processing still does not publish into
the display-ready processed-text cache.

`testNativeSectionPrewarmDecodesUTF16PackageTextBeforeProcessing` extends the
existing `EbookURLSchemeHandlerTests` with directory-backed entries encoded as
UTF-8 and UTF-16LE/BE both with and without a BOM. The actual package source and
actor prewarm path call an injected processor which checks exact Japanese
XHTML, source URL, section href, raw-byte fingerprint and background flag.
The returned request count must match encoded bytes.

The ManabiReaderCore app also installs its own package-reading prewarmer in
`ReaderProcessingCallbackInstaller.configureReaderProcessingDependencies`.
That independent callback requires the paired correction and installer-level
regression; fixing this actor alone does not change the app callback.

The tests are authored and source-reviewed, **not executed**. No native build,
compiler or runtime test ran. The fixture does not perform morphology,
sidecar/catalog publication, Realm or WebKit work. Run the native regression
and a complete UTF-16 EPUB through both production processing paths before
claiming integrated chapter/statistics qualification.
