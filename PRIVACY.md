# Privacy

TaskForge Reminder Sync is designed to run entirely on the local Mac.

## Data it reads

- TaskForge's local `tasks.v6.bin` cache;
- titles, schedules, status and source metadata for TaskForge tasks;
- reminders in the configured Apple Reminders list only; pruning does not fetch
  reminder contents from any other list;
- the matching Markdown or TaskNotes source file when reverse-completing a
  linked reminder;
- for pruning classification of an unfinished reminder, only the Vault file
  named by that reminder's durable source reference, to confirm whether the
  source task still exists.

## Data it writes

- linked reminders in the configured Apple Reminders list;
- completion state in the matching Vault source task during reverse completion;
- automatic deletion of target-list reminders only after they satisfy every
  prune-candidate rule and pass the two-scan confirmation;
- restored reminders rebuilt under the original reminders source and list
  semantics recorded by the verified backup;
- timestamped source-file backups under
  `~/Library/Application Support/TaskForgeReminderSync/Backups/`;
- the `0600` pruning candidate ledger at
  `~/Library/Application Support/TaskForgeReminderSync/PruneCandidates.json`;
- checksummed `0600` reminder restore backups under
  `~/Library/Application Support/TaskForgeReminderSync/PruneBackups/`;
- a `0600` local random hashing salt at
  `~/Library/Application Support/TaskForgeReminderSync/PruneHashSalt`;
- operational logs under `~/Library/Logs/`.

The pruning ledger stores raw EventKit and target-list identifiers, timestamps,
candidate fingerprints, rules versions and restore grace periods. Pruning
backups contain the reminder fields needed for restoration, including titles,
notes, dates, priority, alarms, recurrence data and original system
identifiers. These are sensitive local runtime data. Their parent application
support directory, source-backup tree and batch directories are restricted to
the current user (`0700`); backup and state files use `0600`.

## Data it does not send

The application contains no HTTP client, analytics SDK, telemetry, advertising,
crash-reporting service or hosted backend. It does not upload task titles,
Vault paths, reminder contents or source files to this repository or to a
third-party service.

Apple Reminders may sync through iCloud according to the user's Apple account
and system settings. That synchronization is performed by macOS, not by this
project.

## Pruning logs

Pruning output is limited to aggregate candidate, waiting, deletion,
restoration and failure counts; when item correlation is needed it uses a
truncated hash derived with the local random salt. Pruning logs do not contain
reminder titles or notes, Vault or source-file paths, raw TaskForge IDs or raw
EventKit IDs. Errors are reported by category without user content.

An EventKit reminder fetch is scoped to the configured list and cancelled after
30 seconds. Timeout, permission, snapshot, source-resolution and I/O failures
are treated as indeterminate and preserve the reminder.

## Metadata stored in reminders

Linked reminders contain:

- a stable, Base64-encoded TaskForge marker;
- a Base64-encoded source reference used for historical reverse completion;
- a human-readable source type, file path and line number.

Anyone who can read the reminder can therefore see its title and source path.
Use a dedicated reminder list and an Apple account you trust.

## Permissions

- **Reminders full access** is required to create, update and observe reminders.
- **Full Disk Access** may be required by macOS to read TaskForge's sandbox
  container or a protected Vault location.

The tool does not request Calendar, Contacts, Photos, microphone, camera or
location access.

## Public repository hygiene

Generated build directories, TaskForge cache files, logs, backups, `.env`
files and local plist overrides are excluded by `.gitignore`. Contributors
should still inspect staged files before every push. `PruneCandidates.json`,
`PruneBackups/`, `PruneHashSalt`, `PruneHashSalt.lock` and
`*.prune-test.json` are explicitly ignored in case private debugging data is
copied into a checkout.

Never commit reminder titles, notes, Vault or source paths, raw TaskForge /
EventKit identifiers, candidate ledgers, pruning backups, salts or production
logs. Uninstalling the App intentionally preserves these private files so that
recovery remains possible; review and remove them separately only after any
needed `--restore-last-prune` operation.
