# History recovery retirement within a chapter

A completed Mark/Unmark can retain a separate History reading-status recovery.
Native admission stops its status poll. A refused preparation or failed query
retains its failure notice without automatically retrying.

The Book state controller retires this recovery on physical movement, including
movement within a chapter. It must also invalidate the old projection at that
point. Reader connects projection invalidation to the request coordinator's
cleanup; completed recoveries are absent from its pending-command map, so a
stopped timer cannot discover the departure later.

Capture whether the transition withdraws a projection before retiring recovery:
a changed chapter/end page, a replaced document, or an existing History recovery.
Clear the old state and notify invalidation using that captured decision. Keep
the existing ownership check after callbacks so a nested replacement read retains
its slot and an old reply cannot consume it.

Ordinary movement within a chapter preserves accepted cached state. Successfully
acknowledged recovery no longer counts as active recovery. Unchanged locations
remain no-ops and do not retry failures. Retirement never replays Mark/Unmark or
sends Cancel for a completed command, and it preserves the native outcome.

Behavior coverage lives in `Tests/JavaScript/native-mark-read-retired-recovery.test.mjs`
and `Tests/Browser/BookRuntimeBoundaries`. The browser fixture composes production
Book runtime, state controller, recovery adapter and request coordinator with an
actual iframe. Native transport and paginator movement are controlled; the
fixture does not execute the full Viewer or native writer. It holds the next
native sample to distinguish immediate cleanup from eventual successful refresh.

Run the JavaScript recovery cases with:

```sh
node --test --test-concurrency=1 \
  Tests/JavaScript/native-mark-read-retired-recovery.test.mjs \
  Tests/JavaScript/native-mark-read-cancel-recovery-integration.test.mjs \
  Tests/JavaScript/ebook-visible-mark-read-commit.test.mjs
```

Run the maintained browser runner with a fresh `--output` path. Keep execution
results outside tracked source.
