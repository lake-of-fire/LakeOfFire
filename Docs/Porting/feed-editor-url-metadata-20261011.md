# Feed editor URL-specific refresh metadata

Reviewed 2026-10-11 against Lake #162 `5e359d88d429693868f9d5fae9fb9b36839a74df`.

The existing editor commits buffered and pasted RSS URL edits through LibraryFeedFieldCommand. Both preserved the previous URL's ETag, Last-Modified and last-refreshed timestamp. Feed.fetch captures those values with the current RSS URL, so URL replacement could reuse validators for another resource and preserve an inappropriate freshness timestamp.

The fix invalidates all three values inside the existing owned transaction, after the admitted command actually changes the URL and before change tracking. It does not clear metadata for unchanged URLs, rejected/obsolete commands or unrelated edits. It preserves captured Realm/record/category identity and field-intent ordering and adds no schema or new write owner.

Four regression methods cover buffered/pasted replacement, unchanged URLs, non-editable category rejection and a suspended obsolete URL writer overtaken by a newer no-op URL intent. These sources are UNCOMPILED/UNRUN. Existing request-generation/URL fencing from #151 continues to guard old in-flight refresh completion; this patch adds no new network tests.

Scope is editor commands only. Imports, OPML and sync-driven URL replacement remain to be audited and are not declared solved. Existing metadata on a URL that was already changed before this patch cannot be retroactively attributed or cleared without an additional policy. The sibling #160 ETag-precedence fix is still separate and must be composed for qualification.

No native execution, CI dispatch, dependency pins, schema, deployment or production change.

## OPML follow-through

A subsequent source trace found the same URL mutation in LibraryDataManager.applyAttributes, reached by importOPMLEntry for an existing feed UUID. The follow-up clears the three resource-specific fields alongside that URL assignment. Two real OPML-import regression sources cover changed and unchanged URLs (including an unrelated title edit). All six added regression methods across the editor and import lanes remain UNCOMPILED/UNRUN. This supersedes the earlier editor-only scope for OPML imports; sync-driven mutation and pre-existing stale values remain unresolved. No import ownership, category matching or schema semantics were changed.
