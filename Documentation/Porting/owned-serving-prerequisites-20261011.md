# Owned eBook serving prerequisites — 2026-10-11

Prepared against Lake #138 34974fb6de751a6b5b67ae4ac32aec7e0bae9995, carrying focused source from retained #50 47c3307ef93e91dd3295ab31704a5446705d43ed.

## Prepared contracts, not runtime activation

Carried ReaderEBookServingSession.swift and EbookPackageSessionEnvironment.swift. They define the immutable fingerprint-backed package, revocable per-document lease, bounded per-reader store, replacement-fenced registration, and optional opening environment contract. No handler or Core invocation is changed in this step: existing initialization still uses no-op preparation and no package session argument. The new types alone do not enroll or mutate reading history.

The package source/fingerprint/snapshot/rendition and resource-limit dependency surfaces were reviewed; the ten ReaderEBook/ReaderPackage file implementations already match #50 exactly. ReaderPackageEntrySource is a Sendable value that reopens a verified archive for each read, not a shared mutable Archive handle. Strict fingerprint resources are compared using literal UTF-8 bytes, and each served entry must match its captured size and SHA-256. Snapshot ownership survives original-file removal but changed private snapshot bytes are rejected. Installing a session permanently disables implicit legacy fallback for that store. Withdrawing a foreign lease does not affect its owner; replacing one registration does not close another reader's shared store.

## Retained behavioral evidence

- ReaderEBookServingSessionTests: 19 methods covering exact resources, source revision separation, unchanged content observation, capability/source/generation rejection, capacity, revocation, source removal, literal paths, changed snapshots, lifetime, cancellation and registration replacement.
- ReaderEBookPortCompositionTests: 6 methods exercising strict fingerprint/snapshot/bounded read composition, larger admitted resources and literal path budgets without weakening strict admission.

These are source counts, not results. All Swift UNCOMPILED, all tests UNRUN; no build, test, native launch, generation, CI, deployment or dependency pin change. The composition tests generate synthetic ZIP files and can allocate large bounded fixtures when eventually run; no user library is opened.

## Integration still open

Wire the current main EbookURLSchemeHandler and per-reader modifier to captured serving access; carry the matching JavaScript loader and request capability contract; then trace/adapt Core's opening lifetime and cache identity hook before activating the environment. Every suspended handler/cache result needs final access validation, and malformed or revoked capabilities must not fall back to the original file. This prerequisite does not establish end-to-end parity or justify closing #50. Reader's Tuist source list must include both suites for later qualification.
