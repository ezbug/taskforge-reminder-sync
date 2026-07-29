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

Pruning also needs private local state under:

`~/Library/Application Support/TaskForgeReminderSync/`

The directory must be accessible only to the current user (`0700`), while
`PruneCandidates.json`, files below `PruneBackups/` and `PruneHashSalt` must be
`0600`. If permissions are broader, the ledger is damaged, or a backup checksum
does not verify, pruning fails closed and keeps the reminders.

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

Reverse sync only marks the TaskForge source task `done`; reminder pruning
never deletes TaskForge task lines or TaskNotes files.

## A prune candidate is not deleted

Run the strict read-only classification first:

```bash
./dist/TaskForgeReminderSync.app/Contents/MacOS/TaskForgeReminderSync \
  --prune-dry-run
```

Common safe reasons for retaining a reminder are:

- it is completed, has EventKit priority greater than zero, or starts with
  `!`, `！`, `❗`, `‼️`, `⭐` or `📌` after leading whitespace;
- the TaskForge current snapshot still contains it;
- its durable source reference still resolves to a real Vault task;
- source presence is indeterminate because of permissions, I/O, an out-of-Vault
  path or an ambiguous same-named source task;
- the second unchanged scan has not occurred at least 60 seconds later;
- the reminder changed, moved lists or regained TaskForge identity, which
  revokes or restarts the candidate;
- it was restored less than 24 hours ago;
- the candidate ledger or deletion backup cannot be privately written and
  verified.

`--prune-dry-run` is strictly read-only: it does not create or change the
candidate ledger, backup directory, hash salt or reminders. To advance state,
use `--prune-once`, `--sync`, or let `--watch` complete another reconciliation.

## Pruning reports an ambiguous list

If more than one Apple Reminders list has the configured name, pruning and
name-based restoration refuse to select one. Rename the unintended duplicate,
then rerun `--prune-dry-run`. Do not delete either list until you have checked
which one contains the expected reminders and backups.

Pruning never fetches reminder contents from other lists. If the configured
list does not exist, a prune pass returns zero and does not create it.

## Reminder reading times out

Each target-list EventKit fetch has a 30-second limit. On timeout, the tool
cancels that fetch request once, records an anonymous error category and skips
deletion. Check Reminders permission and whether the Reminders app is
responsive, then retry. A late callback from the cancelled request is ignored.

## Restore the last pruned batch

Run:

```bash
./dist/TaskForgeReminderSync.app/Contents/MacOS/TaskForgeReminderSync \
  --restore-last-prune
```

The command restores the newest verified, un-restored batch whose parsed actual
deletion result is non-empty. Newer unresolved or zero-deletion backups remain
available for audit but do not block an older real deletion batch and are not
marked restored. It restores user-editable fields, but macOS assigns new
EventKit IDs. Restored reminders receive a 24-hour minimum grace period and
must complete two new scans before any later deletion.

If the original list is gone, the tool attempts to recreate it only in the
original reminders account recorded by the backup. A missing account, multiple
same-named lists in that account, unsupported or modified backup, or ambiguous
post-restore readback fails closed; the backup remains available for retry.
The command is idempotent after an interrupted restore and will not knowingly
duplicate an already read-back restored item.

If no eligible non-empty unrestored batch is found, the restored count is zero.
Unresolved, empty and restored backups remain at:

`~/Library/Application Support/TaskForgeReminderSync/PruneBackups/`

## Restore a source file

Backups are stored below:

`~/Library/Application Support/TaskForgeReminderSync/Backups/`

Each run uses a timestamped directory. Compare the backup and current source
before restoring. Stop the LaunchAgent first if manual restoration is needed.

This source-file backup is separate from `PruneBackups/`, which restores Apple
reminders deleted by the pruning feature.

## Repeated sync loop

Current versions compare EventKit date components semantically and should
settle at `更新 0`. If logs show continuous updates:

1. stop the LaunchAgent;
2. save the relevant redacted logs;
3. report the macOS and TaskForge versions;
4. do not publish real reminder notes or Vault paths.

## Uninstall and private pruning data

```bash
./scripts/uninstall-daily-sync.sh
```

Uninstalling stops the LaunchAgent and removes the installed App. It does not
delete Apple reminders, Vault sources, the candidate ledger, pruning backups,
hash salt or logs. If you may need a deleted reminder, run
`--restore-last-prune` before removing those private runtime files. If the App
is already uninstalled, rebuild it and run the restore command from `dist`;
the preserved backup remains the source of truth.
