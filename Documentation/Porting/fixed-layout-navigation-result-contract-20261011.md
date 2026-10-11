# Fixed-layout navigation result contract, 2026-10-11

Reviewed #138 at 5031ca92452919dd39c8149045defeed7cfc8d16 after the View ownership port. Both fixed-layout.js (blob 5bf10a374852215fdac904f467150435e84e9122) and paginator.js (3754c281f288a9d73fe1434f6b77ce14033490e7) were byte-identical to #50 at 642250f9dee22b0460871006e803ae57151f5c12. Equality did not imply a correct result contract.

## Source-confirmed defect
FixedLayout.goTo/goToSpread returned undefined for destroyed, invalid, missing-spread and superseded work as well as successful work. The required-restore adapter intentionally accepts void for legacy successful renderers. Consequently a silently rejected fixed-layout command could be treated as applied by a caller that only checked promise fulfillment.

## Bounded repair
Rejected/superseded fixed-layout navigation now returns null. Displayed navigation returns true and goTo/select forward the result. Invalid section/spread indices are explicitly rejected. Existing generation checks, frame cancellation, display ordering, exception propagation and rendering remain intact.

The real FixedLayout behavioral suite now asserts replacement success and obsolete completion rejection, delayed-target rejection, invalid/destroyed required-restore rejection, successful frame display and already-displayed success. Two new cases, plus strengthened existing cases; all UNRUN. No native launch, build, test or CI dispatch occurred. This is source corroboration, not a runtime reproduction.

## Remaining
Paginator.goTo also silently returns void while locked or when an index is rejected; this requires a separate bounded repair and behavioral coverage. Renderer cancellation during actual pagination remains a separate review. This patch does not establish full renderer parity or supersede #50, which retains other owned-serving/cache work. Upstream only; no unfinished media feature activation.
