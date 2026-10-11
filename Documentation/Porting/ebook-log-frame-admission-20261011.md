# eBook diagnostic frame admission — 2026-10-11

Compared current #138 4e219ca93d24c63b327cba8e517a3d98587ed352 against retained #50 11b71f294a530cf38352065bceb05ce10aa88aa7. The current print-message path registered an eBook frame solely because diagnostic text matched one of five markers. This bypassed the stronger initialization receipt check already ported. Carried the retained main-frame + nonnil exact current JavaScript binding check before that registration. Logging itself is unchanged.

Source-correlated missing port; no claim of runtime reproduction. No tests, builds, native execution or CI were run, and no new test pass is claimed. A future native message-handler test should deliver stale, missing-binding and subframe diagnostic messages and assert the registered viewer frame remains unchanged, then verify a current main-frame receipt can register.

The same comparison found optional opening-preparer/store wiring in #50. Prepared a surgical composition but deliberately left it unpublished pending producer ownership review: the existing modifier refreshes handler dependencies only when colorScheme changes, so blindly copying a mutable environment preparer can retain a stale closure. Core #183 e71646312b548e694dd878ffc79410f063347f4f still has URL-based restore; package/document producer selection and replacement semantics require paired review. Current main metadata/RSS/image mutation admission must be preserved; those older #50 hunks are not replacements.

Next: resolve per-reader opening producer lifetime and environment refresh before activating the optional bridge. Data-store/pool lifetime and completion-proof/cache-admission differences remain separate open ports. #50 remains open; unfinished media/transcript features remain outside hotfix scope.
