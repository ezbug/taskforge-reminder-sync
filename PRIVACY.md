# Privacy

TaskForge Reminder Sync is designed to run entirely on the local Mac.

## Data it reads

- TaskForge's local `tasks.v6.bin` cache;
- titles, schedules, status and source metadata for TaskForge tasks;
- reminders in the configured Apple Reminders list;
- Markdown or TaskNotes source files only when a linked reminder is completed.

## Data it writes

- linked reminders in the configured Apple Reminders list;
- completion markers in the matching Vault source task;
- timestamped source-file backups under
  `~/Library/Application Support/TaskForgeReminderSync/Backups/`;
- operational logs under `~/Library/Logs/`.

## Data it does not send

The application contains no HTTP client, analytics SDK, telemetry, advertising,
crash-reporting service or hosted backend. It does not upload task titles,
Vault paths, reminder contents or source files to this repository or to a
third-party service.

Apple Reminders may sync through iCloud according to the user's Apple account
and system settings. That synchronization is performed by macOS, not by this
project.

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
should still inspect staged files before every push.
