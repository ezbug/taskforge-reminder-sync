# Privacy

TaskForge Reminder Sync is designed to run entirely on the local Mac.

## Data it reads

- TaskForge's local `tasks.v6.bin` cache;
- the preferences plist entry `flutter.ctl_<fixed-list-id>`;
- titles, status, priority, original schedule and source metadata needed for selected custom-list members;
- reminders only when they carry this tool's marker or match the private index;
- the exact Markdown or TaskNotes source file when an approved reverse write is requested;
- the Vault source referenced by the private index when pruning confirms historical presence.

## Data it writes

- only the tool-managed Apple status lists and their managed reminders;
- the status of a matching Vault source task during reverse sync;
- verified source-file backups and verified reminder deletion backups;
- private configuration, learned symbols, source references, state history and hashes;
- aggregate operational logs.

The default private root is:

```text
~/Library/Application Support/TaskForgeReminderSync/
```

The root and directories are `0700`; configuration, index, ledger, source backups, reminder
backups and salts are `0600`. The list ID, full source references and reminder mappings are
never committed to Git and are not printed in logs. If permissions, ownership, symlinks,
extended ACLs, schema or hashes are unsafe, the operation fails closed.

## Data it does not send

The project has no HTTP client, hosted backend, analytics SDK, telemetry, advertising or
crash-reporting service. It does not upload task titles, notes, Vault paths, source files,
personal profiles or list IDs. Apple may sync reminders through iCloud according to the user's
Apple account and macOS settings; that is performed by Apple, not this project.

The tool does not use Computer Use and does not request Calendar, Contacts, Photos, microphone,
camera or location access.

## Reminder notes

Managed reminder notes contain only a stable TaskForge tool marker and a short source marker.
The marker is intended for management, not secrecy. Full source references, previous status,
source hashes and EventKit mappings remain in the private `0600` index rather than being copied
into reminder notes.

## Logs and recovery

Logs contain status counts, timing and anonymous error categories. They do not contain raw task
IDs, EventKit IDs, titles, notes, list IDs, Vault paths or source paths. Backups are intentionally
sensitive local data because they can contain the fields required to restore a source or
reminder; stop the watcher before manual recovery and preserve their permissions.

Reverse completion changes a source task to `done` and never deletes a TaskForge task. Cleanup
deletes only a managed, low-priority, unfinished reminder after the two-scan gate and verified
backup; ordinary Apple reminders and all TaskForge source tasks are protected.
