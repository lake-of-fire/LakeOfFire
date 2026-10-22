# Full native coverage withdrawal consumes optional page advancement

The optional Mark continuation introduced by LakeOfFire #213 waits for the
animation and a successful full chapter publication. A current full publication
can also prove that a later reading change withdrew one of the original Mark's
subjects. That is a terminal decision for the old optional turn, even if its
animation has not finished.

Previously the continuation returned false for missing coverage but remained
installed. An independent later reading action could restore the subject in
the same chapter pass. Its full publication then replayed the older page turn.
The original Mark still had durable success; it had lost permission to move the
viewport after native coverage withdrawal.

Reader now consumes that continuation when a successful current full
publication at or after the Mark's sequence lacks a requested stable segment.
It uses the existing original owner, navigation and pending-intent guards, and
checks that the controller's full projection matches the successfully rendered
publication. The decision runs before the animation-ready check, including immediately
after continuation registration when a full sample beat the native reply.
Early withdrawal cannot be hidden by a later restored sample.

A partial receipt is different evidence. Core may advance the shell's native
ordering watermark without replacing its cached full chapter projection.
Noting that full projection's own revision must still succeed before its
missing membership can prove withdrawal. This check cannot lower the watermark
or issue another query. It preserves waiting when full evidence is stale or
not yet available, and composes with #221's separate final advancement gate.

The complete production Reader harness tests withdrawal before and after the
430 ms animation boundary and before continuation registration, followed by
restored coverage and no movement. Two
controls overtake cached full state with a partial receipt and require the
later current full publication to remain eligible to advance. Existing tests
retain late publication, native success, navigation and lifecycle behavior.
Controlled JavaScript state and renderer collaborators do not establish native
writer or actual WebKit execution.
