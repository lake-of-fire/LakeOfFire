# Raw process-text lease fence — 2026-10-11

At retained #50 47c3307ef93e91dd3295ab31704a5446705d43ed, the no-processor /process-text response called finishActiveTask without its captured package read. A lease withdrawn between receipt and final publication could therefore allow this raw response through. Added the same final required-access validation used by the other package response paths.

Added two behavioral real-handler regression sources: withdrawal before raw response completion, and registration replacement rejecting the captured request while another owner of the same store remains valid. Six retained handler cases are preserved, eight total. This is source-correlated review, not an executed reproduction. All Swift UNCOMPILED and tests UNRUN; no builds, native launches, generation, CI or pins.

The same fix is included in newer composition #138 ada3d27fbdc3bb954c1b294fb438a44ebd993618. This bounded repair preserves #50's paired completion-proof/cache architecture. #50 remains open for the still-uncomposed integration work.
