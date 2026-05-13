# Liquid Glass redesign — proposal

You've tried this three times (`e824a08`, `32734c9`, `ff7a060` → `9f26a93`)
and ended somewhere correct-but-flat. This doc explains *why* it feels flat,
proposes three concrete visual directions you can choose between, and lists
the small things to fix everywhere regardless of direction.

You don't need to be at your computer to make decisions. Read this on your
phone, tell me a letter (A/B/C) and any "yes also do this" notes from the
checklist at the bottom, and I'll implement.

---

## Why the current state feels flat

Liquid Glass is not just `.glassEffect(...)`. It's a layered system:

1. A **vivid, slow-moving scene** behind the glass — gradient, mesh, or
   imagery. Without something interesting to refract, glass renders as plain
   translucent gray.
2. **Edge specular** that catches light as content scrolls behind it.
   Comes free with `glassEffect`, but only if there's content to scroll.
3. **Depth via stacking** — at least 2 layers of glass with different
   `interactionStyle`/elevation read as "stacked panes". The app today uses
   1 layer (the cards) over a flat material background.
4. **Motion** — subtle parallax / hue-shift behind the glass communicates
   "alive". Apple's apps use `TimelineView` or `MeshGradient` animations.

The earlier attempts: `ff7a060` added a `MeshGradient` (right direction);
`9f26a93` removed it because it looked off in light mode and broken in dark
mode. The right answer is **a `MeshGradient` that adapts to color scheme
AND respects each account's identity color** — not a single gradient for
the whole app, and not no gradient at all.

The bug filed in this session (the `modelContainer` missing 3 models)
also made the dashboard look emptier than it should, which made the
flatness worse. That's fixed in commit `4ebcacf`.

---

## Three visual directions

Pick one. Each is a single design language applied consistently.

### Direction A — "Liquid Vault" (recommended)

A single global mesh-gradient scene that drifts slowly, tinted by the
**currently scoped account's identity color**. Consolidated view = the
neutral system tint. HSBC credit card = HSBC red. Openbank Débito =
Openbank teal. The gradient shifts hue as the user moves between
accounts in the sidebar.

- Background: animated `MeshGradient` with 9 control points; 2 points
  drift on a 6-second loop using `TimelineView(.animation)`. Hue
  centered on the scoped account's color in HSL with low saturation
  (~25%) and adaptive brightness for light/dark.
- Glass cards: existing `glassEffect(.regular, in: .rect(cornerRadius: 16))`
  with a slightly larger corner radius for elegance.
- Summary tiles: hero glass with `.glassEffect(.regular.interactive())` so
  they respond to hover with a soft hue pulse.
- Sidebar: subtle vertical gradient behind it (separate plane); the
  selected account row uses an inset glass capsule that picks up the
  identity color.
- Floating Import button: stays `.glassProminent` but gains a soft glow
  in the identity color via `.tint(...)`.
- Charts: keep transparent backgrounds; add `chartPlotStyle` border in
  the identity color at low opacity.

Feel: **personal, alive, identity-aware.** This is the most "Apple
2025" direction.

### Direction B — "Aurora"

A single quiet aurora-style gradient backdrop that doesn't change per
account. The interesting motion is at the **edges** of glass cards: each
card gets a thin animated specular highlight that rotates around its
perimeter when you hover, like the System Settings panel highlights in
macOS 26.

- Background: static `MeshGradient` with 4 cool/warm corners; no per-
  account theming.
- Glass cards: `.glassEffect(.regular, in: .rect(cornerRadius: 16))`
  PLUS a `RoundedRectangle().stroke(LinearGradient(...), lineWidth: 1)`
  overlay whose gradient angle animates on hover via a `@State` rotation.
- Sidebar: floating glass panel detached from window edge by 8pt margin,
  like Reminders.
- Charts: keep current.

Feel: **cool, professional, less personal.** Closer to a Bloomberg /
Linear aesthetic than Apple's friendly direction.

### Direction C — "Stack of Cards"

Move away from "one big scrollable surface" toward distinct floating
cards. Each chart and summary group is a separate glass pane with its
own elevation. Hover lifts a pane forward (`shadow` + `scaleEffect`).
The dashboard reads as a deck of cards, not a single sheet.

- Background: static gradient (same as B).
- Glass cards: `.glassEffect(.regular)` + a small `.shadow(...)` whose
  radius animates on hover.
- Layout switches from `VStack` to a `LazyVGrid` so cards reflow on
  window resize.
- Charts keep current.

Feel: **playful, modular.** Best for "dashboard as briefing" use case.
Worst for dense reading because horizontal cards are smaller.

---

## Things to do regardless of direction

These improve perceived quality without picking a visual language:

1. **Corner radii consistent.** Today we have 6, 10, 12 mixed in
   `glassEffect(in: .rect(cornerRadius: …))`. Standardize on 12 for
   cards, 16 for hero tiles, 20 for sheets, 999 (capsule) for chips.
2. **Replace hardcoded MXN currency code in `DashboardChrome.swift`
   and `BreakdownSheet.swift`** with the account's currency. Transactions
   already store it; we just don't pass it through to summary tiles.
3. **Typography pass.** Use SF Rounded for headline numbers in summary
   tiles (gives money a friendlier feel). Body text stays SF.
4. **Tighter empty states.** The "No transactions yet" view is plain
   `VStack`. Wrap it in a glass card with a soft illustrated icon
   (SF Symbols `chart.line.uptrend.xyaxis.circle.fill` with `.symbolRenderingMode(.hierarchical)`).
5. **Dark-mode-correct CategoryPalette colors.** The current palette is
   tuned for light; in dark mode `.yellow` and `.mint` are too
   saturated. Use `Color.accentColor.opacity(...)` or named semantic
   colors per category.
6. **Sidebar account row utilization bar.** Today the consolidated
   accounts list shows a `%` pill but the sidebar account rows
   themselves don't. Add a thin glass `ProgressView` for credit-card
   accounts — see at a glance which card needs attention.
7. **Charts: soft drop-shadow on bars and lines.** `chartForegroundStyleScale`
   per series + a slight `.shadow(radius: 1)` makes them feel layered
   onto glass instead of painted underneath.
8. **Hover affordances on every clickable surface.** Today
   `BreakdownSheet`-triggering tiles look identical to non-tappable
   chrome. Add `.onHover { … }` with a slight scale/glow on tappable
   surfaces.
9. **Account identity color storage.** Add `Account.tintHex: String?`
   (lightweight migration, optional) so the user can pick a color per
   account in Settings. Default colors: HSBC = red, Openbank = teal,
   Amex = blue, etc.

---

## What I'll do while you decide

Without your direction-pick I won't implement the visual language. But I
*will* implement the regardless-of-direction items (1, 2, 4, 5, 7, 8)
because they're correctness/consistency, not taste. Items 3, 6, 9 wait
for you because they touch the model layer or shift the typography.

When you reply with A/B/C plus any items from the checklist you
explicitly want to skip, I'll:

1. Implement the chosen direction as one commit, all visual files, build-
   only verification.
2. Implement remaining regardless-of-direction items.
3. Update `CHANGELOG.md`.
4. NOT launch the app, NOT run UI tests. You verify with one
   `open …app` on your end when you're back.

---

## Other useful work I can do while waiting

Ranked by value, all source-only:

- **New parsers from `specs/credit-cards.md` follow-up backlog.** Banorte
  POR Ti, Mercado Pago, DiDi Cuenta paste parsers — same shape as
  HSBC. Each is ~200 LOC of regex + tests.
- **Replace the stale `specs/credit-cards.md`** with a current-state
  summary pointing at the commit history.
- **Investment-account dashboard variant** for `Skandia` / `CETES` /
  `CI Banco` once we have any data — but those issuers aren't pasted
  yet so this is preparing-the-ground work.
- **The Stage 3 plan's verification section** says we should test:
  - HSBC paste → utilization shows ~9.7% — verify via test, not app
    launch. Write a test that constructs the snapshot from a known
    fixture and asserts.
  - Net worth signed correctly with mixed asset+liability. Same
    approach.
  - Consolidated cash flow doesn't double-count an HSBC SU PAGO when
    paired with a matching Openbank statement. Same approach.

I'll write those tests now (they don't need the app to run).

---

## TL;DR for your phone

Tell me:
1. Visual direction: **A / B / C**.
2. Anything from "things to do regardless" you want skipped: numbers.

I'll do the rest. No app launches. No surprises.
