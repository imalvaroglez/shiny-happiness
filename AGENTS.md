# Repository Guidelines

## Project Structure & Module Organization

`FinanceTracker/` contains the macOS SwiftUI application. Key areas are `App/` for app bootstrap and SwiftData container setup, `Domain/` for models, value objects, and domain extensions, `Ingest/` for statement detection, parsing, normalization, deduplication, and seed data, `Features/` for SwiftUI screens, and `Utilities/` for shared helpers. JSON resources live under `FinanceTracker/Ingest/SeedData/` and `FinanceTracker/Ingest/StructuralParser/Knowledge/`.

`FinanceTrackerTests/` mirrors behavior by area: parser tests in `ParserTests/`, pipeline tests in `PipelineTests/`, structural parser tests in `StructuralParserTests/`, and integration coverage in `EndToEndTests/`. Sample PDFs and paste inputs used by tests live in `samples/`. Architecture decisions are documented in `DECISIONS.md`; planned work lives in `specs/`.

## Build, Test, and Development Commands

- `xcodegen generate` regenerates `FinanceTracker.xcodeproj` from `project.yml`; run it after adding, moving, or deleting Swift files.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project FinanceTracker.xcodeproj -scheme FinanceTracker build` builds the app.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests -destination 'platform=macOS' -parallel-testing-enabled NO` runs the full test suite serially.
- `xcodebuild test ... -only-testing:FinanceTrackerTests/CategorizerTests` runs one test class.
- `open FinanceTracker.xcodeproj` opens the generated project in Xcode.

## Coding Style & Naming Conventions

Use Swift 6 with strict concurrency. Keep ViewModels and SwiftData `ModelContext` work on `@MainActor`; keep parsers as `Sendable` structs with async parsing methods. Store money as `Decimal`; do not introduce `Double` or `Float` in `FinanceTracker/Domain/`. Follow existing Swift naming: types in `PascalCase`, methods/properties in `camelCase`, test files ending in `Tests.swift`.

## Testing Guidelines

Use XCTest-style unit and end-to-end tests under `FinanceTrackerTests/`. Add focused tests when changing parsers, normalization, categorization, dashboard snapshots, or backup behavior. Prefer real fixtures from `samples/` for statement parsing. Run the serial full-suite command before handing off changes that touch ingest, persistence, or shared domain logic.

## Commit & Pull Request Guidelines

Git history uses conventional commit prefixes such as `feat:`, `fix:`, `test:`, `docs:`, and `perf:`. Keep commits scoped and imperative, for example `test: add HSBC paste parser reconciliation cases`. Pull requests should include a short problem statement, implementation summary, test results, linked issues or specs, and screenshots for visible SwiftUI changes.

## Security & Configuration Tips

This is a private finance app. Do not commit personal statements, generated stores, secrets, or unredacted financial data. Keep entitlements and sandbox settings aligned with `project.yml`, especially user-selected file access for imports and backups.
