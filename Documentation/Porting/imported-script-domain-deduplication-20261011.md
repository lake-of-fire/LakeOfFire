# Imported script domain deduplication — 2026-10-11

At Lake #138 `40223adf5c66321b3bec27c908b0183e5b34e11d`, applyScriptDomains snapshots existing domain names once before iterating imported names. A repeated new name is absent from that frozen snapshot every time, so the import creates several domain objects/references. The change detector compares sets, which can then consider the duplicated state unchanged on later imports.

Use a mutable Set initialized from existing live domain names and insert each decoded imported name into that set before creating a new row. This retains first occurrence order, avoids repeated new rows, and changes membership lookup from repeated linear scans to set lookup. Existing domain retirement/revival and journal ownership are preserved; no broad cleanup or deletion of historical duplicate rows is introduced.

The real OPML import/reimport fixture now includes repeated plain and percent-encoded spellings of example.org and asserts one domain row/reference after each import. Suite count remains four. All source remains UNCOMPILED/UNRUN, with no build, test, CI, native launch, pins, merge, closure or deployment. Reader #384 registration/count remains unchanged.
