# Porting work: Article read-authority epoch pointer

Lake main owns the persisted `ArticleReadingProgress` model. v3-hotfix Common uses `readAuthorityEpochID` to fence delayed Mark/Undo/position/lifecycle work across Clear, Start Over and Reopen, but Lake main had removed the field while Common main retained it only as migration evidence.

This port restores the field as passive storage. Lake does not interpret or rotate it; Common remains the authority owner. Nil is the legacy/unversioned lifetime.

The paired Common schema port must advance beyond schema 322 and restore any epoch value previously quarantined in `LegacyReaderSchemaFieldRecord`. Do not select this Lake change without that Common migration.
