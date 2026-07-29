# Architecture

## Components

### TaskForgeReminderCore

A Foundation-only library responsible for:

- decoding TaskForge MessagePack v6 records;
- selecting scheduled open tasks;
- creating and decoding stable markers;
- deriving stable source identities and selecting deduplicated reminder matches;
- serializing durable source references;
- classifying prune candidates and advancing the two-scan state machine;
- encoding private prune ledgers and checksummed restore backups;
- comparing reminder dates semantically;
- validating and editing Markdown / TaskNotes completion state.

Keeping these rules outside EventKit makes them deterministic and testable.

### TaskForgeReminderSync

The macOS executable coordinates:

- `EKEventStore` access;
- forward and reverse reconciliation;
- target-list-only pruning and restoration;
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

The pruning path is separate from deduplication. It selects exactly one
configured list by name, fails closed if that name is ambiguous, and builds an
EventKit predicate scoped to that one calendar. Reminders from other lists,
including the deduplication archive, are never fetched as prune inputs.

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

Each reconciliation is serialized and runs in this order:

1. reverse-complete Apple reminders into TaskForge sources;
2. create or refresh today's TaskForge reminders in Apple Reminders;
3. advance the pruning state machine against the latest snapshot and sources.

This preserves completion writeback before any candidate can be deleted.

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

Reverse completion only changes the source task to `done`. It never deletes a
Markdown task line, TaskNotes file or any other TaskForge source item.

## Prune flow

1. Select exactly one configured calendar. No match means no prune work;
   multiple same-named matches fail closed.
2. Fetch reminders with an EventKit predicate containing only that calendar.
   A fetch is cancelled after 30 seconds and the pass fails closed.
3. Protect every completed reminder, every reminder with EventKit priority
   greater than zero, and every title whose leading whitespace is followed by
   `!`, `！`, `❗`, `‼️`, `⭐` or `📌`.
4. Resolve TaskForge presence from both the current snapshot and the durable
   source reference. Only `.absent` is eligible; permission, I/O, out-of-Vault
   and ambiguous-source results are indeterminate and protected.
5. On the first eligible scan, store the EventKit ID, calendar ID, candidate
   fingerprint, first-seen time and rules version in the private ledger.
6. On a later scan at least 60 seconds after first sighting, refetch and
   reclassify the reminder. Any identity, calendar or fingerprint change
   revokes or restarts the candidate.
7. Before deleting a confirmed batch, write a checksummed private backup and
   read it back. A write or verification failure rejects the whole batch.
8. Stage EventKit removals, commit once, then refetch actual state. Record and
   report what was actually deleted rather than assuming atomic success.

`--prune-dry-run` uses a read-only ledger load and never creates or modifies
the ledger, backup directory, hash salt or EventKit items. `--prune-once`,
`--sync` and each watcher pass advance the same state machine.

Private pruning state defaults to:

- `~/Library/Application Support/TaskForgeReminderSync/PruneCandidates.json`;
- `~/Library/Application Support/TaskForgeReminderSync/PruneBackups/`;
- `~/Library/Application Support/TaskForgeReminderSync/PruneHashSalt`.

The parent directory is `0700`; ledger, backups and salt are `0600`. Writes use
temporary files and atomic replacement. The salt produces truncated hashes for
anonymous item correlation; logs contain counts, hashed identifiers and error
categories, never reminder content, source paths or raw identifiers.

## Restore flow

`--restore-last-prune` selects the newest backup with a verified, recorded
actual deletion result that has not been restored. It restores only items
confirmed deleted, preserving EventKit-readable user fields. EventKit assigns
new system IDs.

The original calendar is matched by calendar and source identifiers first. If
it no longer exists, restoration may recreate it only in the recorded original
source. A missing source, multiple same-named calendars in that source,
unsupported backup schema, checksum mismatch or ambiguous readback fails
closed without consuming the backup.

Restored reminders receive a ledger grace entry for at least 24 hours. When
the grace period expires, an item still satisfying the candidate policy starts
again at the first scan; restoration never skips the two-scan requirement.

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
- Prune and restore operations are serialized in-process and with a private
  operation lock.
- A reminder is claimed by at most one TaskForge task in each reconciliation.
- Duplicate IDs, duplicate source identities and ambiguous existing reminders
  are reported as conflicts and never cause a new reminder to be created.
