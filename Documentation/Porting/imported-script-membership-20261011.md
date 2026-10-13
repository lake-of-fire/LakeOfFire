# Imported user-script membership — 2026-10-11

Source review at Lake #138 `c7bd8208e351fa9680a02354cd170f659cc78b04` found importOPML used `!userScriptIDs.contains(where: { $0 != script.id })` to decide whether to add a script. Once an unrelated reference existed, the predicate prevented insertion of a new script even though its row had been imported. With only a matching reference it instead admitted an unnecessary duplicate that the later cleanup removed.

Changed the membership test to `!userScriptIDs.contains(script.id)`, matching the neighboring category-membership implementation. Existing ordering, captured Realm, current Set optimization for category order, deletion, script settings and journal calls remain untouched.

Added a real-import regression to LibraryCapturedMutationPortTests. It seeds one user script in an isolated Realm, imports two additional scripts from a temporary OPML file, verifies all three ordered references and rows before any second consolidation, then repeats the import and checks stable membership/count. It does not substitute a helper predicate for the production importer. The owning file now has three methods, all UNCOMPILED/UNRUN. Existing duplicate-feed selection regression also remains unrun.

Root registration requires adding this file and its LakeOfFireLibrary module dependency to Reader #384's explicit Tuist test list; package inclusion alone is insufficient. No project generation, build, tests, native launch, CI, pins, merge, deployment or production changes.

Further script-setting semantics, including archived-state import, are outside this focused membership correction and remain for independent review.
