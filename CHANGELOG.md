# Changelog

All notable changes to this project are documented here.

## Unreleased

- Added automatic cleanup for unfinished, unimportant reminders that are
  confirmed absent from both the TaskForge snapshot and durable Vault source.
- Added protection for completed reminders, EventKit priority and six leading
  important-title markers.
- Added an unchanged two-scan confirmation window of at least 60 seconds,
  private candidate persistence and fail-closed source resolution.
- Added checksummed `0600` pre-deletion backups and
  `--restore-last-prune` with a minimum 24-hour restoration grace period.
- Restore selection skips unresolved, zero-deletion and already restored
  backups, choosing the newest remaining real deletion batch.
- Added strict read-only `--prune-dry-run` and one-pass `--prune-once`
  commands; `--sync` and `--watch` now advance the same pruning state machine
  after reverse and forward synchronization.
- Scoped pruning fetches to exactly one configured reminders list, rejecting
  same-name ambiguity and leaving all other lists untouched.
- Added a 30-second EventKit fetch timeout with request cancellation and
  anonymous, salted pruning logs.
- Preserved the existing TaskForge boundary: reverse completion only marks
  source tasks `done`; pruning never deletes TaskForge task lines or files.

## 1.1.0 - 2026-07-29

- Added TaskForge-to-Reminders updates for linked title, date, time and status
  changes.
- Added source-identity fallback matching when TaskForge re-indexing changes a
  task ID.
- Added ambiguity protection so duplicate IDs or source locations never create
  another reminder.
- Added a privacy-preserving `--audit` command for duplicate checks across the
  complete managed reminder history.
- Distinguished active duplicates and same-occurrence duplicates from normal
  completed history that reused a source line on another scheduled day.
- Added dry-run and reversible deduplication maintenance: current exact
  reminders win, while redundant active reminders move to a separate archive
  list instead of being deleted.
- Classified conservative reverse-write refusals as unattended skips instead
  of repeating them as synchronization failures.
- Changed LaunchAgent startup to use LaunchServices so background EventKit
  access retains the authorized app bundle identity.
- Added an optional stable code-signing identity setting while keeping keychain
  and TCC changes explicitly outside the build script.
- Expanded core regression coverage and public deduplication documentation.

## 1.0.0 - 2026-07-27

- Added TaskForge MessagePack v6 decoding.
- Added today's open-task synchronization to Apple Reminders.
- Added near-real-time EventKit and TaskForge cache watching.
- Added historical Apple Reminders completion scanning.
- Added durable task-source references for cache-evicted tasks.
- Added guarded Markdown and TaskNotes reverse completion.
- Added pre-write backups, SHA-256 receipts and TaskForge readback checks.
- Added LaunchAgent install/uninstall scripts and scheduled fallbacks.
- Added automated core tests and GitHub Actions CI.
