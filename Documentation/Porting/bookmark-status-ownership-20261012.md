# Bookmark status ownership port, 2026-10-12

Reviewed main-stack Lake #164 at 07ad973c4b19faff0a52e55f669c1168a791163d against hotfix #165 at c9cfca63ac129c6bfab7f595b5550c1bb65874b0.

## Bounded UI repair
Main's Toggle binding awaited toggleBookmark and then directly published that transaction's Boolean into the shared cache. Overlapping work can commit a newer state while an older add still awaits follow-up work; the older result is not proof of current canonical state. Remove that completion-side override and retain the existing Realm collection observation. Guard invalidated source objects in both public cache accessors and before the Toggle task reads source-backed state.

Preserve main's LakeOfFireContentUI module, Toggle binding/style, visibility behavior and existing observation startup. Do not replace it with hotfix's different Button implementation.

## Remaining gaps
Main still separates bookmark removal and addition, has older add/fallback/history mutation logic, and lacks the full storage/physical-row admission carried by hotfix #165. This UI port does not make toggle atomic, protect every awaited model access, or fix cache replacement across accounts/storage. Those require an independent model/observation port and owning native tests.

## Validation
Full current main UI source and relevant model paths were inspected alongside #165. Source inspection only; no new executable tests in this UI-only change. Native compilation, invalidated-object UI coverage, overlapping add/remove completion ordering and observation publication are UNRUN. Hotfix's reported 73-test batch is evidence for its composed hotfix snapshots, not this main patch.

Next bounded action: port the model's single-transaction add/remove decision while preserving main's separate modules, content metadata and inline HTML analysis enqueue. Test two queued toggles, cancellation, deleted/recreated source and history rows, and a delayed older add completion after removal. Do not advance root dependency pins on the basis of this UI repair.
