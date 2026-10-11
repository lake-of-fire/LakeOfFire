# Retained composition renderer repair checkpoint, 2026-10-11

Review base #50: 642250f9dee22b0460871006e803ae57151f5c12.
The fixed-layout/paginator source and relevant existing tests matched the #138 pre-repair versions. Carry the bounded fixes discovered while composing current main so this retained stack does not keep their defects:
- Explicit rejection results for fixed-layout navigation.
- Reload the old spread if replacement iframe loading has already cleared its frames.
- Explicit paginator locked/invalid-target rejection and post-await lock recheck.
- Replace a tautological native request-correlation assertion with independent second-request wire/UUID checks.

The 26-case fixed-layout suite and four new Paginator admission cases are UNRUN; the native suite is UNCOMPILED/UNRUN. No build/test/native/CI execution or pin changes occurred.

Cross-check against fresh hotfix candidate Reader #342 a86c6a8044049b5bceed9c1efcb4bdbfbebf8f15 / Lake 8f1af5b86b866b9fbfd6ca8f1dffd9e94022f569: that Lake already uses explicit owning/non-owning renderer results and stages fixed-layout spreads before visible commit. The defects repaired here were observed in the upstream compositions; do not label them reproduced shipping-hotfix regressions. The fuller current hotfix transaction implementation remains a source for further careful forward-port review, not a blind replacement of main.

Source repair provenance: #138 366e10da57bb7752a4feb0faeb7e2ab8ccf14b1d, 3f6ef77b9fe50fbe1a52ee864ca2aa649bd6eeeb, 0ce3d53b193a5d523d99d0140c49dcd5805531b6 and b84a433fbc4571a8519b14527405f8acb90ec29d.
#50 remains open for paired owned-serving/cache composition and runtime qualification.
