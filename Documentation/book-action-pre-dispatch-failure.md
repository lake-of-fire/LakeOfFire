# Book action failures before native dispatch

A fresh Book action reserves its immutable semantic request before preparing its
timer and native producer envelope. If preparation fails before entering the
transport callback, native has never received the operation. Keeping it as an
unknown outcome would strand Endcap and Book Actions on Check Status.

The bridge records whether transport entry occurred. Its shared failure handler
releases the exact fresh reservation on producer refusal, envelope/serialization
failure or early timer expiry before entry. It withdraws ownership before timer
cleanup can synchronously admit a successor. A new user action can then proceed.

A failure or timeout after transport entry preserves the original operation for
status recovery. Preparation failure for status or navigation recovery likewise
preserves that already-submitted command. A synchronous terminal acknowledgement
wins over a later wrapper error. Recovery never replays the reset mutation.

Maintained behavior owners:

- `book-action-bridge-settlement.test.mjs`: exact failure boundaries, early timer
  expiry, successor ownership and posted-operation recovery.
- `book-action-pre-dispatch.test.mjs`: producer and semantic-envelope admission.
- `book-action-recovery.test.mjs`: recovery of the original operation.
- `book-endcap-bridge-dispatch.test.mjs`: complete Endcap, bridge and producer
  adapter composition, visible controls and exact packet sequence.

These component tests control native replies, timers and DOM allocation. Real
WebKit activation, Realm/account transitions and device acceptance remain separate
checks. Store execution logs outside tracked source.
