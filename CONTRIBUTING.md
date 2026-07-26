# Contributing

Contributions are welcome, especially compatibility reports for newer
TaskForge storage versions.

## Development

```bash
swift run TaskForgeReminderCoreTests
swift build
./scripts/build-app.sh
```

Use test-driven development for behavior changes. Add a failing test first,
implement the smallest change, then run the complete test executable.

## Privacy requirements

Before committing:

1. Never add `tasks.v6.bin`, Vault files, reminder exports, logs or backups.
2. Replace task titles, usernames and absolute paths with synthetic fixtures.
3. Inspect `git diff --cached` and `git ls-files`.
4. Run a credential scanner if available.
5. Confirm generated directories remain ignored.

## Pull requests

Explain:

- the user-visible behavior;
- the TaskForge data-format assumptions;
- safety and rollback implications;
- tests performed;
- any new macOS permission requirement.
