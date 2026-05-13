# SPEC: FinanceTracker — Stages S0 → S3

You are the implementing coding agent. This file is your complete brief.
You do not need to ask the stakeholder anything to execute it; every
decision is recorded below. Where a judgment call exists, the
"non-negotiable" subsections name the rule.

The architect (a prior Claude session) drafted the broader plan at
`/Users/developer/.claude/plans/snazzy-rolling-rose.md`. That plan
covers Stages S0–S4. **This spec scopes you to S0, S1 (local-only,
CloudKit deferred), S2, and S3 plus the leftover housekeeping.** Stage
S4 (new issuer parsers) is explicitly out of scope.

---

## 0. Working agreement

- **No app launches and no app runtime tests.** The stakeholder is
  remote-controlling and a macOS permission prompt will block you.
  `xcodebuild build` and `xcodebuild build-for-testing` are fine;
  `xcodebuild test` is fine (it runs the bundled test process headlessly,
  no Documents permission). Do not call `open …app` or anything that
  would launch the bundled app.
- **Run tests serially.** Use
  `-parallel-testing-enabled NO` on every `xcodebuild test` call. The
  parallel runner intermittently hangs on macOS PDFKit/Vision teardown
  in this repo. CLAUDE.md documents this.
- **Commit per stage.** Each numbered subsection below is one commit
  (sometimes a pair: feature + CHANGELOG). Do not bundle stages into a
  single commit. Use the commit titles supplied at the bottom of each
  subsection verbatim.
- **Co-author trailer.** Every commit message ends with:
  `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`
- **Source-only edits while the stakeholder is away.** Edits, reads,
  `xcodegen generate`, `xcodebuild build`, `xcodebuild test`. Nothing
  else.

If `xcodegen generate` fails, stop and report. If `xcodebuild build`
fails after your change, fix forward; do not commit a broken state.

---

## 1. Repository orientation (read these first)

Don't trust this section blindly. Verify each file exists and is roughly
as described before editing.

| Path | Purpose |
| --- | --- |
| `FinanceTracker/App/FinanceTrackerApp.swift` | `@main` entry. Owns the `.modelContainer(for:)`. Must list all 8 `@Model` types. |
| `FinanceTracker/App/AppContainer.swift` | Holds the full schema list. **Currently dead code** — not instantiated. We're going to make it the source of truth. |
| `FinanceTracker/Domain/Models/Account.swift` | `@Model` Account. Already has `tintHex`, `creditLimit`, `nickname`, `accountNumber`. |
| `FinanceTracker/Domain/Models/Transaction.swift` | `@Model` Transaction. Has `cardLast4`. **Will gain `deletedAt` and `lastModifiedAt`.** |
| `FinanceTracker/Domain/Models/Statement.swift` | `@Model` Statement. Source-file dedup via `sourceFileHash`. |
| `FinanceTracker/Domain/Models/InstallmentPlan.swift` | `@Model` for MSI plans. **Inverse relationship will be loosened** (kept for now since CloudKit is deferred; see §3.4). |
| `FinanceTracker/Domain/Models/Category.swift`, `CategoryRule.swift`, `PendingImport.swift`, `SignRecoveryHint.swift` | Other models. Each will gain `lastModifiedAt`. |
| `FinanceTracker/Features/Dashboard/GlassCard.swift` | Primitive used everywhere. **S0 lives here.** |
| `FinanceTracker/Features/Dashboard/DashboardView.swift` | Owns `SidebarSelection`, drives scope. |
| `FinanceTracker/Features/Dashboard/DashboardViewModel.swift` | Produces `DashboardSnapshot` from `(scope, dateRange)`. **S3 bug lives here at line 91.** |
| `FinanceTracker/Features/Dashboard/AccountIdentity.swift` | Resolves identity color. **S2.3 lives here.** |
| `FinanceTracker/Ingest/Pipeline/IngestPipeline.swift` | `findOrCreateAccount` at lines 408–449. **S2.1 bug lives here.** |
| `FinanceTracker/Features/Settings/SettingsView.swift` | Today only a placeholder. **Grows for S2.2 and S1.2 backup UI.** |
| `FinanceTrackerTests/EndToEndTests/DashboardSnapshotTests.swift` | Stage 3 verification. Extend in S3. |
| `specs/credit-cards.md` | **Has uncommitted edits on disk.** A rewrite pointing at git history. Commit it as part of housekeeping (§7). |
| `specs/backlog.md` | Cross off items as you ship them. |
| `specs/liquid-glass-redesign.md` | Reference only; the chrome layer is already in. |
| `CLAUDE.md`, `DECISIONS.md`, `CHANGELOG.md` | Update after each stage. |

Read the existing AD-009 through AD-014 in `DECISIONS.md` before you
touch anything; many invariants are spelled out there.

---

## 2. Leftover housekeeping (do BEFORE Stage S0)

There are uncommitted edits on disk from the prior session. Resolve
them first so your working tree is clean before you start S0.

### 2.1 — Inspect the uncommitted state

```bash
git status
git diff
```

Two known-clean files should be committed as one chore commit before
anything else:

1. `FinanceTracker/Features/Transactions/TransactionsView.swift` —
   `categoryBadge(for:)` now wraps a `GlassChip` and tints the badge
   text with `CategoryPalette.color(for: cat.name)`. Replaces two
   inline `.glassEffect(.regular, in: .capsule)` calls.
2. `FinanceTracker/Features/Transactions/PendingReviewSection.swift` —
   outer surface now uses `GlassCard(role: .card, interactive: true)`
   instead of an inline `.glassEffect`.
3. `specs/credit-cards.md` — rewritten to point at commit history +
   `DECISIONS.md` AD-009..014. The original OCR-era spec content is
   gone; the file is now a forwarding stub.

If any of these aren't actually present on disk when you start, skip
them. If they're present, commit verbatim with this title and message:

```
chore: finish Liquid Glass migration sweep + retire stale credit-cards spec

- TransactionsView category badges and PendingReviewSection card surface
  now use GlassChip / GlassCard so they share the scopedTint env value
  and pick up the hover specular consistently.
- specs/credit-cards.md is now a forwarding stub. The OCR-era plan it
  used to hold is preserved in git history (2e02fbf onwards). New work
  lives in specs/next-stages.md.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

Verify with `xcodebuild build` after committing.

### 2.2 — Stop here if anything else is uncommitted

If `git status` shows files you don't recognise, stop and report. Do
not blindly stash, reset, or commit unexpected changes.

---

## 3. Stage S0 — Scroll perf fix

**Symptom**: stakeholder reports dashboard and Transactions view feel
"heavy" while scrolling.

**Root cause**: `GlassCard` runs an infinite-loop `.repeatForever`
rotation animation on its specular AngularGradient when hovered, and
because hover state can be triggered transiently during scroll, multiple
cards end up running the animation simultaneously. Each rotating
AngularGradient requires per-frame recomputation by the GPU.

**File**: `FinanceTracker/Features/Dashboard/GlassCard.swift`.

### 3.1 — Replace the rotation animation

In the `.onHover { isHovering in … }` modifier:

- Delete the entire `if isHovering { … } else { … }` block that toggles
  `withAnimation(.linear(duration: 4.0).repeatForever(autoreverses: false))`.
- Replace with a single `withAnimation(.easeInOut(duration: 0.25))`
  toggling `hovered` only; do not touch `rotation` from `.onHover`.
- Set the initial `@State private var rotation: Double = 35` (any small
  static angle that catches light). It never changes; the stroke just
  fades in via opacity bound to `hovered`.

The visible effect: a tinted angular gradient stroke fades in over a
quarter second when the pointer enters, fades out when it leaves. No
movement.

### 3.2 — Acceptance

- `xcodebuild build` clean.
- Search the file for `repeatForever` — must return zero hits.
- A new unit test is NOT required for this change. Visual verification
  is the stakeholder's job; do not block waiting for it.

### 3.3 — Commit

```
perf: drop infinite specular rotation on GlassCard hover

The hover-only AngularGradient stroke now fades in with a 0.25s
easeInOut and holds — no .repeatForever animation. With several
interactive cards on screen (dashboard summary tiles + chart cards +
account sidebar rows in hover-transit during scroll), the prior
rotation kept multiple AngularGradient strokes recomputing every
frame, which scrolled like molasses on the stakeholder's MacBook
Pro M1 Pro.

Static stroke still picks up scopedTint so identity-color cues are
preserved.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

---

## 4. Stage S3 — Interest drill-down empty (real bug)

Doing this before S2 because it's a one-line fix that unblocks the
stakeholder's primary smoke-test loop. (S2 is bigger and depends on
schema changes from S1.)

### 4.1 — The bug

**File**: `FinanceTracker/Features/Dashboard/DashboardViewModel.swift`,
around line 91 in `buildConsolidated`:

```swift
let recent = Array(transactions.prefix(20))
```

This 20-row slice is what `ConsolidatedSnapshot.recentTransactions`
gets. The Interest Earned summary card's `BreakdownRequest.interest(transactions:total:)`
filters that slice. If none of the 20 most-recent transactions are
categorized "Interest", the drill-down is empty even though
`totalInterestEarned > 0`.

The same trap exists in `buildAsset` and `buildLiability` if they pass
prefix-limited arrays into `BreakdownRequest`.

### 4.2 — The fix

In `buildConsolidated`, `buildAsset`, and `buildLiability`:

- Replace `let recent = Array(transactions.prefix(20))` with
  `let recent = transactions` (the full filtered set already returned
  by `windowedTransactions`).
- The "Recent Transactions" panels on the dashboards already call
  `.prefix(10)` at the render site
  (`ConsolidatedDashboard.swift`, `AssetAccountDashboard.swift`,
  `LiabilityAccountDashboard.swift`). Confirm those `.prefix(10)`
  calls are present; do not remove them.
- BreakdownSheet now receives the full set and its `.filter` produces a
  complete answer.

### 4.3 — Tests

Extend `FinanceTrackerTests/EndToEndTests/DashboardSnapshotTests.swift`
with a new `@Test` in the existing suite:

```swift
@Test("Interest Earned drill-down sees all matching transactions, not just recent-20")
func interestDrilldownIsComplete() async throws {
    let container = try makeContainer()
    let context = container.mainContext
    SeedDataLoader.bootstrapIfNeeded(context: context)

    // Build a synthetic account + 25 transactions where only the OLDEST
    // 5 are interest income. The most recent 20 must NOT contain any
    // interest. Confirm the consolidated snapshot still exposes all 5
    // for drill-down.
    let savings = Account(institution: "Synthetic Bank", type: .savings, currency: "MXN")
    context.insert(savings)
    let interestCategory = (try? context.fetch(FetchDescriptor<FinanceTracker.Category>()))?
        .first { $0.name == "Interest" }

    // 5 interest rows, dated 100..96 days ago
    for i in 0..<5 {
        let tx = Transaction(
            account: savings,
            postedAt: .now.addingTimeInterval(TimeInterval(-(100 - i) * 86400)),
            amount: 100,
            currency: "MXN",
            descriptionRaw: "Abono de intereses #\(i)",
            category: interestCategory
        )
        context.insert(tx)
    }
    // 20 expense rows, dated 0..19 days ago
    for i in 0..<20 {
        let tx = Transaction(
            account: savings,
            postedAt: .now.addingTimeInterval(TimeInterval(-i * 86400)),
            amount: -10,
            currency: "MXN",
            descriptionRaw: "Coffee #\(i)"
        )
        context.insert(tx)
    }
    try context.save()

    let viewModel = DashboardViewModel()
    viewModel.dateRange = DateRange(start: .distantPast, end: .distantFuture)
    viewModel.scope = .consolidated
    viewModel.configure(context: context)

    guard case .consolidated(let snap) = viewModel.snapshot else {
        Issue.record("Expected consolidated snapshot"); return
    }

    // Snapshot now carries ALL filtered transactions (25), not just 20.
    #expect(snap.recentTransactions.count >= 25,
            "recentTransactions should hold the full filtered set, got \(snap.recentTransactions.count)")

    // And the interest filter against that set yields all 5 rows.
    let interestRows = snap.recentTransactions.filter {
        $0.category?.name == "Interest" && $0.amount > 0
    }
    #expect(interestRows.count == 5,
            "Expected all 5 interest rows visible to BreakdownSheet, got \(interestRows.count)")
}
```

Run with `-parallel-testing-enabled NO`. All existing tests must still pass.

### 4.4 — Commit

```
fix: pass full filtered transactions to snapshots for accurate drill-downs

DashboardViewModel was passing Array(transactions.prefix(20)) as
ConsolidatedSnapshot.recentTransactions (and same for the asset /
liability variants). That 20-row slice is also what BreakdownSheet
filters when the user taps a summary tile — so any aggregate (Interest
Earned, Income, Expenses, category spending) whose matching rows lay
older than the 20 most-recent transactions rendered an empty sheet.

Snapshots now carry the full filtered set. The dashboards' "Recent
Transactions" panels already cap at .prefix(10) at the render site so
nothing visible changes on the dashboard itself; only the breakdowns
gain the missing rows.

Adds DashboardSnapshotTests.interestDrilldownIsComplete locking the
invariant.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

---

## 5. Stage S2 — Multi-HSBC isolation (real bug + UX)

**Symptom**: the stakeholder has TWO HSBC 2Now accounts (different
physical 16-digit card numbers), each with a main + a digital
sub-account. When pasting statements from both, transactions of the
second HSBC account get merged into the first.

### 5.1 — The bug

**File**: `FinanceTracker/Ingest/Pipeline/IngestPipeline.swift`,
`findOrCreateAccount` at lines 408–449.

Today the function has two lookup steps:

1. Match by `(institution, accountNumber)` — correct.
2. **Fallback**: match by `(institution, type)` ignoring
   `accountNumber`. **This is the bug.**

When the second HSBC card's supplementary section is parsed, step 1
finds no Account with `accountNumber == "2222"` (or whatever the second
account's digital sub-card last4 is), so it falls into step 2, which
returns the FIRST HSBC Account already in the DB and merges card B's
adicional rows into account A.

### 5.2 — The fix

Tighten `findOrCreateAccount` so the fallback only fires when the
parser genuinely did NOT supply a `sectionNumber`. Concretely:

```swift
private func findOrCreateAccount(
    for detection: DetectionResult,
    sectionHint: String?,
    sectionType: AccountType,
    sectionNumber: String?,
    sectionNickname: String?,
    creditLimit: Decimal? = nil
) -> Account {
    let institutionName = detection.issuer.rawValue

    if let number = sectionNumber {
        let descriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> {
                $0.institution == institutionName && $0.accountNumber == number
            }
        )
        if let existing = try? context.fetch(descriptor).first {
            if let cl = creditLimit, existing.creditLimit == nil {
                existing.creditLimit = cl
            }
            return existing
        }
        // sectionNumber was supplied but didn't match anyone — CREATE NEW.
        return createNewAccount(
            institution: institutionName,
            type: sectionType,
            nickname: sectionNickname,
            number: number,
            creditLimit: creditLimit
        )
    }

    // Genuinely no number from the parser. Keep the old fallback so
    // legacy paths (e.g. CSV imports without a per-section number)
    // still reuse the institution+type account.
    let institutionDescriptor = FetchDescriptor<Account>(
        predicate: #Predicate<Account> { $0.institution == institutionName }
    )
    if let existing = (try? context.fetch(institutionDescriptor))?
        .first(where: { $0.type == sectionType }) {
        if let cl = creditLimit, existing.creditLimit == nil {
            existing.creditLimit = cl
        }
        return existing
    }

    return createNewAccount(
        institution: institutionName,
        type: sectionType,
        nickname: sectionNickname,
        number: nil,
        creditLimit: creditLimit
    )
}

private func createNewAccount(
    institution: String,
    type: AccountType,
    nickname: String?,
    number: String?,
    creditLimit: Decimal?
) -> Account {
    let displayName = nickname ?? institution
    Logger.pipeline.info("Auto-creating account for \(displayName) (\(number ?? "no number"))")
    let account = Account(
        institution: institution,
        type: type,
        currency: "MXN",
        nickname: nickname,
        accountNumber: number,
        creditLimit: creditLimit
    )
    context.insert(account)
    return account
}
```

**Risk**: legacy Openbank statements supply a `sectionNumber` per
section (Débito vs Apartado). The first import of a fresh Openbank PDF
will still create one Account per (institution, accountNumber) pair —
unchanged behavior. The Amex parser also supplies a number. Confirm by
running the existing test suite after the change.

### 5.3 — Account.displayName

**File**: `FinanceTracker/Domain/Models/Account.swift`.

Add a computed property — do NOT store it (`nickname` is already
stored):

```swift
var displayName: String {
    if nickname != institution { return nickname }
    if let last4 = accountNumber { return "\(institution) ····\(last4)" }
    return institution
}
```

Replace every `account.nickname` reference inside views with
`account.displayName`. Grep for `.nickname` to find them:

- `FinanceTracker/Features/Dashboard/DashboardView.swift` —
  `AccountSidebarRow` body.
- `FinanceTracker/Features/Dashboard/ConsolidatedDashboard.swift` —
  `accountsList` body.
- `FinanceTracker/Features/Dashboard/DashboardChrome.swift` —
  `DashboardTransactionRow`.
- `FinanceTracker/Features/Dashboard/BreakdownSheet.swift` — the
  accountsBreakdown rows and the per-transaction nickname tag.
- `FinanceTracker/Features/Transactions/TransactionsView.swift` — the
  account filter Picker and any in-row label.

Do NOT change `Account.nickname` itself; users can still set it
manually and `displayName` will prefer that.

### 5.4 — AccountIdentity auto-distinguishes same-institution accounts

**File**: `FinanceTracker/Features/Dashboard/AccountIdentity.swift`.

Today `color(for:)` returns the same `HSBC red` for every HSBC 2Now
account. Add a deterministic auto-shifter so two HSBC accounts show
two visibly different reds:

```swift
static func color(for account: Account?) -> Color {
    guard let account else { return consolidated }
    if let hex = account.tintHex, let c = Color(hex: hex) { return c }
    let base = defaultMap[account.institution] ?? .accentColor
    return shiftedHue(of: base, by: hueOffset(for: account))
}

/// Deterministic hue offset in degrees, derived from the account's UUID so
/// two accounts of the same institution land on visibly distinct hues. The
/// offset is zero for the first account of any institution (stable colors
/// for single-account users).
private static func hueOffset(for account: Account) -> Double {
    // Use the first byte of the UUID for cheap dispersion across [-20°, +20°].
    let byte = account.id.uuid.0
    let scaled = (Double(byte) / 255.0) - 0.5    // ~[-0.5, 0.5]
    return scaled * 40                            // ±20°
}

private static func shiftedHue(of color: Color, by degrees: Double) -> Color {
    #if os(macOS)
    let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? .controlAccentColor
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    nsColor.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    let newHue = (h + CGFloat(degrees / 360.0)).truncatingRemainder(dividingBy: 1)
    let normalized = newHue < 0 ? newHue + 1 : newHue
    return Color(nsColor: NSColor(hue: normalized, saturation: s, brightness: b, alpha: a))
    #else
    return color
    #endif
}
```

This is intentionally deterministic-but-stable: a given Account UUID
always picks the same shift; users who never run multiple accounts of
one institution see the original color unchanged most of the time.

### 5.5 — Settings UI: nickname + tint editor

**File**: `FinanceTracker/Features/Settings/SettingsView.swift`.

Today this is a placeholder. Replace its body with a Form that lists
every Account and allows editing per-account:

- `TextField("Nickname", text: $account.nickname)` — bound directly to
  the @Model property; SwiftData persists on the next runloop.
- `ColorPicker("Identity color", selection: …)` — for the color
  serialisation, render and parse via the existing `Color(hex:)`
  initializer in `AccountIdentity.swift`. Store as `account.tintHex`.
  Use a small helper to convert a `Color` to `#RRGGBB`:

```swift
private extension Color {
    /// Best-effort hex serialisation for ColorPicker round-tripping.
    var hexString: String {
        #if os(macOS)
        let ns = NSColor(self).usingColorSpace(.deviceRGB) ?? .controlAccentColor
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
        #else
        return "#000000"
        #endif
    }
}
```

- `TextField("Credit limit", value: $account.creditLimit, format: .currency(code: account.currency))`
  — only for credit cards. Hide for asset accounts.

Keep the form minimal: no destructive actions in this stage. Account
deletion is a future feature and would interact poorly with the
soft-delete mechanism added in S1.3 — explicitly out of scope here.

Apply the same `GlassCard` chrome used elsewhere so Settings doesn't
look unstyled.

### 5.6 — Tests

**New file**:
`FinanceTrackerTests/PipelineTests/MultiHSBCAccountTests.swift`.

You need a second HSBC fixture. Copy `samples/2026-05-08_HSBC_2Now_paste.txt`
to `samples/2026-05-08_HSBC_2Now_paste_accountB.txt` and edit only:

- The `Tarjeta titular` line so the 16-digit number is different. Use
  `9999 0000 2222 2222` for the titular and `9999 0000 2222 2223` for
  the supplementary. (Last 4: 2222 main, 2223 digital.)
- Every transaction row's truncated card hint that names "Tarjeta
  titular …2222" and "Tarjeta adicional …2223".

Tests:

```swift
@Suite("Multi-HSBC isolation")
@MainActor
struct MultiHSBCAccountTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Account.self, Transaction.self, Statement.self,
            Category.self, CategoryRule.self, InstallmentPlan.self,
            PendingImport.self, SignRecoveryHint.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func loadFixture(_ filename: String) throws -> String {
        let url = URL(fileURLWithPath: "/Users/developer/Documents/GitHub/shiny-happiness/samples/\(filename)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Pasting two distinct HSBC accounts creates two distinct Accounts")
    func twoAccountsRemainDistinct() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        SeedDataLoader.bootstrapIfNeeded(context: context)
        let pipeline = IngestPipeline(context: context)

        _ = await pipeline.ingestPastedText(try loadFixture("2026-05-08_HSBC_2Now_paste.txt"),
                                            sourceLabel: "HSBC A")
        _ = await pipeline.ingestPastedText(try loadFixture("2026-05-08_HSBC_2Now_paste_accountB.txt"),
                                            sourceLabel: "HSBC B")

        let accounts = try context.fetch(FetchDescriptor<Account>())
        let hsbcAccounts = accounts.filter { $0.institution == "HSBC 2Now" }
        #expect(hsbcAccounts.count == 2,
                "Expected exactly 2 HSBC accounts after two distinct pastes, got \(hsbcAccounts.count)")

        let numbers = Set(hsbcAccounts.compactMap(\.accountNumber))
        #expect(numbers == ["1111", "2222"],
                "Expected accountNumbers {1111, 2222}, got \(numbers)")
    }

    @Test("Each HSBC account holds only its own cards' transactions")
    func transactionsDoNotCrossAccounts() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        SeedDataLoader.bootstrapIfNeeded(context: context)
        let pipeline = IngestPipeline(context: context)

        _ = await pipeline.ingestPastedText(try loadFixture("2026-05-08_HSBC_2Now_paste.txt"),
                                            sourceLabel: "HSBC A")
        _ = await pipeline.ingestPastedText(try loadFixture("2026-05-08_HSBC_2Now_paste_accountB.txt"),
                                            sourceLabel: "HSBC B")

        let txns = try context.fetch(FetchDescriptor<Transaction>())
        let byAccount = Dictionary(grouping: txns, by: { $0.account?.accountNumber ?? "?" })

        for (acctNumber, list) in byAccount where acctNumber != "?" {
            let cardSet = Set(list.compactMap(\.cardLast4))
            switch acctNumber {
            case "1111":
                #expect(cardSet.isSubset(of: ["1111", "1112"]),
                        "Account 1111 has transactions tagged with foreign cards: \(cardSet)")
            case "2222":
                #expect(cardSet.isSubset(of: ["2222", "2223"]),
                        "Account 2222 has transactions tagged with foreign cards: \(cardSet)")
            default:
                Issue.record("Unexpected account number: \(acctNumber)")
            }
        }
    }

    @Test("AccountIdentity assigns distinct hues to two HSBC accounts")
    func identityColorsDiffer() async throws {
        let a = Account(institution: "HSBC 2Now", type: .creditCard, accountNumber: "1111")
        let b = Account(institution: "HSBC 2Now", type: .creditCard, accountNumber: "2222")
        let colorA = AccountIdentity.color(for: a)
        let colorB = AccountIdentity.color(for: b)
        #expect(colorA != colorB,
                "Two same-institution accounts must receive distinct colors")
    }
}
```

### 5.7 — Commits (in this order)

```
fix: never merge distinct card-account numbers in findOrCreateAccount

Tightens the fallback in IngestPipeline.findOrCreateAccount so it only
fires when the parser did not supply a sectionNumber. When a number is
present and doesn't match any existing account, create a new one
instead of silently merging into the first institution+type match.

Closes the multi-HSBC merge bug: pasting a second HSBC 2Now statement
from a different 16-digit physical card had been merging that account's
supplementary card transactions into the first HSBC account.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

```
feat: Account.displayName + per-account nickname / color / credit-limit editor

Account gains a computed displayName that surfaces the user-set
nickname when present, otherwise "<institution> ····<last4>". Replaces
every .nickname call site across the dashboards, sidebar, breakdown
sheet, transactions table, and category badge so two same-institution
accounts read distinctly without manual setup.

Settings → Accounts gains an editor: nickname TextField,
identity-color ColorPicker (round-trips through Account.tintHex), and
credit-limit field (credit cards only). Bound directly to the @Model
properties so SwiftData persists on the next runloop.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

```
feat: AccountIdentity auto-assigns distinct hues for same-institution accounts

AccountIdentity.color(for:) now shifts the institution's default hue
by a deterministic offset derived from Account.id (first byte ->
±20° on the HSL hue wheel). A given Account always picks the same
shifted color; single-account users see the original color essentially
unchanged.

Required for the multi-HSBC case where both accounts share
institution = "HSBC 2Now" and neither has a user-chosen tintHex.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

```
test: multi-HSBC isolation (two accounts, two card pairs, no cross-tagging)

Adds MultiHSBCAccountTests with three @Tests:
  - twoAccountsRemainDistinct: two pastes produce two Accounts with
    distinct accountNumbers (1111, 2222)
  - transactionsDoNotCrossAccounts: every transaction's cardLast4 is in
    the {main, digital} pair for its owning account
  - identityColorsDiffer: AccountIdentity.color returns distinct values

A new fixture samples/2026-05-08_HSBC_2Now_paste_accountB.txt simulates
the second account by rewriting the titular/adicional 16-digit
identifiers; the rest of the statement is identical to account A.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

---

## 6. Stage S1 — Data safety (local-only; CloudKit deferred)

CloudKit is **explicitly out of scope** per stakeholder decision. The
backlog gets a "CloudKit sync" item; do not edit entitlements or
project.yml capabilities.

### 6.1 — `lastModifiedAt` on every model

Even without CloudKit, this is the universal "what was touched most
recently" signal we'll want for sync-conflict resolution AND for
backup-strategy decisions ("don't write a snapshot if nothing has
changed since the last one").

Add to every `@Model` class:

```swift
var lastModifiedAt: Date = .now
```

Files: every file under `FinanceTracker/Domain/Models/`. Eight models.
Initialize the property in each init. Update the property at every
mutation site:

- `LearningHooks.swift` — when inserting a new `CategoryRule` or
  `SignRecoveryHint`, the init sets `lastModifiedAt` automatically;
  good.
- `Normalizer.swift` — normalize sets `lastModifiedAt` via the init;
  good.
- `EditableCells.swift` — every commit closure in `EditableTextCell`,
  `EditableDateCell`, `EditableAmountCell` must also set
  `transaction.lastModifiedAt = .now` before calling `try? modelContext.save()`.
- `PendingReviewSection.swift` — `resolve()` should bump
  `pending.lastModifiedAt` and the new `Transaction`'s.
- `IngestPipeline.linkInstallmentPlans` — bump the plan's
  `lastModifiedAt` when a new period extends the schedule.

You may centralize this as `extension PersistentModel { func touch() { … } }`
if it lets you replace direct property assignments cleanly. The
mechanical pattern is: any code path that mutates a property is
followed by `obj.lastModifiedAt = .now`.

### 6.2 — `Transaction.deletedAt` for soft-delete

**File**: `FinanceTracker/Domain/Models/Transaction.swift`. Add:

```swift
var deletedAt: Date? = nil
```

Update every `FetchDescriptor<Transaction>` in the codebase to filter
`$0.deletedAt == nil` UNLESS the caller is the "Recently Deleted"
view (introduced below). Use grep to find them all:

```bash
grep -RIn "FetchDescriptor<Transaction>" FinanceTracker/
```

There are several in `DashboardViewModel.swift` (`windowedTransactions`),
`IngestPipeline.swift` (`fetchExistingTransactions`),
`PendingReviewSection.swift`, `ApplyToSimilarView.swift`,
`TransactionsView.swift` (the main `@Query`).

The main `@Query` in `TransactionsView`:

```swift
@Query(filter: #Predicate<Transaction> { $0.deletedAt == nil },
       sort: \Transaction.postedAt, order: .reverse)
private var allTransactions: [Transaction]
```

Add a swipe action / context menu to soft-delete a row. Set
`deletedAt = .now`, do NOT call `context.delete(...)`.

Add a "Recently Deleted" filter chip in the toolbar. Selecting it
swaps the `@Query` for one filtering on `$0.deletedAt != nil` and
shows last 90 days of soft-deleted rows with a Restore action that
nils `deletedAt`.

### 6.3 — Local backup archive (`.ftbackup` folder bundle)

**Why a folder bundle**: easy to inspect (`cd` in, read JSON files
directly), atomic-rename-replace from a tmp directory, no
zip-library dependency, easy to diff between snapshots, macOS
treats it as a package via Info.plist.

**Files (new)**:

- `FinanceTracker/Features/Backup/BackupArchive.swift` — pure I/O,
  no UI. Two static functions:
  ```swift
  static func export(to bundleURL: URL, from context: ModelContext) async throws
  static func restore(from bundleURL: URL, into context: ModelContext, strategy: RestoreStrategy) async throws
  ```
- `FinanceTracker/Features/Backup/BackupScheduler.swift` — orchestrates
  scheduled snapshots, retention, mirroring.
- `FinanceTracker/Features/Backup/BackupModels.swift` — Codable
  snapshot structs (NOT the @Model classes; those are reference types
  and we want explicit Codable contracts).

**Bundle layout**:

```
2026-05-13T14-22-08Z.ftbackup/
  Info.plist                         (CFBundlePackageType=BNDL so Finder treats it as a package)
  manifest.json                      (app version, schema version, timestamp, content hashes)
  models/
    accounts.json
    transactions.json
    statements.json
    categories.json
    category_rules.json
    installment_plans.json
    pending_imports.json
    sign_recovery_hints.json
  statements/
    <hash>.pdf                       (copies of every imported file, by sourceFileHash)
    <hash>.txt
```

The Info.plist needs only:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleIdentifier</key>
    <string>com.financeTracker.app.backup</string>
</dict>
</plist>
```

**Codable snapshot structs** (one per `@Model` in `BackupModels.swift`):

```swift
struct AccountSnapshot: Codable {
    var id: UUID
    var institution: String
    var type: String           // AccountType.rawValue
    var currency: String
    var nickname: String
    var accountNumber: String?
    var openedAt: Date
    var closedAt: Date?
    var creditLimit: Decimal?
    var statementDayOfMonth: Int?
    var paymentDayOfMonth: Int?
    var tintHex: String?
    var lastModifiedAt: Date
}
```

…and so on for every @Model. Relationships encode as the related
object's `UUID`, not the object itself. On restore, resolve the UUID
back to the in-context object after all rows are inserted in two passes.

**manifest.json**:

```json
{
  "schemaVersion": 1,
  "createdAt": "2026-05-13T14:22:08Z",
  "appVersion": "0.x.y",
  "modelCounts": {
    "accounts": 3, "transactions": 412, "statements": 7,
    "categories": 79, "categoryRules": 44, "installmentPlans": 1,
    "pendingImports": 0, "signRecoveryHints": 1
  },
  "contentHashes": {
    "models/accounts.json": "sha256-…",
    "models/transactions.json": "sha256-…"
  }
}
```

`schemaVersion: 1` is the contract for migration: if a future version
of the app reads a backup with a lower `schemaVersion`, it knows to
run a migration step before merging rows.

**`RestoreStrategy`**:

```swift
enum RestoreStrategy {
    case mergeKeepingNewer    // default: per-row, the side with the larger lastModifiedAt wins
    case replaceAll           // wipe the target context, then import every row from the bundle
}
```

`mergeKeepingNewer` requires `lastModifiedAt` on every model (S1.1).

**Statement files**: copy `~/Library/Application Support/FinanceTracker/Statements/*`
verbatim into `<bundle>/statements/`. The Transaction → Statement →
sourceFileHash chain still works after restore because the hash is the
filename.

### 6.4 — `BackupScheduler` — rolling snapshots + retention

**Logic**:

- On app launch (from a `.task` modifier on the root view), if the last
  snapshot is older than 24h, create a new one in
  `~/Library/Application Support/FinanceTracker/Backups/`.
- Retention: keep
  - the last 7 daily snapshots,
  - the most recent weekly snapshot for each of the last 4 weeks,
  - the most recent monthly snapshot for each of the last 12 months.

Implement retention as a single function `pruneSnapshots(in:)` that
walks the Backups directory, parses each `.ftbackup`'s timestamp from
its filename (`yyyy-MM-dd'T'HH-mm-ss'Z'.ftbackup`), classifies each
into daily/weekly/monthly buckets relative to `now`, and deletes
everything outside the keep list.

Run `pruneSnapshots` AFTER each successful snapshot, never before.

### 6.5 — Settings UI: Backup & Restore

Add a section to `SettingsView` (already growing for §5.5):

- "Last snapshot" — relative time ("2 hours ago") + absolute date.
- "Snapshots on disk" — count + total bytes.
- "Export backup…" button — opens a `NSSavePanel` for picking a
  destination, then runs `BackupArchive.export(to:from:)`. Default
  filename: `FinanceTracker-<timestamp>.ftbackup`.
- "Restore from backup…" button — opens a `NSOpenPanel`, then shows a
  confirmation sheet describing what the file contains (counts from the
  manifest) and offering a strategy (Merge / Replace). Defaults to
  Merge.
- "Reveal Backups folder in Finder" — opens
  `~/Library/Application Support/FinanceTracker/Backups/`.

Soft-deleted rows are exported (so they can be restored). Document
this in the Settings copy: "Backups include items in Recently Deleted."

### 6.6 — Tests

**New file**: `FinanceTrackerTests/EndToEndTests/BackupArchiveTests.swift`.

```swift
@Suite("Backup Archive")
@MainActor
struct BackupArchiveTests {

    private func makeContainer() throws -> ModelContainer { … }

    @Test("Round-trip: export then restore reconstructs all rows")
    func roundTrip() async throws {
        let source = try makeContainer()
        SeedDataLoader.bootstrapIfNeeded(context: source.mainContext)
        // Insert a known fixture: 1 account, 3 transactions, 1 statement.
        // …
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID()).ftbackup", isDirectory: true)
        try await BackupArchive.export(to: tmp, from: source.mainContext)

        let target = try makeContainer()
        try await BackupArchive.restore(from: tmp, into: target.mainContext, strategy: .replaceAll)

        let accounts = try target.mainContext.fetch(FetchDescriptor<Account>())
        let txns = try target.mainContext.fetch(FetchDescriptor<Transaction>())
        #expect(accounts.count == 1)
        #expect(txns.count == 3)
    }

    @Test("mergeKeepingNewer keeps the row with the later lastModifiedAt")
    func mergeNewer() async throws { /* construct conflicting rows with different timestamps */ }

    @Test("Manifest content hashes match the JSON files on disk")
    func manifestIntegrity() async throws { /* tamper test */ }
}
```

Don't try to test `BackupScheduler` directly — its time-based logic is
hard to fake. Manual verification is acceptable when the stakeholder
is back.

### 6.7 — Commits

```
feat: lastModifiedAt on every @Model + touch() helper

Adds `var lastModifiedAt: Date = .now` to all 8 @Model classes. Every
mutation path (editable transaction cells, pending-import resolution,
learning hooks, paste-import pipeline) now stamps the field via a
PersistentModel.touch() extension before save().

This is the foundation for two later features: backup
mergeKeepingNewer (lands in this stage's archive commit) and CloudKit
sync (backlog item; not implemented here).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

```
feat: Transaction.deletedAt soft-delete + Recently Deleted view

Transaction gains a nullable deletedAt: Date?. All FetchDescriptors
across the app filter `deletedAt == nil` by default. Swipe / context-
menu delete sets deletedAt = .now instead of calling context.delete.

A new "Recently Deleted" toolbar chip on TransactionsView swaps the
@Query to surface soft-deleted rows from the last 90 days with a
Restore action that nils deletedAt.

Combined with the rolling backup snapshots, this gives the stakeholder
two recovery paths: the in-app trash for short-term mistakes, and the
.ftbackup archives for everything older.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

```
feat: .ftbackup local archive + Settings export / restore UI

New backup pipeline:
  - BackupArchive.export(to:from:) writes a .ftbackup folder bundle
    (Info.plist + manifest.json + per-model JSON snapshots + verbatim
    copies of imported statement files).
  - BackupArchive.restore(from:into:strategy:) reads the bundle and
    materializes rows into a context. Two strategies: mergeKeepingNewer
    (per-row last-write-wins via lastModifiedAt) and replaceAll
    (wipe-then-import, confirmed via Settings sheet).
  - BackupScheduler runs from a .task on the root view: writes a
    snapshot if the last one is >24h old, then prunes to keep last 7
    daily / last 4 weekly / last 12 monthly snapshots under
    ~/Library/Application Support/FinanceTracker/Backups/.
  - Settings → Backup section shows last-snapshot timestamp, count
    on disk, Export… / Restore… / Reveal in Finder actions.

CloudKit sync is intentionally deferred to backlog. This commit gives
the stakeholder durable, vendor-neutral, point-in-time archives that
survive any Apple-ID / schema / SwiftData incident.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

```
test: BackupArchive round-trip + merge + manifest integrity

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

---

## 7. Documentation pass (after S0–S3 land)

### 7.1 — `DECISIONS.md`

Append:

- **AD-015** Soft-delete via `Transaction.deletedAt`; permanent deletion
  is the backup retention's job.
- **AD-016** Local `.ftbackup` folder bundle is the primary durability
  story. CloudKit sync deferred to backlog.
- **AD-017** `findOrCreateAccount` never falls back to
  `(institution, type)` when a `sectionNumber` is supplied; closes the
  multi-HSBC merge bug.

### 7.2 — `CLAUDE.md`

Add a "Backup architecture" subsection under "Architecture" listing:
- `.ftbackup` folder bundles under
  `~/Library/Application Support/FinanceTracker/Backups/`.
- 24h scheduling on launch via `BackupScheduler.runIfNeeded()`.
- Retention windows (7 daily, 4 weekly, 12 monthly).
- Soft-delete via `Transaction.deletedAt`; Recently Deleted view.

Mention the parallel-testing-off invocation explicitly (it's already
there but reinforce it because the test count grows in this stage).

### 7.3 — `CHANGELOG.md`

One section per stage:

- "**Scroll performance**" — S0.
- "**Multi-HSBC isolation**" — S2 (one entry covering all four commits).
- "**Drill-down completeness**" — S3.
- "**Data safety: soft-delete + local backup**" — S1 (one entry).

### 7.4 — `specs/backlog.md`

- Cross off "Drill-down show-me-the-math" — already done in Stage 3
  but the Interest case was bugged; S3 closes it.
- Add new items:
  - **CloudKit sync** — entitlements + `cloudKitDatabase: .private(…)`;
    requires the InstallmentPlan inverse-relationship loosening
    described in the original plan. Deferred per stakeholder.
  - **Account deletion UX** — out of scope for S1.3; needs UI to
    surface soft-deletion of an entire account and its transactions
    cascade.
  - **Currency conversion** — multi-currency dashboards still display
    per-account currency; no conversion. Future.

---

## 8. Final acceptance checklist (run before declaring done)

```bash
# Always:
xcodegen generate

# After every commit:
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project FinanceTracker.xcodeproj -scheme FinanceTracker build

# After every commit that touches tests or model layer:
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project FinanceTracker.xcodeproj \
  -scheme FinanceTrackerTests -destination 'platform=macOS' \
  -parallel-testing-enabled NO
```

Each stage produces a clean build and a passing test suite before the
next stage begins. If a test fails, fix forward in the same commit;
never commit a red state.

Do not push. Do not open PRs. Do not run the bundled app. Do not
launch any sub-app (no `open …app`). Do not edit
`FinanceTracker.entitlements` or `project.yml`'s capabilities section
in this scope.

When everything in §3–7 is landed and the test suite is green, write a
short summary message for the stakeholder listing every commit you
made (oneline format) and any unexpected discoveries.

---

## 9. What to do if you get stuck

- **A test was passing before your change and fails after** — fix
  forward in the same commit. The test was the contract; honour it.
- **A `Predicate` complains about unsupported expressions** — SwiftData
  `#Predicate` rejects some operations on `nil` checks against
  optionals. Use `unwrap` patterns:
  `#Predicate<Transaction> { $0.deletedAt == nil }` works;
  `#Predicate { ($0.deletedAt ?? Date.distantPast) < someDate }` may not.
  If a predicate doesn't compile, fall back to fetching all and
  filtering in-memory.
- **SwiftData migration fails** because of a new property — every new
  property MUST have a default value in its declaration
  (`var deletedAt: Date? = nil`, `var lastModifiedAt: Date = .now`).
  Lightweight migration only handles property additions with defaults.
- **The stakeholder is asleep / unavailable** — never block on them.
  Make the conservative call documented in this spec and proceed. The
  only "go ask" cases are: a destructive operation the spec doesn't
  authorize, or a change that would alter an AD-* invariant.

End of spec.
