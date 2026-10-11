# Delete-confirmation command forward port

## October 11, 06:31 UTC exact-source checkpoint

Source: hotfix #135 `4f4620e46c0575af59cc8738727c97909983fe24`.
Destination: upstream #138 `8b9d76145c9d4274bfb4447a8dc6b66b77fe5208`.

The destination had copied aligned list snapshots but still launched an unfenced delete-alert task. Its success cleared whatever dialog was current; its failure replaced whatever dialog was current. An intervening same-item or different-item confirmation could therefore be lost.

Port the hotfix command seam and UUID presentation generation into main's LakeOfFireContentUI owner. Capture the generation in the alert builder before launching the confirmed task. Only presentation completion/error is fenced: an already-confirmed deletion still runs even if another dialog replaces it. New explicit requests, errors and clears rotate the generation. Keep the existing alert Binding getter/setter unchanged so SwiftUI dismissal alone does not rotate it or hide a confirmed command error. Keep main's preconcurrency conformance, module split, deletion preflight and all unrelated list/selection/preview code.

Nine command regressions are adapted from the hotfix into ReaderContentListDeleteCommandTests.swift, importing LakeOfFireContent and LakeOfFireContentUI. They cover cancellation without deletion, one successful command, retained errors, same/different-item successor success/error, binding dismissal and replacement before task entry. The existing two list-snapshot tests remain unchanged. No new package target is needed: LakeOfFireTests already depends on both actual modules and includes this directory.

Tests and builds were NOT RUN by request. This is an authored source port, not an observed failure reproduction or native qualification. The separate filesystem EPUB deletion behavior and its three real-filesystem tests are not claimed by this command-presentation change. Current-head compilation, real alert lifecycle and assembled app qualification remain open. No UI tests, dependency pins, schema, retired validation, production or deployment changes.
