# OPDS boundary coverage reconciliation, 2026-10-11

Compared all eight Sources/LakeOfFireOPDS files between retained #50 (47c3307ef93e91dd3295ab31704a5446705d43ed) and #138 (b84a433fbc4571a8519b14527405f8acb90ec29d): every production blob matches. No OPDS implementation replacement is needed.

The older OPDSTransportAndSearchBoundaryTests.swift was missing from #138. All 18 test bodies were read and carried here. They preserve cases for empty/quoted/case-insensitive MIME types, scoped XML base, literal and optional template braces, namespace/direct-child admission, malformed XML, HTTP/error/partial-body admission and version-specific/public fetchers. URLHelper, transport validation and OpenSearch parser paths were read against those cases.

The existing Package.swift LakeOfFireOPDSTests target already owns Tests/LakeOfFireOPDSTests with its Samples resource. This file belongs to that existing dedicated target, not the root ManabiReader native test list. No root target or retired harness was added.

All cases UNCOMPILED/UNRUN. Blob equality and source coverage are not compilation, discovery or runtime evidence. No builds/tests/native/CI or dependency changes. Existing OPDS test files and historical #50 evidence remain intact.
