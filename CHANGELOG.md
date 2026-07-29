# Changelog

All notable changes to this project are documented here.

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
