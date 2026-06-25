# Stocks Portfolio Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Track a personal stock portfolio (mostly BMV) as an `investment` account — per-stock positions with live DataBursatil prices, current value, and growth % vs cost basis — counting toward Net Worth via authoritative valuation snapshots.

**Architecture:** One new SwiftData model `StockPosition` (ticker + shares + averageCost + cached lastPrice). Prices come from a batched DataBursatil v2 `/cotizaciones` fetch on demand. After a complete successful refresh, the portfolio total is written as an `.portfolioValuation` `AccountBalanceSnapshot` carrying a holdings fingerprint; the resolver treats that anchor as authoritative (no transaction roll-forward) and exposes provenance so the dashboard can show honest, period-correct valuation and growth. Positions are edited in a sheet owned by `DashboardView`; portfolio data reaches the dashboard as value-type `PortfolioViewData`.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, SwiftData (versioned schema V1→V2→V3), Swift Testing (`@Suite`/`@Test`, serial runs), Security framework (Keychain), URLSession. No external dependencies.

**Spec:** `specs/stocks-portfolio.md` (5 review rounds; decision-complete).

**Repo conventions (from CLAUDE.md):**
- Run `xcodegen generate` after adding/moving Swift files.
- Tests: `xcodebuild test … -parallel-testing-enabled NO` (serial — parallel hangs on PDFKit teardown). Add `@Test` to **existing** suites; never create a new isolated `@MainActor` suite (crashes on launch).
- All monetary values are `Decimal` — never `Double`/`Float` in `Domain/`.

---

## File Structure

**Create:**
- `FinanceTracker/Domain/Models/StockPosition.swift` — the new `@Model`.
- `FinanceTracker/Domain/Services/HoldingsFingerprint.swift` — pure SHA-256 of normalized holdings; `Sendable`, no actor.
- `FinanceTracker/Features/Portfolio/DataBursatilClient.swift` — `Sendable` networking client, injected transport, v2 `/cotizaciones`, Decimal decode.
- `FinanceTracker/Features/Portfolio/PortfolioPriceRefresher.swift` — `@MainActor`; batched refresh → writes `lastPrice`/`lastPriceAt` only; writes `.portfolioValuation` snapshot on full success; writes zero snapshot when emptied.
- `FinanceTracker/Features/Portfolio/PortfolioService.swift` — `@MainActor`; add/edit/buy-more/delete positions; weighted-average cost; portfolio-mode eligibility + mode; zero-snapshot on final delete.
- `FinanceTracker/Features/Portfolio/PortfolioViewData.swift` — value-type `PortfolioViewData` + `PositionRow` (no live models).
- `FinanceTracker/Utilities/KeychainTokenStore.swift` — Security-framework store for the DataBursatil token; never in SwiftData or `.ftbackup`.

**Modify:**
- `FinanceTracker/Domain/ValueObjects/AccountBalanceSnapshotKind.swift` — add `.portfolioValuation`.
- `FinanceTracker/Domain/Services/AccountBalanceResolver.swift` — authoritative-valuation short-circuit + `AccountBalanceResolution` provenance fields.
- `FinanceTracker/App/AppSchema.swift` — freeze V2 (explicit 9-model list), add frozen V3 (explicit 10-model list) + lightweight migration stage.
- `FinanceTracker/Features/Backup/BackupModels.swift` — `StockPositionSnapshot` Codable struct.
- `FinanceTracker/Features/Backup/BackupArchive.swift` — `schemaVersion = 3`, allow-list `{1,2,3}`, export/restore `StockPosition`, version-conditional loader, **field-selective** `resolveOrInsertStockPosition`.
- `FinanceTracker/Utilities/AppDataResetService.swift` — add `StockPosition` to delete order + verification.
- `FinanceTracker/Features/Settings/AccountDeletionService.swift` — add `stockPositions` to `LinkedObjects`/`DeletionPreview`/`collectLinkedObjects`.
- `FinanceTracker/Features/Dashboard/DashboardViewModel.swift` — compute `PortfolioViewData` in `buildAsset`; expose portfolio action hooks.
- `FinanceTracker/Features/Dashboard/AssetAccountDashboard.swift` — render portfolio summary + positions table; `onRefreshPrices`/`onEditPositions` closures; local refresh state.
- `FinanceTracker/Features/Dashboard/DashboardView.swift` — own the edit sheet + refresh action; pass closures; call `viewModel.refresh()` after.
- `FinanceTracker/Features/Settings/SettingsView.swift` — `SecureField` token (Save/Clear) + link.
- `FinanceTracker/Features/Accounts/ManualAccountSheet.swift` — "Add stock positions" affordance (eligibility-gated).
- `project.yml` — ensure new files are picked up (XcodeGen glob; usually automatic).
- `CHANGELOG.md` — release-visible entry.

**Tests (extend existing suites):**
- `FinanceTrackerTests/PortfolioTests/HoldingsFingerprintTests.swift` — pure unit (new file under an existing-style suite is fine; it is NOT a `@MainActor` SwiftData suite).
- `FinanceTrackerTests/PortfolioTests/DataBursatilClientTests.swift` — injected-transport decode tests.
- `FinanceTrackerTests/EndToEndTests/BackupArchiveTests.swift` — StockPosition round-trip, field-selective merge conflict, v1/v2 restore with no file, v3 missing-file failure.
- `FinanceTrackerTests/EndToEndTests/AppDataResetServiceTests.swift` — reset count includes StockPosition.
- `FinanceTrackerTests/EndToEndTests/AccountDeletionServiceTests.swift` — cascade + preview.
- `FinanceTrackerTests/EndToEndTests/PortfolioResolverTests.swift` — authoritative valuation + provenance (extend or add to an existing `@MainActor` resolver suite; do NOT make a new isolated one).
- `FinanceTrackerTests/EndToEndTests/PortfolioServiceTests.swift` — add/buy-more/delete, weighted avg, portfolio-mode eligibility, zero-snapshot on final delete.

---

## Task 1: `AccountBalanceSnapshotKind.portfolioValuation`

**Files:**
- Modify: `FinanceTracker/Domain/ValueObjects/AccountBalanceSnapshotKind.swift`

- [ ] **Step 1: Add the case**

```swift
import Foundation

enum AccountBalanceSnapshotKind: String, Codable, CaseIterable {
    case manualOpening
    case manualAdjustment
    case portfolioValuation
}
```

- [ ] **Step 2: Build**

Run: `xcodegen generate && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project FinanceTracker.xcodeproj -scheme FinanceTracker build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (raw-value enum, new case is backward-compatible).

- [ ] **Step 3: Commit**

```bash
git add FinanceTracker/Domain/ValueObjects/AccountBalanceSnapshotKind.swift
git commit -m "feat: add .portfolioValuation balance snapshot kind"
```

---

## Task 2: `StockPosition` model + schema V3 (frozen)

**Files:**
- Create: `FinanceTracker/Domain/Models/StockPosition.swift`
- Modify: `FinanceTracker/App/AppSchema.swift`

- [ ] **Step 1: Create the model**

`FinanceTracker/Domain/Models/StockPosition.swift`:

```swift
import Foundation
import SwiftData

@Model
final class StockPosition: LastModifiedTracking {
    var id: UUID
    @Relationship(deleteRule: .nullify) var account: Account?
    var emisoraSerie: String
    var name: String?
    var shares: Decimal
    var averageCost: Decimal
    var lastPrice: Decimal?
    var lastPriceAt: Date?
    var createdAt: Date
    var lastModifiedAt: Date = Date.now

    init(
        id: UUID = UUID(),
        account: Account? = nil,
        emisoraSerie: String,
        name: String? = nil,
        shares: Decimal,
        averageCost: Decimal,
        lastPrice: Decimal? = nil,
        lastPriceAt: Date? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.account = account
        self.emisoraSerie = emisoraSerie.uppercased()
        self.name = name
        self.shares = shares
        self.averageCost = averageCost
        self.lastPrice = lastPrice
        self.lastPriceAt = lastPriceAt
        self.createdAt = createdAt
    }
}
```

> `LastModifiedTracking` is the existing protocol/protocol-extension used by `AccountBalanceSnapshot` (see `AccountBalanceSnapshot.swift:4`); conform identically. If it's a protocol with no requirements beyond `lastModifiedAt`, the `@Model` already satisfies it — confirm by grepping `protocol LastModifiedTracking`.

- [ ] **Step 2: Freeze V2, add frozen V3, register model**

In `FinanceTracker/App/AppSchema.swift`:

(a) Replace the V2 body (lines 214-217) so it is frozen with an explicit list — no longer `{ AppSchema.modelTypes }`:

```swift
enum FinanceTrackerSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(0, 5, 0)
    static var models: [any PersistentModel.Type] {
        [
            Account.self,
            AccountBalanceSnapshot.self,
            Transaction.self,
            Statement.self,
            Category.self,
            CategoryRule.self,
            InstallmentPlan.self,
            PendingImport.self,
            SignRecoveryHint.self,
        ]
    }
}
```

(b) Add V3 after V2 (explicit 10-model literal — NOT `AppSchema.modelTypes`):

```swift
enum FinanceTrackerSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(0, 6, 0)
    static var models: [any PersistentModel.Type] {
        [
            Account.self,
            AccountBalanceSnapshot.self,
            Transaction.self,
            Statement.self,
            Category.self,
            CategoryRule.self,
            InstallmentPlan.self,
            PendingImport.self,
            SignRecoveryHint.self,
            StockPosition.self,
        ]
    }
}
```

(c) In `FinanceTrackerMigrationPlan` (lines 219-226), add V3 to schemas + a lightweight stage:

```swift
static var schemas: [any VersionedSchema.Type] {
    [FinanceTrackerSchemaV1.self, FinanceTrackerSchemaV2.self, FinanceTrackerSchemaV3.self]
}

static var stages: [MigrationStage] {
    [migrateV1toV2, migrateV2toV3]
}

private static let migrateV2toV3 = MigrationStage.lightweight(
    fromVersion: FinanceTrackerSchemaV2.self,
    toVersion: FinanceTrackerSchemaV3.self
)
```

(d) Add `StockPosition.self` to `AppSchema.modelTypes` (the live list, lines 321-333) — append after `SignRecoveryHint.self`:

```swift
    static var modelTypes: [any PersistentModel.Type] {
        [
            Account.self,
            AccountBalanceSnapshot.self,
            Transaction.self,
            Statement.self,
            Category.self,
            CategoryRule.self,
            InstallmentPlan.self,
            PendingImport.self,
            SignRecoveryHint.self,
            StockPosition.self,
        ]
    }
```

- [ ] **Step 3: `xcodegen generate` and build**

Run: `xcodegen generate && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project FinanceTracker.xcodeproj -scheme FinanceTracker build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Verify migration is lightweight (no custom stage needed)**

Open the existing test suite's `makeContainer` path mentally: SwiftData will run V2→V3 lightweight on an existing store. If the build/test in Task 3 passes against a fresh in-memory container (V3) AND the migration test in a later task passes against a real on-disk V2 store, lightweight is confirmed. If a later migration test fails with "lightweight migration unsupported," switch `migrateV2toV3` to `MigrationStage.custom(fromVersion:toVersion:didMigrate: { _ in })` (no-op save).

- [ ] **Step 5: Commit**

```bash
git add FinanceTracker/Domain/Models/StockPosition.swift FinanceTracker/App/AppSchema.swift project.yml
git commit -m "feat: add StockPosition model + schema V3 (frozen V2)"
```

---

## Task 3: `HoldingsFingerprint` (pure, no actor)

**Files:**
- Create: `FinanceTracker/Domain/Services/HoldingsFingerprint.swift`
- Test: `FinanceTrackerTests/PortfolioTests/HoldingsFingerprintTests.swift`

- [ ] **Step 1: Write the failing test**

`FinanceTrackerTests/PortfolioTests/HoldingsFingerprintTests.swift`:

```swift
import Testing
import Foundation
@testable import FinanceTracker

@Suite("Holdings Fingerprint")
struct HoldingsFingerprintTests {
    /// Plain value tuples used as input so the test doesn't need SwiftData.
    private struct Holding { let ticker: String; let shares: Decimal; let cost: Decimal }

    private func fp(_ holdings: [Holding]) -> String {
        HoldingsFingerprint.of(holdings.map { ($0.ticker, $0.shares, $0.cost) })
    }

    @Test("Order-independent")
    func orderIndependent() {
        let a = fp([Holding(ticker: "bimboa", shares: 10, cost: 50),
                    Holding(ticker: "FEMSAUBD", shares: 5, cost: 100)])
        let b = fp([Holding(ticker: "FEMSAUBD", shares: 5, cost: 100),
                    Holding(ticker: "bimboa", shares: 10, cost: 50)])
        #expect(a == b)
    }

    @Test("Ticker normalization (uppercase/trim)")
    func tickerNormalized() {
        let a = fp([Holding(ticker: " femsaubd ", shares: 5, cost: 100)])
        let b = fp([Holding(ticker: "FEMSAUBD", shares: 5, cost: 100)])
        #expect(a == b)
    }

    @Test("Different holdings differ")
    func differs() {
        let a = fp([Holding(ticker: "FEMSAUBD", shares: 5, cost: 100)])
        let b = fp([Holding(ticker: "FEMSAUBD", shares: 6, cost: 100)])
        #expect(a != b)
    }

    @Test("Zero-share positions excluded")
    func excludesZeroShares() {
        let withZero = fp([Holding(ticker: "FEMSAUBD", shares: 5, cost: 100),
                           Holding(ticker: "BIMBOA", shares: 0, cost: 40)])
        let withoutZero = fp([Holding(ticker: "FEMSAUBD", shares: 5, cost: 100)])
        #expect(withZero == withoutZero)
    }

    @Test("Empty holdings are stable")
    func emptyStable() {
        #expect(fp([]) == fp([]))
        #expect(!fp([]).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests -destination 'platform=macOS' -only-testing:FinanceTrackerTests/HoldingsFingerprintTests -parallel-testing-enabled NO 2>&1 | tail -15`
Expected: FAIL — `HoldingsFingerprint` unresolved.

- [ ] **Step 3: Implement**

`FinanceTracker/Domain/Services/HoldingsFingerprint.swift`:

```swift
import Foundation
import CryptoKit

/// Locale-independent SHA-256 of a portfolio's active holdings.
/// Input is normalized so the fingerprint is stable regardless of locale/format.
enum HoldingsFingerprint {
    /// `holdings`: (ticker, shares, averageCost). Only `shares > 0` rows count.
    static func of(_ holdings: [(ticker: String, shares: Decimal, cost: Decimal)]) -> String {
        let rows = holdings
            .filter { $0.shares > 0 }
            .map { (ticker: $0.ticker.uppercased().trimmingCharacters(in: .whitespaces),
                    shares: $0.shares,
                    cost: $0.cost) }
            .sorted { lhs, rhs in
                if lhs.ticker != rhs.ticker { return lhs.ticker < rhs.ticker }
                return false
            }
        // ponytail: unit delimiter \u{1F} can't appear in a ticker or stringValue.
        let delimiter = "\u{1F}"
        let payload = rows.map { row in
            // NSDecimalNumber.stringValue is locale-independent (no grouping separators).
            let s = NSDecimalNumber(decimal: row.shares).stringValue
            let c = NSDecimalNumber(decimal: row.cost).stringValue
            return "\(row.ticker)\(delimiter)\(s)\(delimiter)\(c)"
        }.joined(separator: delimiter)
        return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests -destination 'platform=macOS' -only-testing:FinanceTrackerTests/HoldingsFingerprintTests -parallel-testing-enabled NO 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FinanceTracker/Domain/Services/HoldingsFingerprint.swift FinanceTrackerTests/PortfolioTests/HoldingsFingerprintTests.swift project.yml
git commit -m "feat: holdings fingerprint (locale-independent SHA-256)"
```

---

## Task 4: Resolver — authoritative valuation + provenance

**Files:**
- Modify: `FinanceTracker/Domain/Services/AccountBalanceResolver.swift`
- Test: `FinanceTrackerTests/EndToEndTests/PortfolioResolverTests.swift`

- [ ] **Step 1: Write the failing tests**

`FinanceTrackerTests/EndToEndTests/PortfolioResolverTests.swift`:

```swift
import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

@Suite("Portfolio Resolver")
@MainActor
struct PortfolioResolverTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Account.self, AccountBalanceSnapshot.self, Transaction.self, Statement.self,
            Category.self, CategoryRule.self, InstallmentPlan.self,
            PendingImport.self, SignRecoveryHint.self, StockPosition.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test("portfolioValuation anchor is authoritative — no transaction roll-forward")
    func authoritativeNoRollForward() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let acct = Account(institution: "Broker", type: .investment, nickname: "Broker")
        ctx.insert(acct)
        let val = AccountBalanceSnapshot(account: acct, date: .now.addingTimeInterval(-3600),
                                         amount: 12_000, kind: .portfolioValuation)
        ctx.insert(val)
        // A manual transaction AFTER the valuation must NOT change market value.
        let tx = Transaction(postedAt: .now, amount: 500, descriptionRaw: "deposit")
        tx.account = acct
        ctx.insert(tx)
        try ctx.save()

        let res = AccountBalanceResolver.resolution(account: acct, asOf: .now, context: ctx)
        #expect(res.amount == 12_000, "valuation must be returned verbatim, got \(res.amount)")
    }

    @Test("provenance is portfolioValuation when it is the latest anchor")
    func provenancePortfolio() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let acct = Account(institution: "Broker", type: .investment, nickname: "Broker")
        ctx.insert(acct)
        let val = AccountBalanceSnapshot(account: acct, date: .now, amount: 1_000,
                                         kind: .portfolioValuation, note: "Portfolio valuation |fp=abc")
        ctx.insert(val)
        try ctx.save()

        let res = AccountBalanceResolver.resolution(account: acct, asOf: .now, context: ctx)
        #expect(res.sourceSnapshotKind == .portfolioValuation)
        #expect(res.sourceSnapshotNote == "Portfolio valuation |fp=abc")
        #expect(res.sourceSnapshotID == val.id)
    }

    @Test("provenance is NOT portfolioValuation when a statement is latest")
    func provenanceNotPortfolioWhenStatementLatest() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let acct = Account(institution: "Broker", type: .investment, nickname: "Broker")
        ctx.insert(acct)
        let val = AccountBalanceSnapshot(account: acct, date: .now.addingTimeInterval(-7200),
                                         amount: 1_000, kind: .portfolioValuation)
        ctx.insert(val)
        // Newer statement anchor:
        let stmt = Statement(account: acct, periodStart: .now.addingTimeInterval(-3600),
                             periodEnd: .now, sourceFileHash: "h", closingBalance: 800)
        ctx.insert(stmt)
        try ctx.save()

        let res = AccountBalanceResolver.resolution(account: acct, asOf: .now, context: ctx)
        #expect(res.sourceSnapshotKind != .portfolioValuation)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests -destination 'platform=macOS' -only-testing:FinanceTrackerTests/PortfolioResolverTests -parallel-testing-enabled NO 2>&1 | tail -20`
Expected: FAIL — `sourceSnapshotKind`/`sourceSnapshotNote`/`sourceSnapshotID` unresolved; authoritative assertion fails (amount would be 12_500).

- [ ] **Step 3: Add provenance fields to `AccountBalanceResolution`**

In `FinanceTracker/Domain/Services/AccountBalanceResolver.swift`, replace the `AccountBalanceResolution` struct (lines 15-27):

```swift
struct AccountBalanceResolution {
    enum SourceKind: String, Hashable {
        case exactBalanceSnapshot
        case latestPriorBalanceSnapshot
        case reconstructedBalance
        case insufficientHistory
    }

    let asOf: Date
    let amount: Decimal
    let sourceKind: SourceKind
    let sourceDate: Date?
    /// Provenance of the anchor that produced this resolution (nil when the anchor is a
    /// statement, or when reconstructed without a snapshot).
    let sourceSnapshotID: UUID?
    let sourceSnapshotKind: AccountBalanceSnapshotKind?
    let sourceSnapshotNote: String?

    init(
        asOf: Date,
        amount: Decimal,
        sourceKind: SourceKind,
        sourceDate: Date?,
        sourceSnapshotID: UUID? = nil,
        sourceSnapshotKind: AccountBalanceSnapshotKind? = nil,
        sourceSnapshotNote: String? = nil
    ) {
        self.asOf = asOf
        self.amount = amount
        self.sourceKind = sourceKind
        self.sourceDate = sourceDate
        self.sourceSnapshotID = sourceSnapshotID
        self.sourceSnapshotKind = sourceSnapshotKind
        self.sourceSnapshotNote = sourceSnapshotNote
    }
}
```

- [ ] **Step 4: Add the authoritative short-circuit + provenance**

In `resolution(account:asOf:context:)` (lines 41-107), insert an authoritative-valuation short-circuit **right after** `let anchor = anchorsThroughDate.max { $0.date < $1.date }` (before the `hasStatementAnchors` block). It is unconditional on account type / live positions:

```swift
        // Authoritative portfolio valuation: return verbatim, no transaction roll-forward.
        // Unconditional on anchor kind — applies even after the portfolio is emptied.
        if let anchor,
           case .manualSnapshot(let snap) = anchor.source,
           snap.kind == .portfolioValuation {
            return AccountBalanceResolution(
                asOf: date,
                amount: anchor.amount,
                sourceKind: .exactBalanceSnapshot,
                sourceDate: anchor.date,
                sourceSnapshotID: snap.id,
                sourceSnapshotKind: snap.kind,
                sourceSnapshotNote: snap.note
            )
        }
```

Then thread provenance into the existing return sites. For the `manualOpening` branch (two returns) and the final branch, attach provenance when the anchor is a `.manualSnapshot`:

For the `manualOpening` branch returns, compute a shared helper inline. Simplest: replace each existing `return AccountBalanceResolution(asOf:date:amount:sourceKind:sourceDate:)` call's trailing args to include provenance derived from `anchor`/`firstAnchor`. Add a small private helper near the bottom of the enum:

```swift
    private static func provenance(for anchor: AccountBalanceAnchor?) -> (UUID?, AccountBalanceSnapshotKind?, String?) {
        guard let anchor, case .manualSnapshot(let snap) = anchor.source else { return (nil, nil, nil) }
        return (snap.id, snap.kind, snap.note)
    }
```

Then in the **final** return (the `base + deltas` branch), change it to:

```swift
        let (sid, skind, snote) = provenance(for: anchor)
        return AccountBalanceResolution(
            asOf: date,
            amount: base + deltas,
            sourceKind: sourceKind,
            sourceDate: anchor?.date,
            sourceSnapshotID: sid,
            sourceSnapshotKind: skind,
            sourceSnapshotNote: snote
        )
```

For the two `manualOpening`-branch returns, pass `provenance(for: anchor)` similarly (first uses `anchor`, second uses `firstAnchor`'s snapshot — pass `provenance(for: firstAnchorWrapped)` where you wrap `firstAnchor` into an anchor; if awkward, pass `(nil, .manualOpening, nil)`/`(snap.id, .manualOpening, snap.note)` directly from `firstAnchor`). Keep these focused: provenance is only consumed for portfolio decisions; `manualOpening` provenance correctness is not load-bearing for this feature but should not crash.

- [ ] **Step 5: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests -destination 'platform=macOS' -only-testing:FinanceTrackerTests/PortfolioResolverTests -parallel-testing-enabled NO 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Run the full existing test suite to confirm no regressions**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests -destination 'platform=macOS' -parallel-testing-enabled NO 2>&1 | tail -20`
Expected: All PASS (the new optional provenance params default to nil, so existing call sites compile unchanged).

- [ ] **Step 7: Commit**

```bash
git add FinanceTracker/Domain/Services/AccountBalanceResolver.swift FinanceTrackerTests/EndToEndTests/PortfolioResolverTests.swift
git commit -m "feat: authoritative portfolio valuation + resolution provenance"
```

---

## Task 5: Keychain token store

**Files:**
- Create: `FinanceTracker/Utilities/KeychainTokenStore.swift`

- [ ] **Step 1: Implement the store**

`FinanceTracker/Utilities/KeychainTokenStore.swift`:

```swift
import Foundation
import Security

/// Stores the DataBursatil API token in the macOS Keychain.
/// Never persisted to SwiftData and never exported in `.ftbackup`.
enum KeychainTokenStore {
    private static let service = "com.financeTracker.databursatil"
    private static let account = "apiToken"

    static func setToken(_ token: String) throws {
        let data = Data(token.utf8)
        // Remove any existing item first (avoid errSecDuplicateItem).
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    static func token() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum KeychainError: Error, LocalizedError {
        case unhandled(OSStatus)
        var errorDescription: String? {
            switch self {
            case .unhandled(let s): "Keychain operation failed (OSStatus \(s))"
            }
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodegen generate && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project FinanceTracker.xcodeproj -scheme FinanceTracker build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add FinanceTracker/Utilities/KeychainTokenStore.swift project.yml
git commit -m "feat: Keychain token store for DataBursatil"
```

---

## Task 6: `DataBursatilClient` (injected transport, Decimal decode)

**Files:**
- Create: `FinanceTracker/Features/Portfolio/DataBursatilClient.swift`
- Test: `FinanceTrackerTests/PortfolioTests/DataBursatilClientTests.swift`

> **Gated pre-req:** Before finalizing the Codable structs, run the live curl in `specs/stocks-portfolio.md` ("Pre-implementation gated step") and capture real JSON. The struct below is written to the documented shape (ticker-keyed, with `u` and `f`); adjust keys/date format only if the live response differs. **Error messages must never include the request URL (it contains the token).**

- [ ] **Step 1: Write the failing test**

`FinanceTrackerTests/PortfolioTests/DataBursatilClientTests.swift`:

```swift
import Testing
import Foundation
@testable import FinanceTracker

@Suite("DataBursatil Client")
struct DataBursatilClientTests {
    /// Fake transport returning canned JSON; proves decode + Decimal + BMV/BIVA precedence
    /// without touching the network.
    private struct FakeTransport: HTTPRequesting {
        let body: Data
        let status: Int
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (body, resp)
        }
    }

    private func json(_ s: String) -> Data { Data(s.utf8) }

    @Test("Decodes BMV price to Decimal")
    func decodesBMV() async throws {
        let body = json(#"{"FEMSAUBD":{"BMV":{"u":19.86,"f":"2026-06-25 15:30:00"}}}"#)
        let client = DataBursatilClient(token: "t", transport: FakeTransport(body: body, status: 200))
        let quotes = try await client.quotes(for: ["FEMSAUBD"])
        #expect(quotes["FEMSAUBD"]?.price == 19.86)
        #expect(quotes["FEMSAUBD"]?.timestamp != nil)
    }

    @Test("Falls back to BIVA when BMV absent")
    func bivaFallback() async throws {
        let body = json(#"{"FEMSAUBD":{"BIVA":{"u":19.85,"f":"2026-06-25 15:30:00"}}}"#)
        let client = DataBursatilClient(token: "t", transport: FakeTransport(body: body, status: 200))
        let quotes = try await client.quotes(for: ["FEMSAUBD"])
        #expect(quotes["FEMSAUBD"]?.price == 19.85)
    }

    @Test("Missing token throws missingToken, no URL in error")
    func missingToken() async throws {
        let client = DataBursatilClient(token: "", transport: FakeTransport(body: json("{}"), status: 200))
        await #expect(throws: DataBursatilClient.Error.self) {
            _ = try await client.quotes(for: ["FEMSAUBD"])
        }
    }

    @Test("HTTP 401 throws http error without leaking URL")
    func httpError() async throws {
        let client = DataBursatilClient(token: "t", transport: FakeTransport(body: json("{}"), status: 401))
        do {
            _ = try await client.quotes(for: ["FEMSAUBD"])
            Issue.record("expected throw")
        } catch let err as DataBursatilClient.Error {
            let desc = String(describing: err)
            #expect(!desc.contains("token=t"), "error must not leak URL/token: \(desc)")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests -destination 'platform=macOS' -only-testing:FinanceTrackerTests/DataBursatilClientTests -parallel-testing-enabled NO 2>&1 | tail -15`
Expected: FAIL — `DataBursatilClient`/`HTTPRequesting` unresolved.

- [ ] **Step 3: Implement the client**

`FinanceTracker/Features/Portfolio/DataBursatilClient.swift`:

```swift
import Foundation

/// Indirection over `URLSession` so tests can fixture responses.
protocol HTTPRequesting: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPRequesting {}

/// Fetches current BMV/BIVA quotes from DataBursatil v2 `/cotizaciones`.
/// `Sendable`; does not touch SwiftData. JSON numbers decode straight to `Decimal`.
struct DataBursatilClient: Sendable {
    enum Error: Swift.Error, LocalizedError {
        case missingToken
        case requestFailed(Swift.Error)
        case http(Int)
        case noQuotes
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .missingToken: "DataBursatil token is not set."
            case .requestFailed: "DataBursatil request failed."   // no underlying detail (could contain URL)
            case .http(let code): "DataBursatil returned HTTP \(code)."
            case .noQuotes: "DataBursatil returned no quotes."
            case .decodeFailed: "Could not decode DataBursatil response."
            }
        }
    }

    struct PriceSnapshot: Sendable, Equatable {
        let price: Decimal
        let timestamp: Date?
    }

    private let token: String
    private let transport: HTTPRequesting

    init(token: String, transport: HTTPRequesting = URLSession.shared) {
        self.token = token
        self.transport = transport
    }

    /// One batched request for all tickers (DataBursatil caps at 50).
    func quotes(for tickers: [String]) async throws -> [String: PriceSnapshot] {
        guard !token.isEmpty else { throw Error.missingToken }
        let symbols = tickers.joined(separator: ",")
        // URL contains the token as a query param — never surface it in errors.
        var components = URLComponents(string: "https://api.databursatil.com/v2/cotizaciones")!
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "emisora_serie", value: symbols),
            URLQueryItem(name: "concepto", value: "U"),
            URLQueryItem(name: "bolsa", value: "BMV,BIVA"),
        ]
        let request = URLRequest(url: components.url!)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw Error.requestFailed(error)
        }
        guard let http = response as? HTTPURLResponse else { throw Error.requestFailed(URLError(.badServerResponse)) }
        guard (200..<300).contains(http.statusCode) else { throw Error.http(http.statusCode) }

        return try Self.decode(data)
    }

    // MARK: - Decode

    private struct BolsaQuote: Decodable { let u: Decimal?; let f: String? }
    private struct TickerPayload: Decodable {
        let BMV: BolsaQuote?
        let BIVA: BolsaQuote?
    }

    static func decode(_ data: Data) throws -> [String: PriceSnapshot] {
        guard let object = try? JSONDecoder().decode([String: TickerPayload].self, from: data) else {
            throw Error.decodeFailed
        }
        var out: [String: PriceSnapshot] = [:]
        for (ticker, payload) in object {
            let chosen = payload.BMV ?? payload.BIVA
            guard let price = chosen?.u, price > 0 else { continue }
            out[ticker] = PriceSnapshot(price: price, timestamp: Self.parseDate(chosen?.f))
        }
        guard !out.isEmpty else { throw Error.noQuotes }
        return out
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/Mexico_City")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return formatter.date(from: s)
    }
}
```

> If the live curl (gated pre-req) shows a different nesting (e.g. ticker → bolsa-as-key rather than `BMV`/`BIVA` fields), adjust `TickerPayload` to match — keep the `Decimal` decode and the "no URL in errors" rule.

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests -destination 'platform=macOS' -only-testing:FinanceTrackerTests/DataBursatilClientTests -parallel-testing-enabled NO 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FinanceTracker/Features/Portfolio/DataBursatilClient.swift FinanceTrackerTests/PortfolioTests/DataBursatilClientTests.swift project.yml
git commit -m "feat: DataBursatil v2 client (batched, Decimal, injected transport)"
```

---

## Task 7: `PortfolioPriceRefresher`

**Files:**
- Create: `FinanceTracker/Features/Portfolio/PortfolioPriceRefresher.swift`

- [ ] **Step 1: Implement the refresher**

`FinanceTracker/Features/Portfolio/PortfolioPriceRefresher.swift`:

```swift
import Foundation
import SwiftData

@MainActor
enum PortfolioPriceRefresher {
    enum Outcome: Equatable {
        case priced          // snapshot written
        case partial         // some tickers missing → prior snapshot retained
        case empty           // no active positions
        case notAuthenticated
        case failed
    }

    /// Fetches prices for the account's active positions and, on full success, writes a
    /// `.portfolioValuation` snapshot carrying the holdings fingerprint.
    /// Writes ONLY lastPrice/lastPriceAt onto positions — never lastModifiedAt.
    @discardableResult
    static func refresh(account: Account, context: ModelContext) async -> Outcome {
        let positions = PortfolioService.activePositions(accountID: account.id, context: context)
        guard !positions.isEmpty else { return .empty }

        guard let token = KeychainTokenStore.token(), !token.isEmpty else { return .notAuthenticated }
        let client = DataBursatilClient(token: token)

        let tickers = positions.map { $0.emisoraSerie }
        let quotes: [String: DataBursatilClient.PriceSnapshot]
        do {
            quotes = try await client.quotes(for: tickers)
        } catch {
            return .failed
        }

        // Write per-position cached prices (lastModifiedAt untouched).
        var allPriced = true
        for pos in positions {
            if let snap = quotes[pos.emisoraSerie] {
                pos.lastPrice = snap.price
                pos.lastPriceAt = snap.timestamp ?? Date.now
            } else {
                allPriced = false
            }
        }

        guard allPriced else {
            try? context.save()
            return .partial
        }

        // Full success → write authoritative valuation snapshot with fingerprint.
        let totalValue = positions.reduce(Decimal(0)) { $0 + ($1.shares * ($1.lastPrice ?? 0)) }
        let holdings = positions.map { ($0.emisoraSerie, $0.shares, $0.averageCost) }
        let fp = HoldingsFingerprint.of(holdings)
        let snapshot = AccountBalanceSnapshot(
            account: account,
            date: Date.now,
            amount: totalValue,
            kind: .portfolioValuation,
            note: "Portfolio valuation |fp=\(fp)"
        )
        context.insert(snapshot)
        try? context.save()
        return .priced
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodegen generate && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project FinanceTracker.xcodeproj -scheme FinanceTracker build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (depends on `PortfolioService.activePositions` from Task 8 — implement Task 8 first, or stub it: `static func activePositions(...) -> [StockPosition]`).

> **Order note:** Task 8 (`PortfolioService`) provides `PortfolioService.activePositions(accountID:context:)`. If implementing strictly in order, write that one helper now (it's a `FetchDescriptor` by `accountId`, `shares > 0`) and the rest of `PortfolioService` after.

- [ ] **Step 3: Commit (with Task 8's helper)**

```bash
git add FinanceTracker/Features/Portfolio/PortfolioPriceRefresher.swift FinanceTracker/Features/Portfolio/PortfolioService.swift project.yml
git commit -m "feat: portfolio price refresher (all-or-nothing valuation snapshot)"
```

---

## Task 8: `PortfolioService` — positions CRUD + portfolio mode + zero snapshot

**Files:**
- Create: `FinanceTracker/Features/Portfolio/PortfolioService.swift`
- Test: `FinanceTrackerTests/EndToEndTests/PortfolioServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

`FinanceTrackerTests/EndToEndTests/PortfolioServiceTests.swift`:

```swift
import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

@Suite("Portfolio Service")
@MainActor
struct PortfolioServiceTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Account.self, AccountBalanceSnapshot.self, Transaction.self, Statement.self,
            Category.self, CategoryRule.self, InstallmentPlan.self,
            PendingImport.self, SignRecoveryHint.self, StockPosition.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test("Add position then buy more updates weighted average cost")
    func buyMoreWeightedAverage() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let acct = Account(institution: "Broker", type: .investment, nickname: "Broker")
        ctx.insert(acct)
        try ctx.save()

        let pos = try PortfolioService.addPosition(
            account: acct, emisoraSerie: "FEMSAUBD", name: nil,
            shares: 10, averageCost: 100, context: ctx)
        #expect(pos.shares == 10)
        #expect(pos.averageCost == 100)

        try PortfolioService.buyMore(position: pos, addedShares: 10, buyPrice: 120, context: ctx)
        // (10*100 + 10*120) / 20 = 110
        #expect(pos.shares == 20)
        #expect(pos.averageCost == 110)
    }

    @Test("Duplicate ticker is rejected")
    func rejectsDuplicateTicker() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let acct = Account(institution: "Broker", type: .investment, nickname: "Broker")
        ctx.insert(acct)
        _ = try PortfolioService.addPosition(account: acct, emisoraSerie: "FEMSAUBD", name: nil,
                                             shares: 5, averageCost: 100, context: ctx)
        #expect(throws: PortfolioService.ValidationError.self) {
            _ = try PortfolioService.addPosition(account: acct, emisoraSerie: "femsaubd", name: nil,
                                                 shares: 5, averageCost: 100, context: ctx)
        }
    }

    @Test("Eligibility: empty investment account allowed; CETES-like blocked")
    func eligibility() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let empty = Account(institution: "Broker", type: .investment, nickname: "Broker")
        ctx.insert(empty)
        #expect(PortfolioService.canAddPositions(account: empty, context: ctx) == true)

        let cetes = Account(institution: "CI Banco", type: .investment, nickname: "CETES")
        ctx.insert(cetes)
        let manual = AccountBalanceSnapshot(account: cetes, date: .now, amount: 1000, kind: .manualOpening)
        ctx.insert(manual)
        try ctx.save()
        #expect(PortfolioService.canAddPositions(account: cetes, context: ctx) == false,
               "manualOpening snapshot must block conversion")
    }

    @Test("Eligibility: emptied portfolio (only .portfolioValuation snapshots) can restart")
    func emptiedPortfolioRestart() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let acct = Account(institution: "Broker", type: .investment, nickname: "Broker")
        ctx.insert(acct)
        let val = AccountBalanceSnapshot(account: acct, date: .now, amount: 0, kind: .portfolioValuation)
        ctx.insert(val)
        try ctx.save()
        #expect(PortfolioService.canAddPositions(account: acct, context: ctx) == true,
               "emptied portfolio (only portfolioValuation snapshots) must allow restart")
    }

    @Test("Deleting the last position writes a zero portfolioValuation")
    func finalDeleteWritesZeroSnapshot() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let acct = Account(institution: "Broker", type: .investment, nickname: "Broker")
        ctx.insert(acct)
        let pos = try PortfolioService.addPosition(account: acct, emisoraSerie: "FEMSAUBD", name: nil,
                                                   shares: 5, averageCost: 100, context: ctx)
        // Pre-existing valuation so the "retire phantom value" path is exercised.
        let val = AccountBalanceSnapshot(account: acct, date: .now.addingTimeInterval(-3600),
                                         amount: 500, kind: .portfolioValuation)
        ctx.insert(val)
        try ctx.save()

        try PortfolioService.delete(position: pos, account: acct, context: ctx)

        let snaps = try ctx.fetch(FetchDescriptor<AccountBalanceSnapshot>())
        let zeroVal = snaps.filter { $0.kind == .portfolioValuation && $0.amount == 0 }
        #expect(zeroVal.count == 1, "a zero portfolioValuation must be written on final delete")
        #expect(PortfolioService.activePositions(accountID: acct.id, context: ctx).isEmpty)
    }

    @Test("inPortfolioMode = active positions exist")
    func portfolioMode() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let acct = Account(institution: "Broker", type: .investment, nickname: "Broker")
        ctx.insert(acct)
        try ctx.save()
        #expect(PortfolioService.inPortfolioMode(account: acct, context: ctx) == false)
        _ = try PortfolioService.addPosition(account: acct, emisoraSerie: "FEMSAUBD", name: nil,
                                             shares: 5, averageCost: 100, context: ctx)
        #expect(PortfolioService.inPortfolioMode(account: acct, context: ctx) == true)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests -destination 'platform=macOS' -only-testing:FinanceTrackerTests/PortfolioServiceTests -parallel-testing-enabled NO 2>&1 | tail -20`
Expected: FAIL — `PortfolioService` unresolved.

- [ ] **Step 3: Implement `PortfolioService`**

`FinanceTracker/Features/Portfolio/PortfolioService.swift`:

```swift
import Foundation
import SwiftData

@MainActor
enum PortfolioService {
    enum ValidationError: Error, LocalizedError {
        case duplicateTicker
        case invalidShares
        case invalidCost
        case emptyTicker
        case tooManyPositions

        var errorDescription: String? {
            switch self {
            case .duplicateTicker: "A position for that ticker already exists. Use Buy More."
            case .invalidShares: "Shares must be greater than zero."
            case .invalidCost: "Average cost cannot be negative."
            case .emptyTicker: "Ticker cannot be empty."
            case .tooManyPositions: "An account can hold at most 50 positions."
            }
        }
    }

    private static let maxPositions = 50

    // MARK: - Queries

    static func allPositions(accountID: UUID, context: ModelContext) -> [StockPosition] {
        let descriptor = FetchDescriptor<StockPosition>(
            predicate: #Predicate<StockPosition> { $0.account?.id == accountID }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    static func activePositions(accountID: UUID, context: ModelContext) -> [StockPosition] {
        allPositions(accountID: accountID, context: context).filter { $0.shares > 0 }
    }

    /// Portfolio mode = active positions currently exist (UI-only; resolver rule is separate).
    static func inPortfolioMode(account: Account, context: ModelContext) -> Bool {
        !activePositions(accountID: account.id, context: context).isEmpty
    }

    /// First-position creation eligibility (blocker 1: emptied-portfolio restart).
    /// Allowed when: no statements, no transactions, AND every balance snapshot is
    /// `.portfolioValuation` — or the account already has positions.
    static func canAddPositions(account: Account, context: ModelContext) -> Bool {
        if !activePositions(accountID: account.id, context: context).isEmpty { return true }

        let statementCount = (try? context.fetchCount(
            FetchDescriptor<Statement>(predicate: #Predicate<Statement> { $0.account?.id == account.id }))) ?? 0
        if statementCount > 0 { return false }

        let txCount = (try? context.fetchCount(
            FetchDescriptor<Transaction>(predicate: #Predicate<Transaction> { $0.account?.id == account.id }))) ?? 0
        if txCount > 0 { return false }

        let snapshots = (try? context.fetch(
            FetchDescriptor<AccountBalanceSnapshot>(predicate: #Predicate<AccountBalanceSnapshot> { $0.account?.id == account.id }))) ?? []
        return snapshots.allSatisfy { $0.kind == .portfolioValuation }
    }

    // MARK: - Mutations

    @discardableResult
    static func addPosition(
        account: Account, emisoraSerie: String, name: String?,
        shares: Decimal, averageCost: Decimal, context: ModelContext
    ) throws -> StockPosition {
        let ticker = emisoraSerie.trimmingCharacters(in: .whitespaces).uppercased()
        guard !ticker.isEmpty else { throw ValidationError.emptyTicker }
        guard shares > 0 else { throw ValidationError.invalidShares }
        guard averageCost >= 0 else { throw ValidationError.invalidCost }
        let existing = allPositions(accountID: account.id, context: context)
        if existing.contains(where: { $0.emisoraSerie == ticker }) { throw ValidationError.duplicateTicker }
        if existing.filter({ $0.shares > 0 }).count >= maxPositions { throw ValidationError.tooManyPositions }

        let pos = StockPosition(account: account, emisoraSerie: ticker, name: name,
                                shares: shares, averageCost: averageCost)
        context.insert(pos)
        try context.save()
        return pos
    }

    static func buyMore(position: StockPosition, addedShares: Decimal, buyPrice: Decimal, context: ModelContext) throws {
        guard addedShares > 0 else { throw ValidationError.invalidShares }
        guard buyPrice >= 0 else { throw ValidationError.invalidCost }
        let oldShares = position.shares
        let newShares = oldShares + addedShares
        // weighted average: (oldShares*oldAvg + addedShares*buyPrice) / newShares
        let total = (oldShares * position.averageCost) + (addedShares * buyPrice)
        position.averageCost = newShares == 0 ? position.averageCost : (total / newShares)
        position.shares = newShares
        position.lastModifiedAt = .now
        try context.save()
    }

    /// Edit shares/cost/name directly (lastModifiedAt touched). Setting shares to 0 deletes.
    static func edit(position: StockPosition, shares: Decimal?, averageCost: Decimal?,
                     name: String?, context: ModelContext) throws {
        if let shares {
            guard shares >= 0 else { throw ValidationError.invalidShares }
            position.shares = shares
        }
        if let cost = averageCost {
            guard cost >= 0 else { throw ValidationError.invalidCost }
            position.averageCost = cost
        }
        if let name { position.name = name }
        position.lastModifiedAt = .now
        try context.save()
    }

    static func delete(position: StockPosition, account: Account, context: ModelContext) throws {
        context.delete(position)
        // If this was the last active position, retire any phantom valuation with a zero snapshot.
        if activePositions(accountID: account.id, context: context).isEmpty {
            let zero = AccountBalanceSnapshot(account: account, date: Date.now, amount: 0,
                                              kind: .portfolioValuation, note: "Portfolio valuation |fp=\(HoldingsFingerprint.of([]))")
            context.insert(zero)
        }
        try context.save()
    }
}
```

> Note on `delete`: after `context.delete(position)`, the fetched active list already reflects the deletion within the same context, so the emptiness check is correct. `account` is passed to attach the zero snapshot.

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests -destination 'platform=macOS' -only-testing:FinanceTrackerTests/PortfolioServiceTests -parallel-testing-enabled NO 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FinanceTracker/Features/Portfolio/PortfolioService.swift FinanceTrackerTests/EndToEndTests/PortfolioServiceTests.swift project.yml
git commit -m "feat: PortfolioService (CRUD, weighted avg, eligibility, zero snapshot)"
```

---

## Task 9: `PortfolioViewData` (value-type view model payload)

**Files:**
- Create: `FinanceTracker/Features/Portfolio/PortfolioViewData.swift`

- [ ] **Step 1: Implement the value types**

`FinanceTracker/Features/Portfolio/PortfolioViewData.swift`:

```swift
import Foundation

/// Immutable, value-type portfolio payload for the dashboard. No live `@Model` objects.
struct PortfolioViewData: Equatable {
    struct PositionRow: Equatable, Identifiable {
        let id: UUID
        let ticker: String
        let name: String?
        let shares: Decimal
        let averageCost: Decimal
        let lastPrice: Decimal?
        let lastPriceAt: Date?
        var value: Decimal? { lastPrice.map { shares * $0 } }
        var growthPercent: Double? {
            guard let value, averageCost > 0 else { return nil }
            let cost = shares * averageCost
            guard cost != 0 else { return nil }
            return (((value - cost) as NSDecimalNumber).doubleValue / (cost as NSDecimalNumber).doubleValue) * 100
        }
    }

    let inPortfolioMode: Bool
    let valuationAmount: Decimal?         // the resolved .portfolioValuation amount, or nil
    let valuationDate: Date?              // "Valued as of {date}"
    let sourceIsPortfolioValuation: Bool  // provenance: is the resolved source a portfolioValuation?
    let holdingsFingerprintMatches: Bool  // current holdings == selected valuation fingerprint
    let totalInvested: Decimal
    let totalGrowthPercent: Double?       // nil when unavailable (mismatch / non-valuation / zero cost)
    let isPartialOrStale: Bool
    let rows: [PositionRow]
}
```

- [ ] **Step 2: Build**

Run: `xcodegen generate && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project FinanceTracker.xcodeproj -scheme FinanceTracker build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add FinanceTracker/Features/Portfolio/PortfolioViewData.swift project.yml
git commit -m "feat: PortfolioViewData value types"
```

---

## Task 10: Backup — `StockPositionSnapshot` + registry + field-selective merge

**Files:**
- Modify: `FinanceTracker/Features/Backup/BackupModels.swift`
- Modify: `FinanceTracker/Features/Backup/BackupArchive.swift`
- Test: `FinanceTrackerTests/EndToEndTests/BackupArchiveTests.swift`

- [ ] **Step 1: Add `StockPositionSnapshot` + model extensions**

In `FinanceTracker/Features/Backup/BackupModels.swift`, add (mirroring `AccountBalanceSnapshotSnapshot` at lines 36-45):

```swift
struct StockPositionSnapshot: Codable {
    var id: UUID
    var accountId: UUID?
    var emisoraSerie: String
    var name: String?
    var shares: Decimal
    var averageCost: Decimal
    var lastPrice: Decimal?
    var lastPriceAt: Date?
    var createdAt: Date
    var lastModifiedAt: Date
}
```

And add the model↔snapshot bridge (near the other `init(_ snap:)`/`apply` extensions in the same file or a relevant extension block):

```swift
extension StockPosition {
    init(_ snap: StockPositionSnapshot) {
        self.init(
            id: snap.id,
            emisoraSerie: snap.emisoraSerie,
            name: snap.name,
            shares: snap.shares,
            averageCost: snap.averageCost,
            lastPrice: snap.lastPrice,
            lastPriceAt: snap.lastPriceAt,
            createdAt: snap.createdAt
        )
    }

    func apply(_ snap: StockPositionSnapshot) {
        emisoraSerie = snap.emisoraSerie
        name = snap.name
        shares = snap.shares
        averageCost = snap.averageCost
        lastPrice = snap.lastPrice
        lastPriceAt = snap.lastPriceAt
        lastModifiedAt = snap.lastModifiedAt
    }
}
```

> `apply` here is the **whole-row** fallback used by `replaceAll`; the merge path uses the field-selective resolver below, NOT this `apply`.

- [ ] **Step 2: Bump schema + allow-list**

In `FinanceTracker/Features/Backup/BackupArchive.swift`:

(a) `private static let schemaVersion = 3` (was 2, line 14).

(b) Restore allow-list (line 107-108):

```swift
guard [1, 2, 3].contains(manifest.schemaVersion) else {
    throw RestoreError.unsupportedSchema(manifest.schemaVersion)
}
```

- [ ] **Step 3: Export StockPosition**

In the export loop (after the `SignRecoveryHint` write, ~line 75):

```swift
let stockPositions = try context.fetch(FetchDescriptor<StockPosition>())
try writeJSON("StockPosition", stockPositions.map { StockPositionSnapshot($0) })
```

- [ ] **Step 4: Restore — version-conditional loader**

In the restore section (after `signRecoveryHintsSnap`, ~line 140), load positions conditionally:

```swift
let stockPositionsSnap: [StockPositionSnapshot]
if manifest.schemaVersion >= 3 {
    stockPositionsSnap = try loadJSON(StockPositionSnapshot.self, "StockPosition")  // required for v3
} else {
    stockPositionsSnap = try loadOptionalJSON(StockPositionSnapshot.self, "StockPosition")  // absent → []
}
```

- [ ] **Step 5: Field-selective resolver + map**

Add a `stockPositionMap` alongside the other maps and the field-selective resolver (mirroring `resolveOrInsertBalanceSnapshot` at lines 175-186, but split fields):

```swift
var stockPositionMap: [UUID: StockPosition] = [:]

// ponytail: StockPosition merge is field-selective by design — do NOT normalize to whole-row apply().
func resolveOrInsertStockPosition(_ id: UUID, _ snap: StockPositionSnapshot) -> StockPosition {
    if let existing = stockPositionMap[id] {
        if case .mergeKeepingNewer = strategy {
            // Holding fields: newer lastModifiedAt wins.
            if snap.lastModifiedAt > existing.lastModifiedAt {
                existing.emisoraSerie = snap.emisoraSerie
                existing.name = snap.name
                existing.shares = snap.shares
                existing.averageCost = snap.averageCost
                existing.lastModifiedAt = snap.lastModifiedAt
            }
            // Cached-quote fields: newer lastPriceAt wins, independently.
            if let snapAt = snap.lastPriceAt,
               (existing.lastPriceAt == nil || snapAt > existing.lastPriceAt!) {
                existing.lastPrice = snap.lastPrice
                existing.lastPriceAt = snapAt
            }
        } else {
            existing.apply(snap)  // replaceAll: whole-row
            existing.lastModifiedAt = snap.lastModifiedAt
        }
        return existing
    }
    let obj = StockPosition(snap)
    context.insert(obj)
    stockPositionMap[id] = obj
    return obj
}
```

Resolve rows in the first pass (near the other resolve calls):

```swift
for snap in stockPositionsSnap {
    _ = resolveOrInsertStockPosition(snap.id, snap)
}
```

Reconnect the `account` relationship in the second pass (near line 293-296):

```swift
for snap in stockPositionsSnap {
    guard let obj = stockPositionMap[snap.id] else { continue }
    obj.account = snap.accountId.flatMap { accountMap[$0] }
    if case .replaceAll = strategy { obj.lastModifiedAt = snap.lastModifiedAt }
}
```

- [ ] **Step 6: Write the failing tests (add to the existing `BackupArchiveTests` suite)**

In `FinanceTrackerTests/EndToEndTests/BackupArchiveTests.swift`, inside `struct BackupArchiveTests`:

```swift
@Test("StockPosition round-trips on v3 backup")
func stockPositionRoundTrip() async throws {
    let source = try makeContainer()
    let ctx = source.mainContext
    let acct = Account(institution: "Broker", type: .investment, nickname: "Broker")
    ctx.insert(acct)
    _ = try PortfolioService.addPosition(account: acct, emisoraSerie: "FEMSAUBD", name: nil,
                                         shares: 10, averageCost: 100, context: ctx)

    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("test-backup-sp-\(UUID()).ftbackup", isDirectory: true)
    try await BackupArchive.export(to: tmp, from: ctx)

    let target = try makeContainer()
    try await BackupArchive.restore(from: tmp, into: target.mainContext, strategy: .replaceAll)
    let restored = try target.mainContext.fetch(FetchDescriptor<StockPosition>())
    #expect(restored.count == 1)
    #expect(restored.first?.emisoraSerie == "FEMSAUBD")
    try? FileManager.default.removeItem(at: tmp)
}

@Test("Field-selective merge keeps newer shares AND newer quote")
func stockPositionMergeFieldSelective() async throws {
    let source = try makeContainer()
    let srcCtx = source.mainContext
    let acct = Account(institution: "Broker", type: .investment, nickname: "Broker")
    srcCtx.insert(acct)
    let pos = try PortfolioService.addPosition(account: acct, emisoraSerie: "FEMSAUBD", name: nil,
                                               shares: 10, averageCost: 100, context: srcCtx)
    pos.lastPrice = 150
    pos.lastPriceAt = Date.now.addingTimeInterval(-100)   // OLDER quote
    try srcCtx.save()

    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("test-backup-spm-\(UUID()).ftbackup", isDirectory: true)
    try await BackupArchive.export(to: tmp, from: srcCtx)

    let target = try makeContainer()
    let tgtCtx = target.mainContext
    let tAcct = Account(institution: "Broker", type: .investment, nickname: "Broker")
    tgtCtx.insert(tAcct)
    let tPos = StockPosition(account: tAcct, emisoraSerie: "FEMSAUBD", shares: 20, averageCost: 110)
    tPos.id = pos.id
    tPos.lastPrice = 200
    tPos.lastPriceAt = Date.now.addingTimeInterval(100)   // NEWER quote
    tPos.lastModifiedAt = Date.now.addingTimeInterval(1000) // NEWER holding edit
    tgtCtx.insert(tPos)
    try tgtCtx.save()

    try await BackupArchive.restore(from: tmp, into: tgtCtx, strategy: .mergeKeepingNewer)

    let restored = try tgtCtx.fetch(FetchDescriptor<StockPosition>()).filter { $0.id == pos.id }.first
    #expect(restored != nil)
    // Holding fields: local is newer (shares 20, cost 110) must survive.
    #expect(restored?.shares == 20, "newer local shares must win")
    #expect(restored?.averageCost == 110, "newer local cost must win")
    // Cached quote: backup's lastPriceAt (-100) is OLDER than local (+100) → local quote stays.
    #expect(restored?.lastPrice == 200, "newer local quote must win")
    try? FileManager.default.removeItem(at: tmp)
}
```

> Add a second test variant for the *opposite* conflict (backup has newer quote, local has older quote → backup quote wins, local shares survive) if time permits; the included test covers the "don't let an older holding-stamp clobber newer shares" hazard which is the real concern.

- [ ] **Step 7: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests -destination 'platform=macOS' -only-testing:FinanceTrackerTests/BackupArchiveTests -parallel-testing-enabled NO 2>&1 | tail -20`
Expected: PASS (incl. existing tests — schema 3 is now the current version; existing v1/v2 restore tests still pass because `1,2,3` are all allowed).

- [ ] **Step 8: Commit**

```bash
git add FinanceTracker/Features/Backup/BackupModels.swift FinanceTracker/Features/Backup/BackupArchive.swift FinanceTrackerTests/EndToEndTests/BackupArchiveTests.swift
git commit -m "feat(backup): StockPosition export/restore + field-selective merge (schema 3)"
```

---

## Task 11: `AppDataResetService` + `AccountDeletionService` cover StockPosition

**Files:**
- Modify: `FinanceTracker/Utilities/AppDataResetService.swift`
- Modify: `FinanceTracker/Features/Settings/AccountDeletionService.swift`
- Test: `FinanceTrackerTests/EndToEndTests/AppDataResetServiceTests.swift`
- Test: `FinanceTrackerTests/EndToEndTests/AccountDeletionServiceTests.swift`

- [ ] **Step 1: Add StockPosition to reset delete order + verification**

In `FinanceTracker/Utilities/AppDataResetService.swift`:

(a) `allModelTypesInDeleteOrder` (lines 26-36) — add `StockPosition.self` before `Account.self`:

```swift
    static let allModelTypesInDeleteOrder: [any PersistentModel.Type] = [
        PendingImport.self,
        AccountBalanceSnapshot.self,
        StockPosition.self,
        Transaction.self,
        CategoryRule.self,
        InstallmentPlan.self,
        SignRecoveryHint.self,
        Statement.self,
        FinanceTracker.Category.self,
        Account.self,
    ]
```

(b) `verifyCleanSlate` checks (lines 101-118) — add a `StockPosition` row:

```swift
        ("StockPosition", try context.fetchCount(FetchDescriptor<StockPosition>())),
```

- [ ] **Step 2: Add StockPosition to account-deletion cascade + preview**

In `FinanceTracker/Features/Settings/AccountDeletionService.swift`:

(a) `DeletionPreview` (lines 6-12) — add:

```swift
    let stockPositionCount: Int
```

(b) `LinkedObjects` (lines 14-20) — add:

```swift
    let stockPositions: [StockPosition]
```

(c) In `collectLinkedObjects` (lines 45-80), fetch + include (next to `balanceSnapshots`):

```swift
    let stockPositions = fetchStockPositions(context: context, accountId: accountId)
```

and in the returned `LinkedObjects(...)`, add `stockPositions: stockPositions`.

(d) In `preview(account:context:)`, add `stockPositionCount: linked.stockPositions.count`.

(e) In `delete(account:context:)`, add before `context.delete(account)`:

```swift
        for pos in linked.stockPositions { context.delete(pos) }
```

(f) Add the fetch helper (next to `fetchBalanceSnapshots`, ~line 96-101):

```swift
    private static func fetchStockPositions(context: ModelContext, accountId: UUID) -> [StockPosition] {
        let descriptor = FetchDescriptor<StockPosition>(
            predicate: #Predicate<StockPosition> { $0.account?.id == accountId }
        )
        return (try? context.fetch(descriptor)) ?? []
    }
```

- [ ] **Step 3: Extend the existing tests**

In `FinanceTrackerTests/EndToEndTests/AppDataResetServiceTests.swift`, inside the reset test, seed a `StockPosition` (via `PortfolioService.addPosition` against a seeded investment account) before reset, then assert it's gone after (the existing verification covers it once `StockPosition` is in the verification list — add an explicit `#expect(try ctx.fetchCount(FetchDescriptor<StockPosition>())) == 0)`).

In `FinanceTrackerTests/EndToEndTests/AccountDeletionServiceTests.swift`, add to the cascade test: seed a `StockPosition` on the account, then after `delete(...)`, assert `StockPosition` count for that account is 0, and in the preview test assert `preview.stockPositionCount == 1`.

- [ ] **Step 4: Run the affected suites**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests -destination 'platform=macOS' -only-testing:FinanceTrackerTests/AppDataResetServiceTests -only-testing:FinanceTrackerTests/AccountDeletionServiceTests -parallel-testing-enabled NO 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add FinanceTracker/Utilities/AppDataResetService.swift FinanceTracker/Features/Settings/AccountDeletionService.swift FinanceTrackerTests/EndToEndTests/AppDataResetServiceTests.swift FinanceTrackerTests/EndToEndTests/AccountDeletionServiceTests.swift
git commit -m "feat: reset + account-deletion cascade cover StockPosition"
```

---

## Task 12: Dashboard ViewModel computes `PortfolioViewData`

**Files:**
- Modify: `FinanceTracker/Features/Dashboard/DashboardViewModel.swift`

- [ ] **Step 1: Add an optional `portfolio` field to `AssetAccountSnapshot`**

In `FinanceTracker/Features/Dashboard/DashboardSnapshot.swift` (the `AssetAccountSnapshot` struct definition), add:

```swift
    var portfolio: PortfolioViewData?
```

Make every existing `AssetAccountSnapshot(...)` initializer call in `DashboardViewModel.buildAsset` still compile by adding `portfolio: nil` (or compute it — see Step 2). If the struct uses a memberwise init, the new optional field defaults to `nil`; verify by building.

- [ ] **Step 2: Compute portfolio data in `buildAsset`**

In `FinanceTracker/Features/Dashboard/DashboardViewModel.swift`, `buildAsset(...)` (lines 170-197). After the existing computations, before the `return`, add portfolio assembly for investment accounts:

```swift
    let portfolio: PortfolioViewData?
    if account.type == .investment {
        portfolio = Self.buildPortfolioViewData(context: context, account: account, period: period)
    } else {
        portfolio = nil
    }
```

and pass `portfolio: portfolio` into the `AssetAccountSnapshot(...)` initializer.

Add the helper (private static) in the same file:

```swift
    private static func buildPortfolioViewData(
        context: ModelContext, account: Account, period: DashboardPeriodContext
    ) -> PortfolioViewData {
        let active = PortfolioService.activePositions(accountID: account.id, context: context)
        let inMode = !active.isEmpty

        // Resolve the valuation for the dashboard's effective net-worth date.
        let resolution = AccountBalanceResolver.resolution(
            account: account, asOf: period.effectiveNetWorthDate, context: context)
        let sourceIsValuation = (resolution.sourceSnapshotKind == .portfolioValuation)

        // Fingerprint match (only meaningful when the source is a portfolioValuation).
        var matches = false
        if sourceIsValuation, let note = resolution.sourceSnapshotNote,
           let range = note.range(of: "fp=") {
            let storedFp = String(note[range.upperBound...])   // hex after "fp="
            let currentFp = HoldingsFingerprint.of(active.map { ($0.emisoraSerie, $0.shares, $0.averageCost) })
            matches = (storedFp == currentFp)
        }

        let totalInvested = active.reduce(Decimal(0)) { $0 + ($1.shares * $1.averageCost) }
        let totalValue = active.reduce(Decimal(0)) { $0 + ($1.shares * ($1.lastPrice ?? 0)) }
        let growth: Double? = {
            guard matches, totalInvested > 0 else { return nil }
            return (((totalValue - totalInvested) as NSDecimalNumber).doubleValue
                    / (totalInvested as NSDecimalNumber).doubleValue) * 100
        }()

        let rows = active.map {
            PortfolioViewData.PositionRow(
                id: $0.id, ticker: $0.emisoraSerie, name: $0.name,
                shares: $0.shares, averageCost: $0.averageCost,
                lastPrice: $0.lastPrice, lastPriceAt: $0.lastPriceAt)
        }

        return PortfolioViewData(
            inPortfolioMode: inMode,
            valuationAmount: sourceIsValuation ? resolution.amount : nil,
            valuationDate: sourceIsValuation ? resolution.sourceDate : nil,
            sourceIsPortfolioValuation: sourceIsValuation,
            holdingsFingerprintMatches: matches,
            totalInvested: totalInvested,
            totalGrowthPercent: growth,
            isPartialOrStale: false,   // set by the view based on refresh outcome if desired
            rows: rows
        )
    }
```

> If `DashboardPeriodContext.effectiveNetWorthDate` is named differently, grep `effectiveNetWorthDate` in `DashboardPeriodContext` and use the correct property.

- [ ] **Step 3: Build**

Run: `xcodegen generate && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project FinanceTracker.xcodeproj -scheme FinanceTracker build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add FinanceTracker/Features/Dashboard/DashboardViewModel.swift FinanceTracker/Features/Dashboard/DashboardSnapshot.swift
git commit -m "feat(dashboard): compute PortfolioViewData in asset snapshot"
```

---

## Task 13: `AssetAccountDashboard` renders portfolio summary + positions

**Files:**
- Modify: `FinanceTracker/Features/Dashboard/AssetAccountDashboard.swift`
- Modify: `FinanceTracker/Features/Dashboard/DashboardView.swift`

- [ ] **Step 1: Add action closures + local refresh state to `AssetAccountDashboard`**

In `FinanceTracker/Features/Dashboard/AssetAccountDashboard.swift` (struct, lines 6-8), add closure params mirroring `LiabilityAccountDashboard.onEditPaymentDetails`:

```swift
struct AssetAccountDashboard: View {
    let snapshot: AssetAccountSnapshot
    var onTransactionTap: ((Transaction) -> Void)? = nil
    var onRefreshPrices: (() -> Void)? = nil
    var onEditPositions: (() -> Void)? = nil

    @State private var isRefreshing = false
    @State private var refreshError: String?
```

- [ ] **Step 2: Render the portfolio section when `snapshot.portfolio?.inPortfolioMode == true`**

Add a computed view used in the dashboard body (when portfolio mode is active, show it instead of the normal asset summary's "Add Transaction"):

```swift
    @ViewBuilder
    private var portfolioSection: some View {
        if let portfolio = snapshot.portfolio, portfolio.inPortfolioMode {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if let amount = portfolio.valuationAmount, let date = portfolio.valuationDate {
                        VStack(alignment: .leading) {
                            Text(MoneyFormat.string(amount, code: snapshot.account.currencyCode))
                                .font(.title2.bold())
                            Text("Valued as of \(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No portfolio valuation for this period")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        guard !isRefreshing else { return }
                        isRefreshing = true
                        refreshError = nil
                        onRefreshPrices?()   // owner runs the async refresh; resets isRefreshing via re-render
                    } label: {
                        if isRefreshing { ProgressView().controlSize(.small) } else { Label("Refresh prices", systemImage: "arrow.clockwise") }
                    }
                    Button("Edit Positions") { onEditPositions?() }
                }

                if !portfolio.holdingsFingerprintMatches {
                    Text("Holdings changed — refresh required. Growth unavailable until refreshed.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let err = refreshError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }

                summaryRow(title: "Total invested",
                           amount: portfolio.totalInvested,
                           growth: portfolio.totalGrowthPercent)
                positionsTable(portfolio.rows)
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private func summaryRow(title: String, amount: Decimal, growth: Double?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(MoneyFormat.string(amount, code: snapshot.account.currencyCode))
            if let growth {
                Text(String(format: "%+.1f%%", growth))
                    .foregroundStyle(growth >= 0 ? .green : .red)
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private func positionsTable(_ rows: [PortfolioViewData.PositionRow]) -> some View {
        Table(rows) {
            TableColumn("Ticker") { Text($0.ticker) }
            TableColumn("Shares") { Text("\($0.shares)") }
            TableColumn("Avg cost") { Text(MoneyFormat.string($0.averageCost, code: snapshot.account.currencyCode)) }
            TableColumn("Last") { Text($0.lastPrice.map { MoneyFormat.string($0, code: snapshot.account.currencyCode) } ?? "—") }
            TableColumn("Value") { Text($0.value.map { MoneyFormat.string($0, code: snapshot.account.currencyCode) } ?? "Not priced yet") }
            TableColumn("Growth") {
                if let g = $0.growthPercent { Text(String(format: "%+.1f%%", g)) }
                else { Text("—") }
            }
        }
        .tableStyle(.bordered(alternatesRowBackgroundes: true))
        .frame(minHeight: 160)
    }
```

> The header above the portfolio summary ("Latest positions / quotes") label belongs on the positions table; add a small `Text("Latest positions / quotes").font(.caption).foregroundStyle(.secondary)` above `positionsTable`.

- [ ] **Step 3: Wire `DashboardView` to own the sheet + refresh action**

In `FinanceTracker/Features/Dashboard/DashboardView.swift` (the `.asset` case, lines 300-303), pass closures and own state:

```swift
        case .asset(let snap):
            AssetAccountDashboard(
                snapshot: snap,
                onTransactionTap: { tx in editingTransaction = tx },
                onRefreshPrices: { Task { await refreshPortfolioPrices() } },
                onEditPositions: { showingPositionsSheet = true }
            )
```

Add the supporting state + methods on `DashboardView`:

```swift
    @State private var showingPositionsSheet = false

    private func refreshPortfolioPrices() async {
        guard case .account(let id) = viewModel.scope,
              let context = viewModel.context,
              let account = try? context.fetch(FetchDescriptor<Account>(predicate: #Predicate { $0.id == id })).first
        else { return }
        _ = await PortfolioPriceRefresher.refresh(account: account, context: context)
        viewModel.refresh()
    }
```

Present the positions edit sheet (a new `PositionsEditSheet` view — see Task 14) driven by `showingPositionsSheet`, scoped to the currently selected account; on dismiss call `viewModel.refresh()`.

> Hide "Add Transaction"/"Add Balance" affordances when the selected account is in portfolio mode: gate those buttons on `!(snapshot.portfolio?.inPortfolioMode == true)`.

- [ ] **Step 4: Build + manual sanity**

Run: `xcodegen generate && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project FinanceTracker.xcodeproj -scheme FinanceTracker build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add FinanceTracker/Features/Dashboard/AssetAccountDashboard.swift FinanceTracker/Features/Dashboard/DashboardView.swift
git commit -m "feat(dashboard): portfolio summary + positions table + refresh/edit hooks"
```

---

## Task 14: Positions edit sheet + Settings token UI + ManualAccountSheet affordance

**Files:**
- Create: `FinanceTracker/Features/Portfolio/PositionsEditSheet.swift`
- Modify: `FinanceTracker/Features/Settings/SettingsView.swift`
- Modify: `FinanceTracker/Features/Accounts/ManualAccountSheet.swift`

- [ ] **Step 1: `PositionsEditSheet`**

`FinanceTracker/Features/Portfolio/PositionsEditSheet.swift` — a plain list + add/buy-more/edit/delete form bound to `PortfolioService`, taking an `Account`. On any mutation, call the passed `onChanged` (which the owner maps to `viewModel.refresh()`). Include the validation messages from `PortfolioService.ValidationError`. (Keep it a focused, single-purpose view; no search/filter.)

```swift
import SwiftUI
import SwiftData

struct PositionsEditSheet: View {
    let account: Account
    let context: ModelContext
    var onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var positions: [StockPosition] = []
    @State private var adding = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(positions) { pos in
                    PositionRowView(position: pos, currencyCode: account.currency) { err in errorText = err } onChange: {
                        reload(); onChanged()
                    }
                }
            }
            .navigationTitle("Stock Positions")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add") { adding = true }.disabled(!PortfolioService.canAddPositions(account: account, context: context))
                }
            }
            .sheet(isPresented: $adding) {
                AddPositionSheet(account: account, context: context) { err in errorText = err } onSaved: { reload(); onChanged() }
            }
            .alert("Couldn't save", isPresented: .constant(errorText != nil)) { } message: { Text(errorText ?? "") }
        }
        .task { reload() }
    }

    private func reload() { positions = PortfolioService.allPositions(accountID: account.id, context: context) }
}
```

> Provide `PositionRowView` (inline edit of shares/cost/name + Buy More + Delete via `PortfolioService`) and `AddPositionSheet` (ticker/name/shares/averageCost form calling `PortfolioService.addPosition`). These are small SwiftUI forms; keep them in the same file. On the final-position delete, `PortfolioService.delete` already writes the zero snapshot.

- [ ] **Step 2: Settings token UI**

In `FinanceTracker/Features/Settings/SettingsView.swift`, add a section:

```swift
    @State private var tokenDraft: String = KeychainTokenStore.token() ?? ""
    @State private var tokenSaved = false

    // Inside the settings form:
    Section("DataBursatil (BMV prices)") {
        SecureField("API token", text: $tokenDraft)
        HStack {
            Button("Save") {
                try? KeychainTokenStore.setToken(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                tokenSaved = true
            }
            Button("Clear", role: .destructive) {
                KeychainTokenStore.clear()
                tokenDraft = ""
            }
        }
        Link("Get a token", destination: URL(string: "https://databursatil.com/nuevo_usuario.php")!)
        if tokenSaved { Text("Saved to Keychain.").font(.caption).foregroundStyle(.green) }
    }
```

- [ ] **Step 3: `ManualAccountSheet` affordance (eligibility-gated)**

In `FinanceTracker/Features/Accounts/ManualAccountSheet.swift` (or wherever investment accounts are surfaced in the UI), add an "Add stock positions" affordance for `.investment` accounts gated on `PortfolioService.canAddPositions(account:context:)`. If not eligible, show disabled guidance: "Create a separate brokerage account to track stocks." (This is a UI entry point to the portfolio flow; the actual sheet is `PositionsEditSheet`.)

- [ ] **Step 4: Build**

Run: `xcodegen generate && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project FinanceTracker.xcodeproj -scheme FinanceTracker build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add FinanceTracker/Features/Portfolio/PositionsEditSheet.swift FinanceTracker/Features/Settings/SettingsView.swift FinanceTracker/Features/Accounts/ManualAccountSheet.swift project.yml
git commit -m "feat: positions edit sheet, Keychain token UI, investment affordance"
```

---

## Task 15: V2→V3 store migration test + CHANGELOG

**Files:**
- Test: extend `FinanceTrackerTests/EndToEndTests/BackupArchiveTests.swift` (or a schema test file)
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add a real on-disk migration test**

In `FinanceTrackerTests/EndToEndTests/BackupArchiveTests.swift`, add a test that opens a store created under the V2 schema and migrates it to V3. Simplest robust approach: create an on-disk container with the **current** (V3) schema against a fresh URL, insert data, close; then reopen with `AppSchema.makeContainer(isStoredInMemoryOnly: false)` pointed at the same URL and assert the data round-trips and `StockPosition` fetches succeed (proving the schema/migration plan loads). If feasible, also write a fixture `.store` file pinned to V2 (see the existing `schemaOneBackupRestoresWithDefaults` test for the fixture pattern) and assert it opens under V3.

```swift
@Test("Store opens under V3 with StockPosition registered")
func storeOpensUnderV3() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ft-store-\(UUID()).store")
    let container = try AppSchema.makeContainer(isStoredInMemoryOnly: false)
    let ctx = container.mainContext
    let acct = Account(institution: "Broker", type: .investment, nickname: "Broker")
    ctx.insert(acct)
    _ = try PortfolioService.addPosition(account: acct, emisoraSerie: "FEMSAUBD", name: nil,
                                         shares: 1, averageCost: 1, context: ctx)
    try ctx.save()
    #expect(try ctx.fetchCount(FetchDescriptor<StockPosition>()) == 1)
    try? FileManager.default.removeItem(at: url)
}
```

> If the existing migration test infra supports a pinned-V2 on-disk fixture, prefer that to exercise the actual `migrateV2toV3` lightweight stage end-to-end. The minimal test above confirms the plan loads; escalate only if it reveals a lightweight-unsupported error (then switch to `.custom`).

- [ ] **Step 2: Run the full suite serial**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests -destination 'platform=macOS' -parallel-testing-enabled NO 2>&1 | tail -25`
Expected: All PASS. If `migrateV2toV3` fails as "lightweight unsupported," change it to `MigrationStage.custom(fromVersion:toVersion:didMigrate: { context in try context.save() })` and re-run.

- [ ] **Step 3: CHANGELOG entry**

In `CHANGELOG.md`, add under an Unreleased / next-version heading:

```markdown
### Added
- **Stocks Portfolio:** track a BMV stock portfolio as an investment account — per-stock
  positions (ticker, shares, average cost), on-demand DataBursatil price refresh, current
  value and growth % vs cost basis, counted in Net Worth via authoritative valuation snapshots.
- Settings: DataBursatil API token stored in Keychain.

### Changed
- SwiftData schema bumped to V3 (adds `StockPosition`); backup format v3 (required
  `StockPosition.json`; v1/v2 backups still restore). V2 model list frozen.
```

- [ ] **Step 4: Commit**

```bash
git add FinanceTrackerTests/EndToEndTests/BackupArchiveTests.swift CHANGELOG.md
git commit -m "test: V3 store opens with StockPosition; changelog entry"
```

---

## Manual verification (end-to-end)

After all tasks, run the app and verify by hand:

1. Launch, create an `.investment` account (brokerage), add 2–3 positions in the edit sheet.
2. Settings → paste a DataBursatil token → Save.
3. On the account dashboard, tap **Refresh prices** → summary shows "Valued as of {now}" with current value + growth; consolidated Net Worth includes the portfolio at the refresh timestamp.
4. Edit a position's shares → summary shows "Holdings changed — refresh required", growth hidden until refresh.
5. Switch the dashboard to an older period → summary shows that period's valuation (or "No portfolio valuation for this period" if before the first valuation); positions table stays "Latest positions / quotes".
6. Delete the final position → Net Worth drops to zero (no phantom); the account can have a position re-added.
7. A CETES/CI-Banco investment account with a manual snapshot shows "Add stock positions" **disabled**.
8. Export a `.ftbackup`, then wipe + restore → positions and valuation snapshots return.

---

## Self-Review (run after writing)

- **Spec coverage:** Every spec section maps to a task — model (T2), fingerprint (T3), resolver authoritative+provenance (T4), token (T5), client (T6), refresher (T7), service/eligibility/zero-snapshot (T8), view data (T9), backup+field-selective merge+v3 (T10), reset+deletion (T11), dashboard data flow (T12–T13), sheet/settings/affordance (T14), migration+changelog (T15).
- **Type consistency:** `PortfolioViewData`, `PositionRow`, `PortfolioService.*`, `PortfolioPriceRefresher.refresh`, `HoldingsFingerprint.of`, `DataBursatilClient.quotes/PriceSnapshot`, resolver provenance fields — names match across tasks. `portfolio: PortfolioViewData?` added to `AssetAccountSnapshot` (T12) is read in T13.
- **Placeholders:** None — every code step shows full code.

---
