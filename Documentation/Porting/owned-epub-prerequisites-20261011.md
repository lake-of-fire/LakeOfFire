# Owned EPUB snapshot prerequisites — 2026-10-11 08:11 UTC

Source #50: ce8200d810d35b6ff18e0da2fe33341e5d87b73b. Destination #138: e9bf30addfbd198d5ea5bc5846f600708aa8fdef, tree6bf96abe6938eb34ec2dccdd57ec69f761c771b6.

## Reviewed API prerequisite slice
Eight source files provide coordinated private package snapshots, bounded ZIP structure validation, byte-preserving namespace rejection, frozen-v1 resource fingerprints, directory-envelope normalization, metadata-only local availability and selected-rendition admission. The graph was absent in current main. Every source file was read before carrying it over.

Snapshot references retain private copies; observation validates device/inode/size/timestamps and rejects replacement. ZIP checks reject mismatched headers/descriptors, overlapping records, unsupported representations and ambiguous Unicode override metadata before extraction. Normalized/folded names are rejection keys only; original bytes remain part of the fingerprint.

Eleven actual-module test files carry 130 regression methods. Legacy alternate harness imports are removed from the two files that had them; fixtures now unconditionally test LakeOfFireContent. No retired validation scripts, alternate packages or workflow files are added. Historical frozen vectors are preserved.

## Qualification and boundaries
ALL 130 methods are UNCOMPILED/UNRUN in this composition. No builds/tests, native snapshots, CI, dependency resolution, pins or production changes. Apple coordinated-directory behavior still requires native verification; source inspection does not prove provider semantics.

This is an API prerequisite commit, not activation or full EPUB port completion. It does not replace current default live-file serving, enroll reading state, alter schemas or redirect UI requests. Next bounded action: compose session-bound URL-scheme serving and reader initialization with current main lifetimes, then pair Common/Core bindings and schema preservation. Unfinished media/transcript is not a hotfix blocker. #50 remains open.
