# Credit-card support — current state

> The original spec for this work has been superseded by what actually
> shipped after the OCR pivot. This file is now a pointer to the
> historical record. See `git log` and `DECISIONS.md` AD-009..AD-014 for
> rationale.

## What shipped

Six stages landed across `c6f470d` → `7376c36`:

| Stage | Commit | What |
|---|---|---|
| Domain | `c6f470d` | Account/Statement/Transaction extensions, `InstallmentPlan`, `CategoryKind.creditCardPayment`, seed data |
| Parser | `2e02fbf` | `PastedHsbc2NowParser` + `PendingImport` (OCR removed; paste-text replaces it) |
| Stage 1 UI | `60641ee` | Paste Text button in `ImportView` + `PasteImportSheet` + `.txt` file path |
| Stage 2 UI | `ec0d23d` | Editable `TransactionsView` with inline `PendingImport` review |
| Stage 4 | `4a42991` | `LearningHooks` (merchant→category) + `SignRecoveryHint` (description→sign-recovery) |
| Stage 3 | `7376c36` | `DashboardScope`, `DashboardSnapshot` union, per-account dashboards (consolidated/asset/liability), interactive charts, `BreakdownSheet` drill-down |

Plus follow-ups: `99cd605` (CategoryPicker subcategories + Import-sheet
Done button), `4ebcacf` (registered all 8 `@Model` types in
WindowGroup — silent bug where 3 models weren't persisted),
`6a81391` (Stage 3 end-to-end verification tests),
`1211c76` (Liquid Glass redesign chrome layer).

## Architectural decisions

Documented in `DECISIONS.md`:

- **AD-009** Manual-review-first parsing (`PendingImport` over heuristics)
- **AD-010** Liability balances stored signed-negative
- **AD-011** Supplementary cards as `cardLast4` field, not separate Accounts
- **AD-012** MSI: both original purchase and per-month installments
- **AD-013** `SU PAGO GRACIAS` = `.creditCardPayment`, excluded from cash flow
- **AD-014** Manual fixes feed `CategoryRule` + `SignRecoveryHint`

## What this file used to be

Before the pivot, this spec described a Vision-OCR path through HSBC's
custom-font PDF. The OCR approach had unsolvable accuracy gaps on dense
tables and was replaced by paste-from-portal text imports. The OCR
files were deleted in `2e02fbf`; the design conversation that led to
the pivot is preserved in chat history.

## Next steps (not started)

Now that the HSBC paste path is stable and the dashboard is rebuilt:

### Liquid Glass redesign

In progress — `1211c76` shipped the chrome layer (AppBackdrop +
GlassCard + AccountIdentity + scopedTint env + Item 5 dark-mode
palette + Item 6 sidebar utilization + Item 7 chart plot strokes).
See `specs/liquid-glass-redesign.md` for the full plan and which items
remain.

### More paste parsers

The HSBC paste parser is a template. The most useful next parsers, in
priority order based on the issuers `Detector` already classifies:

1. **Banorte POR Ti** — credit card, similar PDF quality issues to HSBC.
   Highest ROI; the user has historical statements.
2. **Mercado Pago** — wallet account. Paste from the web portal's
   "Movimientos" view; rows look like `<date> <description> <amount>`
   with no sign glyph at all (amount color encodes sign).
3. **DiDi Cuenta** — savings account. Similar to Mercado Pago.
4. **Skandia / CI Banco / Suburbia** — lower priority because the user
   has fewer of these statements; defer until the top three are solid.

Each parser is ~200–300 LOC of regex + a fixture in `samples/` + a
test suite mirroring `PastedHsbc2NowParserTests`. The dispatch point in
`IngestPipeline.ingestPastedText` is already generic — `Detector.detectFromPastedText`
just needs new pattern arms.

### Account settings UI

`Account.tintHex` exists in the model but there's no UI yet to let the
user pick it. Add a `Settings → Accounts` section with per-account
nickname / identity color / credit limit editors. The identity color
will then propagate through the chrome via `scopedTint` automatically.

### Investment-account dashboard variant

`AssetAccountDashboard` works for checking/savings but is shallow for
investments. Once a real CETES / Skandia statement is imported, add a
dedicated `InvestmentAccountDashboard` with contributions-vs-growth and
holdings sections.
