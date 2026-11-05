#!/usr/bin/env bash
# Execute complete production value/bridge implementations under their real
# module names. No fake Realm/WebKit implementation is linked into this probe.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/LakeOfFireContent" "$work/Sources/LakeOfFireReader" \
  "$work/Sources/FixtureExport" "$work/Tests/NativeRestoreTests"
cp "$root/Tools/NativeRestoreTests/Package.swift" "$work/Package.swift"
cp "$root/Sources/LakeOfFireContent/Files/ReaderEBookInitialRestorePolicy.swift" "$work/Sources/LakeOfFireContent/"
cp "$root/Sources/LakeOfFireContent/Reader/ReaderContentEbookInitialRestore.swift" "$work/Sources/LakeOfFireContent/"
cp "$root/Sources/LakeOfFireReader/Reader/ReaderEBookInitialRestoreBridgeRequest.swift" "$work/Sources/LakeOfFireReader/"
cp "$root/Tools/NativeRestoreTests/FixtureExportAdapter.swift" "$work/Sources/LakeOfFireReader/"
cp "$root/Tools/NativeRestoreTests/FixtureExport/main.swift" "$work/Sources/FixtureExport/"
for file in ReaderEBookInitialRestorePolicyTests ReaderEBookNativeRestoreRegressionTests ReaderEBookNativeRestoreAdmissionTests ReaderEBookNativeRestorePreparationTests ReaderEBookNativeRestoreWebKitTests; do
  cp "$root/Tests/LakeOfFireTests/$file.swift" "$work/Tests/NativeRestoreTests/"
done
if [[ "${NATIVE_RESTORE_SWIFT6:-0}" == 1 ]]; then
  python3 - "$work/Package.swift" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); text=p.read_text()
text=text.replace('// swift-tools-version: 5.10', '// swift-tools-version: 6.0')
text=text.replace('    ]\n)', '    ],\n    swiftLanguageModes: [.v6]\n)')
p.write_text(text)
PY
fi
swift test --package-path "$work" "$@"
swift run --package-path "$work" "$@" export-native-restore-fixtures > "$work/native-restore-wire.json"
if [[ -n "${NATIVE_RESTORE_FIXTURES:-}" ]]; then
  cp "$work/native-restore-wire.json" "$NATIVE_RESTORE_FIXTURES"
fi
NATIVE_RESTORE_WIRE_FIXTURES="$work/native-restore-wire.json" node --test "$root/Tools/NativeRestoreTests/native-wire.test.mjs"
