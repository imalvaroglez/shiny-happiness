# LOOPS — FinanceTracker change workflow

This is the authoritative, repository-native workflow for moving a product
change from request to an installed, rollback-safe release of the FinanceTracker
macOS app. It is operational: a future coding agent should be able to follow it
without reconstructing the working agreement from conversation history.

`AGENTS.md` remains the architecture, style, and production-data-safety
contract. This document governs **process** — how work is planned, verified,
approved, released, installed, and rolled back. Where the two overlap
(production-data safety, release gates), this document references `AGENTS.md`
rather than duplicating it.

Everything below is grounded in the real repository. Commands, paths, bundle
ids, version formats, and backup locations are actual, not illustrative. Where
a mechanism does not exist in the repo (CI, SwiftLint, an install script), it
is stated as absent and a safe manual replacement or blocking condition is
defined. Nothing here is invented to look plausible.

---

## 1. Purpose

`LOOPS.md` defines, for FinanceTracker:

- how a product change moves from request to implementation;
- what "ready for development validation" means and does **not** authorize;
- what requires explicit human approval, and what kind of approval;
- what "ready for release" means;
- how specifications, independent reviews, Pull Requests, backups, builds,
  installation, and rollback are handled;
- how failures, uncertainty, and missing tooling are reported.

The human user is the release authority. Automated tests, passing builds, and
reviewer sign-off are prerequisites, never authorizations. The 0.11.0 incident
— where a build was installed to the production app after "READY FOR
DEVELOPMENT VALIDATION" but before an explicit install approval, and the first
install crashed on the real on-disk store — is the motivating example this
document exists to prevent.

---

## 2. Operating principles

- **Inspect before editing.** Read the affected code, persistence, and tests
  before proposing changes.
- **Specifications and acceptance criteria are the source of truth**, not the
  implementation.
- **Do not claim success for commands that were not executed.** Report the exact
  command and its real output.
- **Automated tests do not replace human feature validation.** They are
  necessary, not sufficient.
- **Human development approval does not remove the need for release
  verification.** Approval starts release *preparation*; it is not install
  authorization.
- **Passing builds do not prove persistence or migration safety.** In-memory
  test containers can mask on-disk store-open failures (this is exactly what
  happened in 0.11.0).
- **Never assume a current backup exists.** Confirm it (see §14).
- **Never overwrite the installed application without preserving a named
  rollback copy** (see §17).
- **Never deploy merely because implementation is complete.**
- **Keep changes focused on the requested scope.** Do not bundle unrelated
  refactors.
- **Do not silently weaken, skip, or delete tests to obtain a green result.**
- **Do not conceal limitations or unverified behavior.** State them.
- **Prefer reversible operations.** Copy before replace; move-aside before
  overwrite.
- **Report exact commands and results.**

---

## 3. Workflow states

Every work item is in exactly one state. Do not skip states.

### DISCOVERY
- **Entry:** a request is received.
- **Permitted:** reading code, docs, tests, persistence, git history; Explore
  subagents.
- **Exit:** the affected domain, persistence, UI, and tests are identified.
- **Approval:** none.

### SPEC READY
- **Entry:** complexity warrants a written spec, or a concise inline spec is
  drafted.
- **Permitted:** writing `docs/specs/<feature>.md` or an inline spec; defining
  acceptance scenarios and non-goals.
- **Exit:** behavior, data implications, migration, UI states, accessibility,
  acceptance scenarios, non-goals, tests, and rollback implications are
  documented.
- **Approval:** user review of the spec is recommended for non-trivial changes.

### IMPLEMENTING
- **Entry:** spec/plan accepted (or change is trivially small).
- **Permitted:** editing production code, migrations, fixtures, tests; running
  narrow targeted checks.
- **Exit:** the coherent change compiles and targeted tests pass.
- **Approval:** none.

### AUTOMATED VERIFICATION
- **Entry:** implementation slice is coherent.
- **Permitted:** running the real build + test commands in §8.
- **Exit:** Debug build succeeds; full serial suite passes; focused suites for
  touched areas pass; `git diff --check` clean; Domain `Double`/`Float` guard
  clean.
- **Approval:** none.

### INDEPENDENT REVIEW (first gate — see §9)
- **Entry:** automated verification passes.
- **Permitted:** a fresh-context reviewer attempts to invalidate readiness.
- **Exit:** all BLOCKING findings resolved; IMPORTANT findings resolved or
  explicitly justified; affected tests rerun.
- **Approval:** none (reviewer reports findings; primary agent resolves).

### READY FOR DEVELOPMENT VALIDATION
- **Entry:** automated verification + first independent review pass.
- **Permitted:** reporting readiness to the user with the §23 template; nothing
  release-related.
- **Exit:** the user explicitly approves (→ APPROVED FOR RELEASE) or reports a
  problem (→ DEVELOPMENT VALIDATION FAILED).
- **Approval:** **user only.** This state does **not** authorize release prep,
  PR, build, or install.

### DEVELOPMENT VALIDATION FAILED
- **Entry:** the user reports a functional, visual, or workflow problem.
- **Permitted:** record the issue, compare to spec, return to DISCOVERY or
  IMPLEMENTING.
- **Exit:** fix implemented, automated verification + first review rerun, a new
  READY FOR DEVELOPMENT VALIDATION report.
- **Approval:** none.

### APPROVED FOR RELEASE
- **Entry:** an explicit user message confirms the feature works in the
  development environment (see §11).
- **Permitted:** beginning release preparation.
- **Exit:** → RELEASE PREPARATION.
- **Approval:** **user only, explicit.**

### RELEASE PREPARATION
- **Entry:** explicit approval.
- **Permitted:** final diff review, commit scoping, PR, version bump,
  CHANGELOG/About, build, second independent review (§13), backup confirmation
  (§14).
- **Exit:** PR open, required checks pass, backup confirmed, release `.app`
  built and validated, rollback plan ready.
- **Approval:** none until READY TO INSTALL.

### READY TO INSTALL
- **Entry:** release preparation complete.
- **Permitted:** presenting the install plan to the user.
- **Exit:** explicit install approval → INSTALLED; or BLOCKED.
- **Approval:** **user only, explicit and separate from release approval.**

### INSTALLED
- **Entry:** new `.app` installed, prior app preserved, smoke checks pass.
- **Permitted:** reporting installation + rollback status.
- **Exit:** user accepts, or a smoke failure → ROLLED BACK.
- **Approval:** user validation of the installed release.

### ROLLED BACK
- **Entry:** install or smoke failed.
- **Permitted:** restore prior `.app` (+ compatible data backup if needed),
  minimal rollback smoke check, report.
- **Exit:** return to IMPLEMENTING with the failure evidence.
- **Approval:** none.

### BLOCKED
- **Entry:** a required condition cannot be established safely (e.g., backup
  cannot be confirmed, migration reversibility unproven, a command cannot run).
- **Permitted:** report the blocker and the exact missing condition; stop.
- **Exit:** user provides the decision/information.
- **Approval:** **user.**

---

## 4. Feature execution loop

1. Read repository instructions (`AGENTS.md`, `CLAUDE.md`, `README.md`, this
   file, relevant `specs/` and `docs/specs/`).
2. Restate the requested behavior.
3. Inspect the current implementation (affected domain, persistence, UI, tests).
4. Identify affected subsystems and existing utilities to reuse — avoid new code
   when suitable implementations exist.
5. Write or update a focused specification when complexity warrants it
   (`docs/specs/<feature>.md`).
6. Define acceptance scenarios and non-goals.
7. Produce a plan grounded in real files.
8. Implement the smallest coherent change.
9. Run targeted tests during implementation (focused `-only-testing` suites).
10. Run the complete required verification suite (§8).
11. Conduct the first independent readiness review (§9).
12. Fix findings and repeat verification.
13. Report `READY FOR DEVELOPMENT VALIDATION` (§10/§23).

The loop repeats until acceptance criteria are met, required commands pass, and
the first independent review has no unresolved BLOCKING findings. If repeated
attempts are not converging, **stop and report the blocker** — do not cycle
indefinitely.

---

## 5. Specification standard

A sufficient feature spec normally includes:

- problem statement
- current behavior
- desired behavior
- product decisions (with rationale)
- domain invariants
- persistence effects
- migration behavior (including idempotency and reversibility)
- UI states (including error and empty states)
- accessibility
- acceptance scenarios
- non-goals
- tests
- release and rollback implications

Small changes may use a concise inline spec, but behavioral clarity must not be
skipped because the change appears small. Existing examples:
`docs/specs/household-settlement-explicit-inclusion.md`,
`specs/household-settlement-allocations.md`.

---

## 6. Planning standard

Plans must identify:

- concrete files or subsystems
- ordering and dependencies
- data-model changes
- migration needs (and whether they are checksum-affecting — see §19)
- test additions
- UI validation needs (and that there is no UI test harness — see §8)
- release risks
- rollback constraints

Plans must be project-specific, not generic checklists.

---

## 7. Implementation loop

1. Make a coherent change.
2. Compile or run the narrowest relevant check (focused suite or Debug build).
3. Inspect the actual failure.
4. Fix the cause, not merely the symptom.
5. Add or update tests.
6. Re-run targeted checks.
7. Move to the next coherent slice.

Preserve unrelated local changes; review `git diff` regularly. Do not use broad
destructive cleanup commands (`git checkout .`, `git reset --hard`,
`git clean -fd`, wholesale `rm`) merely to obtain a clean tree — they can
destroy the user's uncommitted work. If the tree has unrelated dirty files,
report them and exclude them from commits.

---

## 8. Automated verification matrix

All commands require the Xcode 26 toolchain prefix:
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

| Check | Exact command | When required | Expected | Blocking | Limitation |
|---|---|---|---|---|---|
| Project regen | `xcodegen generate` | After adding/moving/deleting any `.swift`, or editing `project.yml` (AD-005) | `Created project at ...FinanceTracker.xcodeproj` | Yes (before build if files changed) | None |
| Debug build | `DEVELOPER_DIR=…/Developer xcodebuild -project FinanceTracker.xcodeproj -scheme FinanceTracker build` | Every implementation slice | `** BUILD SUCCEEDED **` | Yes | Produces `FinanceTracker Dev` (dev bundle id) |
| Release build | `… xcodebuild -project FinanceTracker.xcodeproj -scheme FinanceTracker -configuration Release build` | Release prep | `** BUILD SUCCEEDED **` | Yes (release) | Produces `FinanceTracker.app` (prod bundle id) |
| Build for testing | `… xcodebuild build-for-testing -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests -destination 'platform=macOS'` | When iterating on tests | `** TEST BUILD SUCCEEDED **` | No | Not documented in AGENTS/README but valid |
| Full serial suite | `… xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests -destination 'platform=macOS' -parallel-testing-enabled NO` | Before READY FOR DEVELOPMENT VALIDATION and before release | `Test run with N tests … passed` / `** TEST SUCCEEDED **` | Yes | **`-parallel-testing-enabled NO` is mandatory** — parallel runs hang on PDFKit/Vision teardown |
| Focused suite | `… xcodebuild test … -only-testing:FinanceTrackerTests/<Suite>` (then `-parallel-testing-enabled NO`) | During implementation for touched areas | pass | Yes for touched areas | Swift Testing `@Suite` struct name, e.g. `HouseholdSettlementReportTests` |
| Domain money guard | `grep -rnE "\b(Double|Float)\b" FinanceTracker/Domain/ \| grep -vE "NSDecimal\|doubleValue\|//"` | Before READY FOR DEVELOPMENT VALIDATION | no output | Yes | **No `.swiftlint.yml`, no pre-commit hook** — AD-007 is a convention, not enforced. This grep is the manual guard. |
| Whitespace guard | `git diff --check` | Before any commit | clean | Yes | None |

**What does NOT exist (state explicitly, do not fabricate):**

- **No CI.** There is no `.github/workflows`, no `.gitlab-ci.yml`, no other CI.
  All validation is local and manual. There is no `npm run verify` or
  equivalent. "CI passed" cannot be claimed — there is no CI.
- **No lint/format tooling.** No `.swiftlint.yml`, no SwiftFormat, no active
  pre-commit hook. Formatting is by convention only.
- **No UI/integration/E2E test target.** `FinanceTrackerUITests/` exists but is
  **empty and not a build target**. There are no automated UI tests. Behavior
  that requires the live UI must be validated manually by the user (§10/§11).
- **No install/archive/export script.** Build + install is manual shell (§16/§17).

**Focused suites worth naming (real, verified to exist):**
`HouseholdSettlementReportTests`, `HouseholdSettlementPresenterTests`,
`BackupArchiveTests`, `CategoryRepairTests`, `NormalizerTests`,
`DashboardPeriodFilteringTests`, `DashboardInsightBuilderTests`,
`NetWorthCompositionTests`, `RetirementSemanticsTests`. (Note: README mentions
`DashboardSnapshotTests`, which does **not** exist — a known doc inaccuracy.)

---

## 9. First fresh-context review gate (development readiness)

Conducted **immediately before** reporting READY FOR DEVELOPMENT VALIDATION.

The reviewer must be a **different reasoning thread** than the implementer when
subagents are available. The reviewer receives only:

- the feature specification
- acceptance criteria
- relevant repository instructions (`AGENTS.md`, this file, applicable `specs/`)
- the **final diff** (the actual diff, not a summary)
- changed-files list
- automated test results
- the minimum architecture context needed to inspect the change

The reviewer must **not** receive the implementer's claim that the work is
correct, private reasoning, or a persuasive justification of implementation
decisions.

The reviewer behaves **adversarially**. Suggested prompt:

> Attempt to prove that this change is not ready. Compare the implementation
> against the specification, inspect the diff and tests, and report concrete
> findings with severity and evidence.

Inspect for: missing acceptance criteria; incorrect product semantics;
regressions; duplicated domain logic; persistence mistakes; unsafe migration;
Decimal/money errors; stale state; UI states not covered; accessibility
regressions; misleading copy; incomplete tests; tests that validate
implementation details rather than behavior; hidden assumptions; changes
outside scope.

Classify findings: **BLOCKING**, **IMPORTANT**, **NON-BLOCKING**, **QUESTION**.

- All BLOCKING findings must be resolved.
- IMPORTANT findings must be resolved or explicitly justified before handoff.
- After fixes, rerun affected tests; repeat the review when changes are
  material.

For changes affecting stored user data, migrations, backups, exact monetary
calculations, or compatibility with older app versions, also engage a
**specialized data reviewer** (§21).

---

## 10. Development handoff report

When the feature is ready for the user to test, return a report containing:

- **status:** `READY FOR DEVELOPMENT VALIDATION`
- concise behavior summary
- affected areas
- any migration or seeded-data behavior
- exact commands executed
- exact test results (suite name + pass/fail counts; build status)
- review findings and their disposition
- known limitations
- focused manual test steps
- behavior the user should pay special attention to

The agent must **not**, at this stage:

- create the release commit solely because tests pass
- build the Release `.app`
- install or replace the application
- assume user approval
- label the feature released

Wait for explicit user validation (§11).

---

## 11. Human development validation gate

Release preparation begins **only** after an explicit user message confirming
the feature works sufficiently in the development environment.

Sufficient approval (examples):

- "It works; prepare the release."
- "Approved. Create the PR and install it."
- equivalent explicit authorization

**Ambiguous** comments, screenshots, questions, or partial approval are **not**
release authorization. "Looks good to me" posted during a *validation* step is
approval to proceed; the same phrase posted while still reviewing is not. When
unclear, ask.

If the user reports a problem:

1. Record the observed behavior.
2. Compare it with the spec.
3. Reproduce or reason from evidence (systematic debugging — do not guess).
4. Return to implementation.
5. Rerun automated verification.
6. Repeat the first independent review (§9).
7. Return a new READY FOR DEVELOPMENT VALIDATION report.

### Separate authorization gates

There are three distinct authorization gates. Treat them as independent; **none
automatically implies the others** unless the user's wording clearly authorizes
multiple.

- **Approval to begin release preparation** — explicit message authorizing the
  release-prep loop (§12): version bump, CHANGELOG/About, commit, PR, build.
  This is the gate §11 describes.
- **Approval to install** — a separate explicit message authorizing replacement
  of the installed production app (§17). Backup confirmation (§14) and the
  second review (§13) must be complete first. "Prepare the release" is **not**
  install approval.
- **Approval to merge the PR** — a separate explicit message authorizing merge
  of the PR into `main` (§15). The PR may be opened during release prep, but
  merging is its own decision and should normally follow successful installation
  + user validation of the installed build.

When the user's wording clearly authorizes multiple gates at once (e.g.
"Approved — create the PR, install it, and merge it"), proceed through each in
its documented order, still satisfying every precondition (backup confirmation,
reviews, artifact identity) before the install and merge steps. When unclear,
ask.

---

## 12. Release preparation loop

After explicit approval:

1. Re-read the approved scope.
2. Inspect the full final diff (`git diff`).
3. Confirm no unrelated files are included; preserve unrelated dirty files.
4. Re-run required automated checks (§8) against the final tree.
5. Review persistence and migration implications (§14/§19).
6. Determine backward-compatibility with the previous installed app.
7. Confirm version/build-number requirements (`project.yml`
   `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`).
8. Update `CHANGELOG.md` (move `[Unreleased]` → `## [X.Y.Z] - YYYY-MM-DD`) and
   `SettingsView.latestReleaseHighlights` (3–5 product-facing bullets).
9. Prepare coherent commit(s) (§15).
10. Create the Pull Request using repository conventions (base `main`,
    `release/X.Y.Z` branch).
11. Ensure the PR description includes: problem, implemented behavior,
    migration/data impact, tests, manual validation, backup requirements,
    installation plan, rollback plan.
12. There is no CI (§8) — "required checks" means the local serial suite +
    Release build run by the agent.
13. Conduct the second fresh-context review (§13).
14. Resolve findings.
15. Obtain backup confirmation (§14).
16. Build the release `.app` (§16).
17. Validate the produced bundle (§16).
18. Preserve the currently installed application (§17).
19. Install the new application (§17).
20. Perform smoke checks (§18).
21. Report installation and rollback status (§23).

Do not combine these into an opaque "deploy" action.

---

## 13. Second fresh-context review gate (release/PR)

Distinct from the development-readiness review (§9). Conducted on the final
release candidate. The reviewer receives:

- approved feature specification
- final PR diff
- commit list
- test/build results
- migration details
- release build configuration
- data storage location and compatibility assumptions
- backup plan
- installation plan
- rollback plan

Review specifically for:

- mismatch between user-approved behavior and the final diff
- last-minute changes made after development validation
- uncommitted or excluded required files
- accidental unrelated files
- migration reversibility (see §19 — additive-optional/column-reuse rules)
- old-app/new-data incompatibility
- destructive schema behavior
- missing backup confirmation
- incorrect application destination (`~/Applications`, not `/Applications`)
- invalid signing/entitlements
- wrong version/build number
- inability to distinguish installed versions
- incomplete rollback instructions
- unsafe replacement order
- smoke checks that do not exercise the changed area

All release-blocking findings must be resolved before installation. If the
final diff changes materially after this review, rerun the relevant release
review.

---

## 14. Backup confirmation gate

**Real data location** (production, sandboxed):

```
~/Library/Containers/com.financeTracker.app/Data/Library/Application Support/default.store
~/Library/Containers/com.financeTracker.app/Data/Library/Application Support/default.store-wal
~/Library/Containers/com.financeTracker.app/Data/Library/Application Support/default.store-shm
```

(All three files are the store set. Backups also appear at the host-level
`~/Library/Application Support/FinanceTracker/Backups/` and inside the container
at `…/Application Support/FinanceTracker/Backups/`.)

**Real backup mechanism:** `.ftbackup` folder bundles written by
`BackupScheduler` (24h gate on launch; retention 7 daily / 4 weekly / 12
monthly) and by manual export from Settings. Format: `Info.plist` +
`manifest.json` (`schemaVersion: Int`, currently 6) + `models/*.json` +
`statements/*`. Restore strategies: `replaceAll`, `mergeKeepingNewer`.

Before installing a release that reads or writes user data:

- verify through available tooling that a current backup exists, **or**
- ask the user explicitly to confirm that a current backup exists.

Record the confirmation (path + timestamp + manifest schemaVersion + that it is
newer than the last data change) in the release report.

**Backup status is a hard precondition to installation.** The order is
unambiguous and must not be reordered:

1. verify/confirm a current **compatible** backup (§14);
2. validate the release artifact (§16);
3. preserve the rollback app (§17);
4. install (§17).

**No app replacement may happen while backup status is unresolved.** If a
compatible backup cannot be confirmed, the release is BLOCKED before any
artifact validation or preservation step.

**Do not infer that a backup exists because:**

- a backup feature exists
- an old backup file is present
- Time Machine may be enabled
- the user previously created a backup
- the data directory exists

Per `AGENTS.md:47`, a release is blocked unless a fresh, verifiable `.ftbackup`
exists and its timestamp is later than the last production data change. If this
cannot be confirmed, **do not release**.

**Migration caveat (critical):** if the change includes a migration that could
make the old application unable to correctly read the new data (schema-version
change, or column repurposing — see §19), copying the old `.app` back alone is
**not** a complete rollback. Rollback then requires **both**:

- the previous `.app`
- a compatible pre-migration data backup (restored via `replaceAll`)

Mark the release BLOCKED until this risk is understood and acknowledged, and
until app-only rollback is either proven safe (e.g., the 0.11.0 guarded binary
test) or explicitly not required.

---

## 15. Commit and Pull Request protocol

Derived from actual repository practice.

- Inspect `git status --short` and both staged/unstaged `git diff` before
  committing.
- Avoid committing unrelated user work; report and exclude dirty files.
- Use meaningful conventional-commit prefixes observed in history: `feat:`,
  `fix:`, `test:`, `docs:`, `chore:`, `refactor:`, scoped variants
  (`feat(dashboard):`), and `perf:` (rare). Release-prep prefixes in history
  are inconsistent (`feat: release`, `release: prepare`, `chore:`) — prefer
  `feat: release X.Y.Z` for the release commit and `docs:`/`test:` for
  follow-ups.
- Include required docs, migrations, tests, and `project.yml`/`project.pbxproj`
  (regenerated) in the commit.
- Push the intended branch (`release/X.Y.Z`).
- Create a focused PR against `main` (merge-commit style is the observed
  convention — PRs #1–#14 all land via merge commits).
- Include verification evidence (exact commands + results) in the PR body.
- **Never claim CI passed** — there is no CI (§8). State the local suite/build
  results instead.
- Record the PR URL in the final report.
- Do not rewrite shared history or force-push unless explicitly authorized.
  Notably: if a release commit corresponds to an **installed** production
  build, do not amend/force-push it without rebuild + retest + reinstall +
  revalidation (the installed artifact must remain traceable to a commit on
  `main`).

Follow `AGENTS.md` "Release Hygiene": `git status --short` reviewed; all
intended changes committed; pushed; PR created; final tree clean except
documented unrelated files; final report includes commit hash, branch, push
status, PR URL, remaining dirty files.

---

## 16. Release `.app` build protocol

Exact build command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project FinanceTracker.xcodeproj -scheme FinanceTracker \
  -configuration Release build
```

The Release product lands in DerivedData at:
`~/Library/Developer/Xcode/DerivedData/FinanceTracker-*/Build/Products/Release/FinanceTracker.app`
(the hash suffix is machine-specific; DerivedData is gitignored).

Validate the produced bundle before install:

- the `.app` exists at the DerivedData Release path
- `CFBundleShortVersionString` (`/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" …/Info.plist`) equals the intended `MARKETING_VERSION`
- `CFBundleVersion` equals the intended `CURRENT_PROJECT_VERSION` (date-based
  `YYYYMMDD.N`)
- `CFBundleIdentifier` == `com.financeTracker.app` (Release; **not** `.dev`)
- executable present at `Contents/MacOS/FinanceTracker`; architecture arm64
  (`file …/MacOS/FinanceTracker`)
- code-signing: `codesign -dv <app>` (ad-hoc; `TeamIdentifier=not set`,
  `flags=0x2(adhoc)` is expected for this project) and
  `codesign --verify --deep --strict <app>` passes
- entitlements: sandbox on, user-selected read-write, network client
  (`FinanceTracker/FinanceTracker.entitlements`)
- no obvious packaging errors

Do **not** treat a Debug build (`FinanceTracker Dev`, bundle id
`com.financeTracker.app.dev`) as a release artifact. The Debug configuration is
for development only.

### Artifact-to-commit immutability

The installed production artifact must correspond **exactly** to the reviewed PR
commit. Any change to that commit after the artifact is built invalidates the
artifact. This includes: amend, rebase, force-push, conflict resolution, or any
source/project change — even if the diff looks equivalent.

If any such change occurs, the artifact is no longer valid and the following
must repeat before that (or a replacement) artifact is installed:

- relevant independent re-review (§9 and/or §13, scoped to the change);
- required tests (§8 — at minimum the affected focused suites + full serial
  suite);
- Release rebuild (§16);
- artifact identity validation (§16 validation list);
- reinstall if the changed artifact is intended for production, with the
  preserved rollback app still in place.

In particular, do **not** amend or force-push a release commit that corresponds
to an already-installed production build without rebuild + retest + reinstall +
revalidation. The installed bundle must remain traceable to a commit on `main`.

---

## 17. Safe application replacement protocol

Production install path: `~/Applications/FinanceTracker.app` (the user's home
Applications, **not** system `/Applications`).

1. Determine the currently installed app path (`~/Applications/FinanceTracker.app`).
2. Confirm it is **not running**, terminating **gracefully first**:
   - request normal termination:
     `osascript -e 'tell application "FinanceTracker" to quit'`;
   - wait and verify exit: `pgrep -fl FinanceTracker` (expect none) after a short
     wait; repeat once if still alive;
   - use forced termination **only as a fallback** if graceful quit does not
     exit: `pkill -f "Applications/FinanceTracker.app"`;
   - **report when forced termination was necessary** (it can indicate the app
     was hung or mid-write — investigate before replacing the bundle).
   Do not proceed to replacement while the app is still running, and do not
   present `osascript` and `pkill` as an unconditional combined step.
3. Identify the installed version/build (`PlistBuddy … CFBundleShortVersionString`
   and `CFBundleVersion`).
4. **Preserve** the current `.app` under an unambiguous rollback name:
   `~/Applications/FinanceTracker-<oldversion>.app` (e.g.
   `FinanceTracker-0.10.0.app`). Use `mv` (preserves the bundle). The name must
   include app name + previous version/build.
5. Verify the rollback bundle exists **before** placing the new app.
6. Copy the new Release `.app` to `~/Applications/FinanceTracker.app`:
   `cp -R <DerivedData>/…/Release/FinanceTracker.app ~/Applications/FinanceTracker.app`.
7. Verify the installed bundle matches the intended artifact: version, build,
   bundle id, arch, `codesign --verify --deep --strict` OK.
8. Launch when appropriate: `open ~/Applications/FinanceTracker.app`.
9. Run smoke checks (§18).
10. Preserve the rollback bundle until the user decides it is no longer needed.
    Do **not** auto-delete it.

Avoid any order that destroys the only known-good application before the new
bundle is validated. Prefer `mv` (reversible) over `rm` for the prior app, and
`trash` (not `rm`) for any disposable test artifacts.

---

## 18. Smoke validation

A small release smoke suite, based on the real app:

- the application launches (process appears, no immediate crash)
- no immediate migration or decoding failure (check
  `~/Library/Logs/DiagnosticReports/FinanceTracker*` for new crash reports and
  `log show --predicate 'process=="FinanceTracker"'` for fatal/error lines)
- expected data opens (the store at the container path loads; transaction count
  is non-zero/plausible)
- primary navigation works (sidebar switches)
- the changed feature opens and one critical approved behavior is observable
- the app can be closed and reopened
- data persists across the close/reopen when the feature requires persistence

Smoke testing is **not** a substitute for the user's earlier development
validation. It only confirms the install did not break launch/data.

---

## 19. Rollback loop

Rollback conditions:

- the app does not launch
- data cannot be read
- a migration fails (watch for `fatalError("Failed to open FinanceTracker
  store: …")` at `FinanceTrackerApp.swift:17`)
- a critical feature regresses
- the installed artifact is incorrect (wrong version/build/bundle id)
- signing or permissions fail
- a smoke check fails

Rollback steps:

1. Stop the new application, **gracefully first** (`osascript … quit`; wait and
   verify exit; `pkill` only as a fallback; report if forced).
2. Preserve logs/error evidence when safe (crash reports, `log show`).
3. Remove/rename the failed installed bundle (`trash` or `mv` to a failed name;
   do not `rm`).
4. Restore the previous versioned `.app` (`mv ~/Applications/FinanceTracker-<old>.app ~/Applications/FinanceTracker.app`).
5. **Restore compatible data when a migration requires it** (see below).
6. Launch the prior version.
7. Perform a minimal rollback smoke check.
8. Report what failed and what was restored.

**Migration/data rollback safety (the 0.11.0 lesson):**

FinanceTracker uses an explicit SwiftData `SchemaMigrationPlan`
(`AppSchema.swift`) ending at V5 (`Schema.Version 0.8.0`). Two constraints
govern schema changes:

1. **Additive-optional properties are checksum-neutral under this plan.** Adding
   a new optional persisted property cannot get its own `VersionedSchema` stage
   — SwiftData raises "Duplicate version checksums detected." Redefining the
   terminal (V5) model in place instead fails to reopen existing on-disk stores
   (the store's recorded model hash mismatches the redefined model) →
   `fatalError` at launch. This is why 0.11.0 repurposed the unused
   `settlementPaidByRaw` column for `householdScope` rather than adding a new
   property. Verified in code at `Transaction.swift:26-32` and `CHANGELOG.md`
   (0.11.0).
2. **Column repurposing makes app-only rollback semantically unsafe.** Once a
   newer app writes new meaning into an existing column (e.g.
   `settlementPaidByRaw` now holds `included`/`excluded`; `customPartnerPercent`
   now holds an exact currency amount for `.custom` rows), an older binary will
   misread those columns.

Therefore:

- **Never assume app rollback also rolls back data.** App-only rollback
  sufficiency must be **proven** (the 0.11.0 release-safety checks proved
  0.10.0 can open a 0.11.0-written store) or it must not be claimed.
- When app-only rollback is unproven or a schema-version change occurred,
  rollback requires **both** the previous `.app` **and** a compatible
  pre-migration `.ftbackup` restored via `replaceAll`.
- Any schema/model change must include: backup first, focused
  reset/dashboard/persistence coverage, the full serial suite, a changelog
  entry, and a documented rollback path (`specs/release-checklist.md`).

**The live store is never the first migration test.** Required order:

1. an **automated migration fixture** (a focused test that builds/migrates a
   store through the relevant `VersionedSchema` stages);
2. a **disposable copy of representative historical or production data**
   (copied, never the live store), opened migrated, and verified — the 0.11.0
   store-open probe against a production-store copy is the model;
3. **live installation only after both pass and the user explicitly authorizes
   it.**

In-memory containers can mask on-disk migration failures (the 0.11.0 root
cause); an on-disk copy test is required before any live install of a change
that touches persistence.

**Column repurposing is an exceptional compatibility technique, not a default
migration strategy.** It is justified only when a normal `VersionedSchema`
migration is provably impossible (as with additive-optional checksum
neutrality above) and the repurposed column is verified unused for its original
purpose. Any column repurposing must document:

- old and new semantics;
- possible legacy values that may exist in production stores;
- backup behavior (how the column round-trips; how restore handles legacy
  values);
- old-app/new-data compatibility (can the previous binary read the new values
  without corruption?);
- rollback consequences (does rolling back the app misread the column?);
- test coverage (legacy-nil, legacy values, new values, old-backup restore,
  new-backup round-trip, merge explicit-wins).

The 0.11.0 `settlementPaidByRaw` → `householdScope` repurpose is the example:
documented at `Transaction.swift:26-32`, `BackupArchive.swift` (scope-deriving
restore), and `BackupArchiveTests` (`scopeValuesRoundTrip`,
`legacySettlementPaidByRawNotMisreadAsScope`, `mergePreservesExplicitScope`).

When in doubt, mark the release BLOCKED and ask the user.

---

## 20. Failure protocol

When a command fails:

- report the exact failed command
- report the meaningful error (not the whole log)
- identify whether it is caused by the change, the environment, or uncertainty
- do not mark the stage complete
- fix and rerun when safe
- escalate instead of guessing when user input or credentials are required
- if a test runner wedges (the known PDFKit/Vision teardown hang), kill stale
  `xcodebuild`/`xctest`/`FinanceTracker Dev` processes, clean DerivedData and
  the dev container, and rerun serially

If a required check cannot run in the current environment, state what remains
unverified and whether it blocks development validation or release.

---

## 21. Subagent usage

Recommended roles:

- **Explore agent** — architecture, affected-file discovery, persistence
  tracing, test discovery, release-path discovery. Read-only.
- **Implementation agent** — scoped changes following the approved plan.
- **Development-readiness reviewer** — fresh-context reviewer after
  implementation + automated verification (§9).
- **Release reviewer** — fresh-context reviewer on the final PR/release
  candidate (§13).
- **Specialized data reviewer** — use when a change affects stored user data,
  migrations, backups, exact monetary calculations, or compatibility with older
  app versions.

Subagents provide findings; the **primary agent** remains responsible for
reconciling contradictory findings, checking findings against the repository,
implementing fixes, running commands, and making readiness claims. A subagent's
"looks good" is not evidence that tests passed.

---

## 22. Context-isolation protocol for reviewers

"Fresh context" means independence from the implementer's framing — **not** lack
of necessary task information. A reviewer should receive: specification,
acceptance criteria, relevant instructions, the actual diff, tests and results,
and necessary files.

A reviewer should **not** receive: private reasoning, persuasive explanations of
why the implementation is correct, a request to confirm the implementer's
conclusion, or only a summary instead of the actual diff.

Use prompts such as:

> Attempt to prove that this change is not ready. Compare the implementation
> against the specification, inspect the diff and tests, and report concrete
> findings with severity and evidence.

---

## Subagent orchestration policy

Use subagents to divide investigation, implementation, verification, and
release review into independently accountable roles. This expands §21 and §22.

Subagents are preferred when a task involves two or more of:

- persistence or schema changes
- migration or backup compatibility
- exact monetary calculations
- multiple UI surfaces
- navigation or state propagation
- release packaging
- installation or rollback
- a broad diff across unrelated subsystems
- ambiguous repository behavior
- previously observed production failures

The primary agent remains responsible for orchestration, evidence, and the
final readiness claim. A subagent finding is **advisory** until the primary
agent verifies it against the repository, tests, or runtime behavior.

### Recommended subagent topology

#### 1. Architecture explorer
Purpose: trace the current behavior end to end; identify affected models,
services, views, persistence, and tests; find existing conventions and
analogous features; detect hidden coupling before implementation.
Expected output: concrete file map; current data flow; relevant invariants;
risks and unknowns; recommended implementation seams. This agent does not edit
production code.

#### 2. Persistence and migration reviewer
Required when the change affects stored data, backups, schema, migrations, or
rollback compatibility. Purpose: inspect actual store configuration; compare
old and new persistence semantics; identify migration and checksum risks;
evaluate backup restore behavior; evaluate old-app/new-data compatibility;
design tests using historical or real-store copies. This agent should assume
that **in-memory success is insufficient evidence for an on-disk migration**
(the 0.11.0 lesson).

#### 3. Implementation agent
Purpose: implement a clearly scoped part of the approved plan; add focused
tests; report exact files and commands; avoid unrelated cleanup. For large
features, implementation may be split by coherent ownership (e.g. domain and
persistence; calculator and presentation; transaction UI and navigation;
backup and migration tests). Avoid assigning multiple agents to modify the
same files concurrently unless the primary agent has an explicit merge plan.

#### 4. Test and coverage analyst
Purpose: compare acceptance criteria with the existing test matrix; identify
missing behavioral coverage; distinguish unit-testable behavior from manual UI
validation; propose adversarial and regression cases; inspect whether tests
prove behavior rather than implementation details. This agent should not
assume that a passing suite covers the requested feature completely.

#### 5. Development-readiness reviewer
Runs after implementation and automated verification. Must use fresh context.
Purpose: attempt to prove the feature is not ready; compare the complete diff
against the specification; classify concrete findings; challenge persistence,
state, UI, accessibility, and test assumptions. Required finding severities:
**BLOCKING**, **IMPORTANT**, **NON-BLOCKING**, **QUESTION**. The reviewer must
receive the actual diff and test evidence, not only an implementation summary.

#### 6. Release reviewer
Runs on the final PR/release candidate after explicit user approval for release
preparation. Purpose: verify the final diff matches what the user validated;
inspect post-validation changes; validate commit/artifact identity; challenge
backup and rollback claims; inspect version, build, signing, entitlements,
destination, and packaging; ensure installation is not occurring without
explicit authorization. This must be a separate review from development
readiness.

#### 7. Runtime or smoke-test observer
Used when the application can be launched in a controlled environment.
Purpose: launch the built artifact; observe startup and logs; validate
representative data loading; execute a minimal smoke route; report behavior
without changing product code. For migration-sensitive releases, use a
disposable copy of representative historical or production data before
touching the live store (§19).

### Context isolation

Fresh-context reviewers should know: the specification; acceptance criteria;
relevant repository instructions; changed files and actual diff; executed
commands and results; necessary architecture context.

They should not receive: the implementer's private reasoning; persuasive
explanations intended to obtain approval; a request to confirm that the work is
correct; only a summarized version of the diff.

A preferred review prompt is:

> Attempt to prove this change is not ready. Inspect the specification, complete
> diff, tests, persistence behavior, and runtime assumptions. Report concrete
> findings with severity and evidence.

### Parallel exploration

Parallel Explore agents are encouraged when the work decomposes into read-only
investigations. Good splits include: domain and architecture; persistence,
migration, and backup; tests and CI; UI and navigation; release and packaging;
Git and PR conventions. The primary agent must reconcile contradictions before
planning. **Do not merely concatenate subagent reports.**

### Parallel implementation safety

Parallel implementation is allowed only when: ownership boundaries are clear;
file overlap is minimal or nonexistent; shared types and interfaces are agreed
first; each agent receives the same specification; the primary agent reviews
the combined diff; the complete test suite runs after integration.

Avoid concurrent edits to: central models; schema definitions; project files;
shared navigation state; backup formats; the same SwiftUI view hierarchy —
unless there is an explicit coordination strategy.

### Mandatory subagent triggers

At least one independent specialist or reviewer is required when:

- persisted data semantics change
- a migration is introduced
- a storage column is repurposed
- backup format or restore behavior changes
- exact money allocation changes
- the release may affect rollback compatibility
- a prior production incident exposed a gap in current tests
- the primary agent encountered contradictory evidence
- installation or data replacement is being prepared

### Orchestrator responsibilities

The primary agent must: define each subagent's scope; prevent overlapping
edits; provide the correct evidence; reconcile conflicting conclusions; verify
claims independently; integrate changes; rerun required checks on the combined
tree; make the final readiness report; preserve all human approval gates.

Subagents cannot authorize: development approval; release preparation;
installation; merge; deletion of rollback artifacts. Those remain with the
human release authority.

### Failure and escalation

If subagents disagree: identify the precise disputed claim; inspect the source
code or runtime evidence; run a focused experiment when safe; prefer observed
behavior over assumptions; report unresolved uncertainty instead of voting by
majority.

If a subagent discovers a BLOCKING issue, the workflow returns to
implementation or discovery. It does **not** advance merely because other
agents reported no issues.

---

## 23. Standard reports and templates

### Implementation start
- understood request
- discovered architecture (real files)
- planned files
- risks (persistence/migration/UI-validation)
- verification plan (which §8 commands)

### Ready for development validation
- status: `READY FOR DEVELOPMENT VALIDATION`
- implemented behavior
- exact commands executed
- exact results (suite + counts; build)
- review findings + disposition
- manual validation steps
- known limitations

### Development feedback received
- observed issue
- expected behavior
- likely affected area
- next verification steps

### Release preparation
- approval evidence (the explicit user message)
- final diff scope
- commit/PR status (hash, branch, PR URL)
- CI status: **N/A — no CI**; report local serial suite + Release build results
- backup status (path + timestamp + manifest schemaVersion + newer-than-last-change)
- build status (Release product validated per §16)
- install plan
- rollback plan (and whether app-only rollback is proven)

### Installed release
- installed version/build
- installation path
- previous-app rollback path/name
- backup confirmation
- smoke checks performed + results
- PR/commit reference
- remaining follow-up

### Blocked release
- blocker
- completed checks
- unverified requirement
- user decision/information required

---

## 24. Prohibited shortcuts

- releasing before explicit user approval
- describing a feature as released when only a development build exists
- assuming backups (see §14)
- installing over the only copy of the previous `.app` without a named rollback
- silently omitting failed tests
- fabricating unavailable commands (CI, SwiftLint, install scripts — see §8)
- changing acceptance criteria to fit the implementation
- asking a reviewer only to approve
- using the same self-review as the independent gate when subagents are available
- relying exclusively on snapshots or screenshots for domain correctness
- treating a Pull Request as complete before local required checks finish
- automatically deleting rollback bundles
- assuming app rollback also rolls back data (see §19)
- committing unrelated working-tree changes
- force-pushing without authorization, or amending an installed release commit
  without rebuild/retest/reinstall
- deploying from a dirty or unknown tree without explicitly resolving it

---

## Unresolved repository-specific details

- **Git tagging.** `specs/release-checklist.md` documents tagging the validated
  release commit (e.g. `v0.3.0`), but no tags are observed in `git log` /
  `git branch -a`. Tagging is documented intent, **not observed practice**.
  Until a tagging convention is actually adopted, do not claim a release is
  "tagged"; if a tag is wanted, ask the user and record it.
- **CI.** None exists. Treat "required status checks" as the local serial suite
  + Release build run by the agent (§8/§12).
- **Decimal/money lint.** AD-007 (Decimal-only in `Domain/`) is a convention,
  not mechanically enforced (no `.swiftlint.yml`, no pre-commit hook). The
  manual grep in §8 is the guard.
- **UI tests.** No automated UI test target exists. UI behavior is validated
  manually by the user (§10/§11).
