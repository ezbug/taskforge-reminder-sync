# Troubleshooting

## Start with a read-only custom-list preview

```bash
APP=./dist/TaskForgeReminderSync.app/Contents/MacOS/TaskForgeReminderSync
"$APP" --check-config --taskforge-list-id LIST_ID
"$APP" --dry-run --taskforge-list-id LIST_ID
```

The preview reads TaskForge only. It must report the same dynamic member count as the current
TaskForge Today list before any command that requests Reminders permission. A missing list ID,
missing `flutter.ctl_<id>`, malformed JSON, unknown filter field/operator, or malformed v6 store
is a fail-closed configuration error.

Once accepted, configure once with `--sync --taskforge-list-id LIST_ID`; later runs can omit the
ID and read the private `0600` configuration. Never place a real ID in shell history shared with
others, logs, tests or repository files.

## Permission denied

Open `System Settings → Privacy & Security → Reminders` and grant full access to the built App.
The TaskForge container or Vault may additionally require Full Disk Access. Rebuilt ad hoc-signed
Apps can receive a new TCC identity and may need re-authorization. The project never resets TCC
or approves permissions automatically.

## A list or reminder is missing

Check the source first:

```bash
"$APP" --dry-run
```

Confirm the task is a member of the fixed custom Kanban list, not terminal, and that its status
is a known or displayable active status. A status list is created only when needed. If the old
`TaskForge 今日` list exists, it is renamed in place to `TaskForge · 待办`.

If a managed reminder was moved to a normal Apple list, the next reverse pass moves it back. A
normal reminder without the marker/index is never imported or modified.

## Apple completion is not reflected in TaskForge

1. Keep TaskForge running so it can re-index the source.
2. Run `--reverse-dry-run --task-id TEST_TASK_ID`.
3. Check that the reminder still has the tool marker and is a managed task.
4. Check the source is inside the current Vault and has not changed at the expected line.
5. Confirm the source type is Markdown inline or TaskNotes and that symbol learning is not conflicting.

An unknown or conflicting symbol intentionally refuses the source write and moves the reminder
back. Completion writes `done`; it never deletes the source task.

## Open-state move was rejected

The source status must be learned from real records. Current Markdown writeback symbols are
`[ ]`, `[>]`, `[/]` and `[x]`. A symbol not learned for the target status, a symbol conflict,
stale original line, ambiguous match, non-UTF-8 source, or Vault escape is a deliberate stop.
TaskForge wins an open/open conflict; Apple completion wins an open/completed conflict.

## TaskForge list was deleted or changed

Stop the watcher. Restore or recreate the original fixed list without silently choosing a new
ID, then run the anonymous preview again. A renamed list keeps its ID; a deleted or missing ID
stops synchronization rather than falling back to a date query.

## Prune candidate is not deleted

Use the strict read-only classification:

```bash
"$APP" --prune-dry-run
```

Retention is expected when the reminder is completed, important, priority-bearing, in an
ordinary list, still present in the current snapshot, source-confirmed by the private index,
indeterminate due to I/O/permissions/ambiguity, or has not passed two unchanged scans separated
by at least 60 seconds. A move, edit, completion or source reappearance restarts the gate.

`--prune-dry-run` never creates or changes the ledger, backup directory, salt or reminders. A
normal mutating pass may tighten a safe user-owned private root to `0700`; an exposed symlink,
wrong owner, ACL or damaged state remains fail-closed.

## EventKit reading times out

Kanban fetches and prune fetches have a 30-second limit. The request is cancelled once and the
pass fails closed; a late callback is ignored. Check Reminders permission and retry only after
Reminders is responsive. A timeout must never be treated as an empty list.

## Roll back a cleanup or source write

Stop the watcher first. Use `--restore-last-prune` for the newest verified reminder deletion
batch. Source-file backups are below:

```text
~/Library/Application Support/TaskForgeReminderSync/Backups/
```

Compare hashes before restoring. Keep the private index and backups until TaskForge re-reads the
source and a fresh `--dry-run`/`--prune-dry-run` passes.

## Watcher and LaunchAgent

```bash
launchctl print "gui/$(id -u)/local.codex.taskforge-reminder-sync"
tail -n 100 ~/Library/Logs/TaskForgeReminderSync.error.log
```

Verify the private list ID exists before reinstalling. The watcher should be left running for at
least 61 seconds during acceptance so both the event path and the full-scan fallback are observed.
To reinstall:

```bash
./scripts/uninstall-daily-sync.sh
./scripts/install-daily-sync.sh
```

The installer does not delete reminders, TaskForge sources, private indexes or backups.
