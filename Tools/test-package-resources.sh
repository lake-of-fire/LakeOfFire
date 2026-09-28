#!/usr/bin/env bash
# Real production package-reader and EPUB parser, excluding app/file-manager cache.
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'These I/O tests require the Apple CryptoKit/UTType implementation; not executed.' >&2
  exit 1
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
finish() {
  local status=$?
  if [[ -n "${PACKAGE_RESOURCE_EVIDENCE_DIRECTORY:-}" ]]; then
    mkdir -p "$PACKAGE_RESOURCE_EVIDENCE_DIRECTORY" || status=1
    cp "$work/Package.swift" "$PACKAGE_RESOURCE_EVIDENCE_DIRECTORY/test-Package.swift" || status=1
    if [[ -f "$work/Package.resolved" ]]; then
      cp "$work/Package.resolved" "$PACKAGE_RESOURCE_EVIDENCE_DIRECTORY/Package.resolved" || status=1
    fi
    tar -czf "$PACKAGE_RESOURCE_EVIDENCE_DIRECTORY/executed-source.tar.gz" -C "$work" Sources Tests || status=1
  fi
  rm -rf "$work" || status=1
  exit "$status"
}
trap finish EXIT
mkdir -p "$work/Sources/LakeOfFireContent" "$work/Sources/LakeOfFireReader" "$work/Tests/PackageResourceTests"
cp "$root/Tools/PackageResourceTests/Package.swift" "$work/Package.swift"
# The reader declaration is unmodified. The following app cache requires the
# full ReaderFileManager graph; two corresponding tests remain full-host only.
awk '/^public actor ReaderPackageEntrySourceCache/ { exit } !/^import LakeOfFire(Core|Adblock)$/ { print }' \
  "$root/Sources/LakeOfFireContent/Files/Archive+Data.swift" > "$work/Sources/LakeOfFireContent/ReaderPackageEntrySource.swift"
cp "$root/Sources/LakeOfFireContent/Files/ReaderPackageResourceLimits.swift" "$work/Sources/LakeOfFireContent/"
cp "$root/Sources/LakeOfFireReader/Reader/Books/EPubParser.swift" "$work/Sources/LakeOfFireReader/"
# Select the 22 existing I/O cases unchanged; leave the two app-cache cases in
# their original full-host suite instead of compiling them against a test double.
python3 - "$root" "$work" <<'PYEXTRACT'
from pathlib import Path
import sys
root, work = map(Path, sys.argv[1:])
text = (root / "Tests/LakeOfFireTests/ReaderPackageEntrySourceTests.swift").read_text()
start = "    func testPackageEntrySourceCacheEvictsLeastRecentlyUsedSources()"
end = "    func testArchiveEnumerationRejectsUnsafeEntryPaths()"
assert text.count(start) == 1 and text.count(end) == 1
before, tail = text.split(start)
excluded, after = tail.split(end)
assert excluded.count("    func test") == 1
(work / "Tests/PackageResourceTests/ReaderPackageEntrySourceTests.swift").write_text(before + end + after)
PYEXTRACT
for suite in ReaderPackageResourceBudget ReaderPackageResourceLimit EPubMetadataResourceLimit; do
  cp "$root/Tests/LakeOfFireTests/${suite}Tests.swift" "$work/Tests/PackageResourceTests/"
done
swift test --package-path "$work" "$@"
