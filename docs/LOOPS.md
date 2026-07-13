# Release & Approval Gates

This document records the approval gates that govern releases and production
installation. It exists to prevent a repeat of the 0.11.0 incident, where a
build was installed to the production app before explicit human approval.

## The gates

1. **"Ready for development validation" does NOT authorize installation.**
   A feature reaching development-validation readiness (tests green, independent
   review passed) is a quality signal, not a release authorization.

2. **Only explicit user approval authorizes RELEASE PREPARATION.**
   Version bump, CHANGELOG, About highlights, branch/PR — these release-prep
   actions begin only after the user explicitly says to prepare a release.

3. **Installation requires a separate explicit gate.**
   Installing/smoke-testing the production app is a distinct, higher-bar step
   that requires its own explicit approval, a fresh verifiable backup, and (per
   `AGENTS.md`) confirmation that the backup is newer than the last data change.

4. **Passing tests and a successful release review do NOT imply approval.**
   Green suites, a passing independent review, and a mergeable PR are
   prerequisites, not authorizations. None of them, alone or together, replace
   the explicit human "install" decision.

## Incident: 0.11.0 installed before approval

The 0.11.0 build (Household explicit inclusion) was installed to
`~/Applications/FinanceTracker.app` after the independent review reported
"READY FOR DEVELOPMENT VALIDATION" and the user approved release *preparation*,
but before an explicit production-install approval gate was recorded. The first
install crashed on launch (an on-disk SwiftData migration issue the in-memory
test suite had masked); the app was rolled back to 0.10.0, the migration path
was fixed and re-verified against a copy of real production data, and 0.11.0
was reinstalled.

Lesson: development-validation readiness and release-preparation approval are
NOT install approval. Treat installation as its own gate, always.

## Rollback note

App-only rollback (reverting the `.app` bundle alone) is only viable if the
older binary can open the post-migration store. If it cannot, rollback requires
BOTH the older `.app` bundle AND a compatible pre-migration data backup
restored via `replaceAll`. App/bundle-only rollback sufficiency must be proven,
not assumed.
