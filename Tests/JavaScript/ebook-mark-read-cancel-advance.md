# Cancel may lose the commit race without retaining automatic navigation

The native EPUB page Mark transport waits for authenticated native completion
after Cancel. The writer may already have committed, so a successful terminal
reply must remain successful and its full chapter reading state must still be
displayed.

The pending notice lives in the EPUB shell. Its Cancel button does not dispatch
a trusted input event to the chapter iframe, whose navigation receipt guards the
automatic page turn. Previously the coordinator discarded its `cancelling`
state when returning the successful terminal outcome. Reader therefore refreshed
the saved state and scheduled the original automatic turn after Cancel.

Terminal outcomes now retain factual `cancellationRequested` metadata. This is
independent of success and presentation permission. Reader still requests the
full native chapter state, while declining optional automatic advancement for
the cancelled intent. The metadata is sampled when the original pending request
is consumed; no current or replacement request is consulted.

The production coordinator tests verify both cancelled and untouched success
outcomes. The complete shipping Reader harness separately drives Cancel, native
commit, full publication and the animation clock. Saved read membership and
committed diagnostics must agree in both cases; only the untouched action turns.
These are controlled JavaScript behaviors, not native writer or WebKit tests.

