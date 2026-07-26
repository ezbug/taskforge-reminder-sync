# Architecture

## Components

### TaskForgeReminderCore

A Foundation-only library responsible for:

- decoding TaskForge MessagePack v6 records;
- selecting scheduled open tasks;
- creating and decoding stable markers;
- serializing durable source references;
- comparing reminder dates semantically;
- validating and editing Markdown / TaskNotes completion state.

Keeping these rules outside EventKit makes them deterministic and testable.

### TaskForgeReminderSync

The macOS executable coordinates:

- `EKEventStore` access;
- forward and reverse reconciliation;
- source backups and SHA-256 receipts;
- TaskForge cache refresh verification;
- EventKit notifications, polling and scheduled fallbacks.

### LaunchAgent

The installed LaunchAgent runs one `--watch` process per logged-in user. The
watcher:

1. reconciles at startup;
2. debounces `EKEventStoreChanged` notifications for 750 ms;
3. checks the TaskForge cache mtime every second;
4. runs a full reconciliation every minute;
5. runs additional checks at 07:00, 11:00 and 15:00.

## Forward flow

1. Decode `tasks.v6.bin`.
2. Select tasks scheduled today and not completed/cancelled.
3. Find or create the configured reminder list.
4. Match reminders by a stable marker derived from Vault path and task ID.
5. Create/update title, due date, notes and durable source reference.
6. Preserve completion if either side is already completed.

Only today's open tasks create new reminders. Existing linked reminders may
still be refreshed so their durable source mapping stays current.

## Reverse flow

1. Fetch all reminders from the configured list, including completed history.
2. Keep only completed reminders carrying this tool's marker.
3. Resolve the task from the current TaskForge cache or the durable reminder
   source reference.
4. Reject recurring, non-`keep`, out-of-Vault or ambiguous tasks.
5. Detect and skip a source that is already completed.
6. Back up the complete source file.
7. Apply the completion edit atomically.
8. Verify exact file bytes and wait for TaskForge's cache to refresh.

## Why the binary cache is read-only

`tasks.v6.bin` is treated as an implementation detail and cache, not as a
public database. Writing it could race with TaskForge, corrupt the cache or
bypass TaskForge's own source-of-truth rules. Reverse sync therefore changes
the Vault source and lets TaskForge re-index it.

## Loop prevention

- Apple completion is monotonic: forward sync never reopens an already
  completed reminder.
- Date components are compared by year/month/day/hour/minute, ignoring
  EventKit's calendar/time-zone metadata.
- EventKit changes are debounced.
- A second reconciliation is queued instead of running concurrently.
