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
