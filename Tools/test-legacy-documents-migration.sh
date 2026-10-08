#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Legacy document migration requires Apple file coordination and exclusive rename; no tests ran.' >&2
  exit 1
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
evidence="${LEGACY_DOCUMENTS_EVIDENCE_DIRECTORY:?Set a fresh absolute evidence directory}"
[[ "$evidence" = /* ]] || { echo 'Evidence directory must be absolute' >&2; exit 1; }
mkdir -p "$evidence"
git -C "$root" rev-parse HEAD > "$evidence/tested-commit.txt"
git -C "$root" ls-tree -r HEAD > "$evidence/source-manifest.txt"
swift --version > "$evidence/toolchain.txt"
work="$(mktemp -d)"
finish() {
  local status=$?
  if [[ -n "${LEGACY_DOCUMENTS_EVIDENCE_DIRECTORY:-}" ]]; then
    mkdir -p "$LEGACY_DOCUMENTS_EVIDENCE_DIRECTORY" || status=1
    tar -czf "$LEGACY_DOCUMENTS_EVIDENCE_DIRECTORY/executed-source.tar.gz" -C "$work" Package.swift Sources Tests || status=1
  fi
  rm -rf "$work" || status=1
  exit "$status"
}
trap finish EXIT
mkdir -p "$work/Sources/LakeOfFireContent" "$work/Tests/LegacyDocumentsTests"
cp "$root/Tools/LegacyDocumentsTests/Package.swift" "$work/Package.swift"
cp "$root/Sources/LakeOfFireContent/Files/ReaderLegacyDocumentsMigration.swift" "$work/Sources/LakeOfFireContent/"
cp "$root/Tests/LakeOfFireTests/ReaderLegacyDocumentsMigrationTests.swift" "$work/Tests/LegacyDocumentsTests/"
set +e
swift test --package-path "$work" -Xswiftc -warnings-as-errors \
  --parallel --num-workers 1 --disable-swift-testing \
  --xunit-output "$evidence/native.junit.xml" "$@" 2>&1 | tee "$evidence/test.log"
statuses=("${PIPESTATUS[@]}")
set -e
printf '%s\n' "${statuses[*]}" > "$evidence/test-pipeline-statuses.txt"
if [[ "${statuses[0]}" != 0 || "${statuses[1]}" != 0 ]]; then exit 1; fi
python3 - "$work/Tests/LegacyDocumentsTests/ReaderLegacyDocumentsMigrationTests.swift" "$evidence/native.junit.xml" "$evidence/method-roster.txt" <<'PY'
from collections import Counter
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

expected = re.findall(r'^\s*func\s+(test\w+)\s*\(', Path(sys.argv[1]).read_text(), re.M)
Path(sys.argv[3]).write_text('\n'.join(sorted(expected)) + '\n')
cases = list(ET.parse(sys.argv[2]).iter('testcase'))
def method(case):
    return case.attrib.get('name', '').removesuffix('()').rsplit('/', 1)[-1].rsplit('.', 1)[-1]
counts = Counter(method(case) for case in cases)
assert expected and len(expected) == len(set(expected)), 'Missing or duplicate source test methods'
assert set(counts) == set(expected) and all(count == 1 for count in counts.values()), (expected, counts)
assert not any(case.find(tag) is not None for case in cases for tag in ('failure', 'error', 'skipped')), 'Native suite failed or skipped methods'
print(f'Passed all {len(expected)} filesystem migration methods without skips')
PY
