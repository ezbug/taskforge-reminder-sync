# Architecture

## Components

### TaskForgeReminderCore

A Foundation-only library responsible for:

- decoding TaskForge MessagePack v6 records;
- selecting scheduled open tasks;
- creating and decoding stable markers;
- deriving stable source identities and selecting deduplicated reminder matches;
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

The `--audit` path reads every managed reminder in the target list and
separately reports duplicate task identifiers, duplicate active source
identities, duplicate completed occurrences, normal historical source reuse and
missing source identities. It emits aggregate counts only, including for
historical reminders no longer present in the current TaskForge cache.

The explicit deduplication path builds connected duplicate groups from active
reminders that share either a TaskForge ID or a source identity. It preserves a
single canonical reminder, preferring an ID still present in the current cache
and otherwise the oldest item. Every redundant reminder is moved—not
deleted—to a separate archive calendar before forward reconciliation refreshes
the preserved item.

### LaunchAgent

The installed LaunchAgent keeps a small signed supervisor alive. The supervisor
starts the app through LaunchServices, monitors the exact `--watch` process and
terminates it when the LaunchAgent is unloaded. Launching the bundle, rather
than its inner Mach-O directly, preserves the EventKit/TCC app identity in the
background. The watcher:

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
5. If the ID changed, fall back to a durable source identity:
   - inline Markdown: standardized file path and line number;
   - TaskNotes: standardized file path.
6. Prefer an uncompleted reminder at that source. A completed reminder also
   needs the same scheduled day, so an older task that reused the line cannot
   capture a new occurrence.
7. Reject ambiguous ID/source/occurrence matches instead of creating another
   reminder.
8. Create/update title, due date, notes, marker and durable source reference.
9. Preserve completion if either side is already completed.

Only today's open tasks create new reminders. Existing linked reminders may
still be refreshed so title, date, time, completion and durable source mapping
stay current. A source-identity fallback rewrites the old marker on the same
EventKit item, so a TaskForge reindex does not create a second reminder.

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
- A reminder is claimed by at most one TaskForge task in each reconciliation.
- Duplicate IDs, duplicate source identities and ambiguous existing reminders
  are reported as conflicts and never cause a new reminder to be created.
