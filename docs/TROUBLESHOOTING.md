# Troubleshooting

## Permission denied

Open:

`System Settings → Privacy & Security → Reminders`

Enable **TaskForge Reminder Sync**. If the TaskForge cache or Vault cannot be
read, also check **Full Disk Access**.

If a manual `--sync` works but the LaunchAgent does not write a startup log,
re-run `./scripts/install-daily-sync.sh`. Current releases start the bundle
through LaunchServices so the background process retains the same Reminders
permission identity as the app.

Locally rebuilt ad hoc-signed apps receive a version-specific code identity.
After rebuilding, re-authorize the newly installed app. To preserve identity
across builds, use a stable code-signing certificate via
`TASKFORGE_SYNC_CODESIGN_IDENTITY`; the project never creates one automatically.

## LaunchAgent is not running

```bash
launchctl print "gui/$(id -u)/local.codex.taskforge-reminder-sync"
tail -n 100 ~/Library/Logs/TaskForgeReminderSync.error.log
```

Reinstall:

```bash
./scripts/uninstall-daily-sync.sh
./scripts/install-daily-sync.sh
```

## A reminder is not created

Run:

```bash
./dist/TaskForgeReminderSync.app/Contents/MacOS/TaskForgeReminderSync \
  --check-config
./dist/TaskForgeReminderSync.app/Contents/MacOS/TaskForgeReminderSync \
  --dry-run
```

Confirm the task is scheduled for today and is not already done or cancelled.

## A TaskForge edit reports a deduplication conflict

The forward log includes `冲突 N`. A conflict means more than one TaskForge
record or managed reminder carries the same ID/source identity. The tool does
not select one arbitrarily and does not create another reminder.

1. Stop editing the affected task briefly and let TaskForge finish re-indexing.
2. Run `--sync` again and confirm the conflict settles to `0`.
3. If it remains, inspect only redacted reminder metadata and source locations.
4. Do not delete reminders automatically; decide which existing item is
   authoritative before manual cleanup.

## Apple completion is not reflected in TaskForge

1. Keep TaskForge running.
2. Check the standard and error logs.
3. Confirm the reminder was created by this tool and still contains its marker.
4. Confirm the source remains inside the current Vault.
5. Confirm the task is non-recurring and uses `onCompletion=keep`.

Use `--reverse-dry-run --task-id TASK_ID` before any manual retry.

## Restore a source file

Backups are stored below:

`~/Library/Application Support/TaskForgeReminderSync/Backups/`

Each run uses a timestamped directory. Compare the backup and current source
before restoring. Stop the LaunchAgent first if manual restoration is needed.

## Repeated sync loop

Current versions compare EventKit date components semantically and should
settle at `更新 0`. If logs show continuous updates:

1. stop the LaunchAgent;
2. save the relevant redacted logs;
3. report the macOS and TaskForge versions;
4. do not publish real reminder notes or Vault paths.
