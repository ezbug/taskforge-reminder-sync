# Security Policy

## Supported version

The latest commit on the default branch is the supported development version.

## Reporting a vulnerability

Do not open a public issue for a vulnerability that could expose Vault
contents, task titles, file paths or Apple Reminders data.

Please use GitHub's private vulnerability reporting feature for this
repository. Include:

- affected commit;
- macOS and TaskForge versions;
- reproduction steps;
- the smallest redacted example possible;
- expected and observed behavior.

Never attach a real `tasks.v6.bin`, Vault file, reminder export, backup or log
containing private task data.

## Security boundaries

The application deliberately refuses to:

- modify a source outside the active TaskForge Vault;
- reverse-complete recurring tasks;
- process tasks whose completion policy is not `keep`;
- edit a stale or ambiguous Markdown task;
- write directly to TaskForge's binary cache.

Reminder pruning adds these fixed boundaries:

- only the configured Apple Reminders list is fetched for pruning; other lists,
  completed history and the deduplication archive are never prune targets;
- multiple same-named target lists fail closed instead of selecting one;
- only unfinished, unimportant reminders confirmed absent from both the
  current TaskForge snapshot and their durable Vault source may be candidates;
- EventKit priority greater than zero and the six leading title markers `!`,
  `！`, `❗`, `‼️`, `⭐`, `📌` protect a reminder;
- deletion requires two unchanged scans at least 60 seconds apart and a
  checksummed `0600` backup verified before the EventKit commit;
- snapshot, source, permission, I/O, ledger, backup, EventKit timeout and
  ambiguous restore errors preserve data and fail closed;
- `--prune-dry-run` never writes the ledger, backups, salt or reminders;
- TaskForge reverse completion only changes a task to `done`; pruning never
  deletes or moves a TaskForge source task;
- restoration skips unresolved, zero-deletion and already restored backups,
  selecting the newest remaining verified batch with a non-empty actual
  deletion result.

EventKit target-list reads time out after 30 seconds and cancel the outstanding
request. Pruning logs use aggregate counts, anonymous error categories and
salted truncated identifiers; they exclude reminder content, local paths and
raw TaskForge or EventKit IDs.

The private candidate ledger, restore backups and hash salt live under
`~/Library/Application Support/TaskForgeReminderSync/` with `0600` file
permissions. They are intentionally preserved by uninstall for recovery and
must never be attached to a public issue or committed to Git.
