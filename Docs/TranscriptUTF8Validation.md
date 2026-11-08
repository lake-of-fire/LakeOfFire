# Reject malformed UTF-8 in transcript strings

Base main a6d6f82b3156b7faaeeb59dce2ae1eb3021cfdf3.
Donor Lake #113, head 367775198f6b402cb5708896a44469abf788ccd3.

MediaTranscript.decodeWebVTT previously used String(decoding:as:), repairing
invalid UTF-8 with replacement characters. A successfully decompressed but
malformed stored transcript could therefore become nonempty display text.
Core main ReaderWebMediaCoordinator.existingTranscript calls webVTTString and
checks only that the returned string is nonempty before reuse.

Use failable UTF-8 decoding and throw the existing invalidFrame error, matching
the donor's codec boundary. Preserve valid Unicode, including an actual encoded
U+FFFD, and retain byte-level encode/decode APIs unchanged. No parser/header/cue
validation, Realm schema, generator-version, cache cleanup, or retry behavior
changes. Malformed stored bytes now fail instead of being silently repaired;
they remain stored, with current caller error handling and no promised recovery.

Fresh #113 and #533 heads and bounded transcript encoding/UTF-8 searches checked.
#533 explicitly excludes encoding validation; this change is a disjoint method
and should compose with its allocation bound. It does not include that bound.
No other dedicated open port was found; unpublished ownership is not exhaustively
knowable from this search.

Three authored production-codec XCTest methods cover invalid leading/truncated/
overlong/surrogate/out-of-range sequences, malformed bytes in a nonempty transcript,
and valid Unicode/empty strings/BOM/literal replacement-character preservation.
Raw Data round trips establish that the rejection belongs to string decoding,
not compression or byte-level validation.

All Swift parsing, typechecking, compilation and tests are UNRUN. Existing
LakeOfFireTests package target discovers the file and depends on LakeOfFireContent.
Generated Xcode membership and mounted application behavior remain unqualified.
No pins, builds, CI dispatch, deployment, production or denied-operation retries.
