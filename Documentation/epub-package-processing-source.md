# Keep the opened EPUB source through native processing

The visible EPUB handler already captures a document's immutable serving
lease. Its processor and cache-reader callbacks now receive that same source
through `EbookPackageProcessingContext.source`.

`EbookPackageProcessingSource` bundles the existing lease with the original
reader registration validator. Its MainActor validation checks both. A lease
can remain valid for another owner after this reader replaces its
registration; lease validity alone cannot authorize publication into that
replacement reader. The section producer explicitly retains the captured
source across its task handoff. The scope also surrounds cache hits so native
metadata restored from cached payloads has the same provenance.

This is transient processing context, not a new persistent identity or reading
permission. Legacy callers without session-bound serving retain a nil source.
The paired Core change uses the existing lease for native spine and chapter
warming, qualifies compact catalogs by the package revision and selected
rendition, and validates the local warmer binding before publishing statistics.

`EbookServingHandlerTests.testProcessedSectionCarriesItsOriginalSnapshotThroughCacheAndProcessor`
uses the existing real snapshot/lease and WKURLSchemeHandler fixture. Its
cache-reader and processor callbacks check the original lease and run the
actual bundled admission. The handler must complete normally.

The test is **authored and source-reviewed, not executed**. No build,
compiler invocation, WebKit run or device qualification is claimed. Core's
separate native fixtures cover provider-file changes, same-URL rebinding and
revision-qualified catalog behavior. Complete multi-reader and real package
processing acceptance remains an Apple-host integration check.
