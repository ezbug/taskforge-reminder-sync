# Architecture

## Components

### TaskForgeReminderCore

Core is pure Foundation policy and private persistence. It is responsible for:

- strict decoding of TaskForge v6 records, including the live scalar tombstone;
- decoding `flutter.ctl_<listID>` from the TaskForge preferences plist;
- validating known fields/operators and evaluating nested `all`/`any` filter groups;
- canonicalizing TaskForge statuses and learning the four approved Markdown symbols;
- editing Markdown/TaskNotes source content only after identity and original-line checks;
- storing the private Kanban configuration/index with `0700`/`0600` verification;
- the existing pruning, backup, restore and source-presence policies.

Unknown filter schema, malformed private state and unknown status symbols are errors, not empty
matches. This keeps an incomplete TaskForge reverse-engineering result from becoming a broad
destructive query.

### TaskForgeReminderSync

The executable owns `EKEventStore`, calendar/list creation, forward and reverse reconciliation,
source backups, TaskForge readback verification, and the near-real-time watcher. Its custom
source path never writes `tasks.v6.bin`; it writes only the Vault source file and lets TaskForge
re-index it.

The old scheduled-day engine remains behind `--source scheduled-day` for compatibility. It is
not used by the default custom-list path.

### LaunchAgent

The supervisor starts the signed App bundle so the background process has the same Reminders TCC
identity as a manually launched App. It restarts the watcher if it exits. The watcher:

1. reconciles once at startup;
2. debounces `EKEventStoreChanged` for 750 ms;
3. checks the task store and preferences plist every second;
4. performs a full pass every 60 seconds;
5. performs extra passes at 07:00, 11:00 and 15:00.

Each pass is serialized. Its order is reverse conflict resolution, forward status reconciliation,
then the protected two-scan cleanup. A TaskForge source change is re-read before the forward
phase when reverse writing occurred in the same pass.

## Custom-list forward flow

1. Read `tasks.v6.bin`; a truncated or unknown record fails the pass closed.
2. Read the fixed private list ID and the matching `flutter.ctl_<listID>` JSON.
3. Validate and evaluate TaskForge's group and condition logic against all v6 tasks.
4. Learn only non-conflicting symbols from real source records and persist them privately.
5. Find or create only the state lists needed by current statuses. Reuse/rename the legacy
   `TaskForge 今日` list as `TaskForge · 待办`.
6. Match managed reminders by the stable marker or private index. Duplicate candidates are a
   conflict and never cause a new reminder.
7. Move the reminder to the canonical status list, update title, original scheduled date/time,
   priority and concise marker notes, and preserve completion.
8. Completed/cancelled tasks are completed in EventKit and are not put in an active state list.
9. Managed reminders whose source task left the fixed list are moved to the base `待办` list
   so the protected prune state machine can classify low-priority absent items.

No date filter is added by this path. An existing task's original schedule is the only date
information sent to EventKit.

## Reverse flow and conflict precedence

All state lists are read for managed reminders, including completed reminders. For an open task,
the previous private index status distinguishes a TaskForge change from an Apple list move:

| Situation | Decision |
|---|---|
| TaskForge open status changed | TaskForge wins; forward phase moves Apple reminder |
| Apple open list changed only | Write that approved status to source, then verify readback |
| Both open sides changed | TaskForge wins; Apple reminder is moved back |
| Apple completion is newly observed | Apple completion wins; source becomes `done` |
| Apple reminder was moved to an ordinary list | Move it back to current TaskForge state |
| Symbol unknown/conflicting or source stale | Refuse source write and move reminder back |

Source write checks the resolved source path is inside the Vault, reads the exact original bytes,
backs them up, applies only the status edit, atomically replaces the file, hashes and reads it
back, then waits up to 15 seconds for TaskForge to expose the target state. A completion never
deletes a TaskForge line or file.

## State list policy

Known active states map to the names and colors documented in the README. Unknown active states
use the configured prefix and a gray list; terminal states have no active list. Existing exact
state-list duplicates are ambiguous and stop the pass. A normal Apple list is never treated as a
status merely because its title resembles one.

## Pruning and recovery

The custom path scopes pruning to `TaskForge · 待办`. It protects completed, important,
priority-bearing, indeterminate and ordinary reminders. An absent low-priority managed item is
registered in a private ledger, re-fetched after at least 60 seconds, backed up, removed, and
verified. Fetches time out after 30 seconds; timeout, permission, source and I/O errors preserve
the reminder. Other Apple lists are never fetched as prune inputs.

Source references used for historical presence checks are stored in the private index, not in
reminder notes. The private index is passed into the pruning policy so historical managed items
remain protected without exposing full paths in EventKit notes.

All deletion and source-write backups are private, checksum-verified and recoverable. Restore
never consumes a backup when account, calendar, schema, checksum or readback is ambiguous.

The custom deduplication command builds duplicate groups from all active marked reminders using
the private source references, moves confirmed extras to `TaskForge 今日 · 去重归档`, marks those
extras complete, and adds an archive marker that excludes them from reverse completion. It never
deletes the reminder or its TaskForge source.

## Why the binary cache is read-only

`tasks.v6.bin` is a TaskForge cache and implementation detail. Writing it could race with
TaskForge or bypass the source-of-truth rules. Reverse sync changes the Markdown/TaskNotes
source, then waits for TaskForge to re-index it.

## Loop prevention and safety gates

- EventKit notifications are debounced and passes cannot run concurrently.
- A reminder is claimed by at most one source task per pass.
- Completion is monotonic; forward sync never reopens an Apple-completed reminder.
- Date comparisons use only year/month/day/hour/minute, not EventKit metadata.
- Private configuration/index permission or schema failures stop writes.
- No production permission request, write, cleanup or watcher acceptance is automated by tests.
