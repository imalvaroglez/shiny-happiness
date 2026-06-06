# FinanceTracker Release Checklist

Use this checklist before running a release build against production financial data.

## Personal Stable Release

- Confirm the worktree is clean before release edits.
- Set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
- Move `CHANGELOG.md` entries from `[Unreleased]` into the dated release section.
- Review the About "What's New" bullets in `SettingsView`.
- Run `xcodegen generate` after project metadata changes.

## Data Safety Gate

- Launch the current known-good app before upgrading.
- Export a manual `.ftbackup` from Settings.
- Verify automatic snapshots exist in `~/Library/Application Support/FinanceTracker/Backups/`.
- Keep the latest `.ftbackup` as the rollback source of truth.
- Do not run experimental or development builds against the production store without a fresh backup created immediately before launch.

## Validation

Run the serial test suite:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests -destination 'platform=macOS' -parallel-testing-enabled NO
```

Run a Release build:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project FinanceTracker.xcodeproj -scheme FinanceTracker -configuration Release build
```

Smoke test the release app:

- Launch the app and verify the dashboard loads.
- Open Settings and confirm the About version.
- Create or export a backup.
- View one known account or import one known statement.
- Quit and relaunch.

## Tag And Rollback

- Tag the validated release commit, for example `v0.3.0`.
- If a future build damages data, reinstall the previous tagged app and restore from the latest verified `.ftbackup`.
- Any future SwiftData model/schema change must include: backup first, focused reset/dashboard/persistence coverage, full serial suite, and a changelog entry.
