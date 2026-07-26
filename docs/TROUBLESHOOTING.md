# Troubleshooting

## Permission denied

Open:

`System Settings → Privacy & Security → Reminders`

Enable **TaskForge Reminder Sync**. If the TaskForge cache or Vault cannot be
read, also check **Full Disk Access**.

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
