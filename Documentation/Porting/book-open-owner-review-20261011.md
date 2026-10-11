# Book open owner review — 2026-10-11

Reviewed #50 head 7ba92a8cc3cdd9bc481931fb214856fc751394fe while reconciling its remaining upstream ports.

## Source-confirmed defects
1. start calls onStart synchronously before installing its task handle. A reentrant replacement/cancellation can change the generation during that callback, after which the obsolete outer invocation overwrites the replacement task handle. Added post-callback admission before creating/installing the producer.
2. The weak capture was immediately promoted to strong self across the operation's suspension. This prevents coordinator deinitialization from cancelling an operation whose external owner has been released. Keep self weak across await and perform generation-scoped cleanup in defer; cancellation of the current task no longer prevents clearing its completed handle.

## Regression source
Three new actual coordinator tests cover reentrant replacement handle cancellation, cancellation inside onStart, and release of an owner while an uncooperative operation is suspended. Existing nine cases retained: twelve total, ALL UNRUN.

These are source-review findings, not an executed failure claim. No builds/tests or native processes launched. The coordinator and the current book-open call sites still require behavioral integration into #138 with its newer navigation/content ownership APIs. This repair does not establish #50 supersession or hotfix qualification.
