"""Saldo reconstruido — puerto fiel de AccountBalanceResolver.swift.

Único lugar que conoce el algoritmo. `aggregate.py` deja de hacer max(snapshots)
ad hoc y delega aquí. Spec: `../SPEC.md` §7. Referencia canónica:
`FinanceTracker/Domain/Services/AccountBalanceResolver.swift`.

Algoritmo (ramas del resolver):
  1. portfolioValuation → monto tal cual, sin deltas (corre primero).
  2. sin anchors de statement EN ABSOLUTO + primer anchor manualOpening → B1/B2.
  3. general: base = anchor.amount (o 0); Σ tx.amount con anchor_date < postedAt <= as_of.
  4. sin anchor y sin tx → insufficient.

Tx que cuentan: accountId==acct, statementId is None, isDuplicate False,
deletedAt None, ordenadas por postedAt asc, signos TAL CUAL (sin re-signar).
Comparaciones de fecha crudas UTC (igual que Swift Date).
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from decimal import Decimal
from typing import Any


@dataclass(frozen=True)
class _Anchor:
    date: datetime
    amount: Decimal
    kind: str            # "statement" | snapshot.kind
    snapshot_id: str | None = None


@dataclass(frozen=True)
class AccountBalanceHistory:
    anchors: tuple[_Anchor, ...]
    transactions: tuple[dict, ...]      # txs calificantes, sorted postedAt asc
    has_statement_anchor: bool
    account_opened_at: datetime | None


@dataclass(frozen=True)
class AccountBalanceResolution:
    as_of: datetime
    amount: Decimal
    source_kind: str       # "exact" | "latest_prior" | "reconstructed" | "insufficient"
    source_date: datetime | None = None
    source_snapshot_id: str | None = None
    anchor_kind: str | None = None   # kind del anchor base: "statement" | snapshot.kind


def _to_dt(s: str | None) -> datetime | None:
    if not s:
        return None
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    return dt


def _qualifying_txs(ds: dict[str, Any], account_id: str) -> list[dict]:
    """accountId==acct, statementId None, isDuplicate False, deletedAt None,
    ordenadas por postedAt asc. Signos tal cual."""
    out = []
    for t in ds.get("transactions", []):
        if t.get("accountId") != account_id:
            continue
        if t.get("statementId") is not None:
            continue
        if t.get("isDuplicate"):
            continue
        if t.get("deletedAt"):
            continue
        if _to_dt(t.get("postedAt")) is None:
            continue
        out.append(t)
    out.sort(key=lambda t: t["postedAt"])
    return out


def _deleted_mirror_ids(ds: dict[str, Any], account_id: str) -> set[str]:
    """ids de txs soft-deleted SIN statement en esta cuenta → excluir snapshots cuyo
    id colisiona (resolver lines 331-343, 391-393: tx.statement == nil && deletedAt != nil)."""
    return {t["id"] for t in ds.get("transactions", [])
            if t.get("accountId") == account_id
            and t.get("deletedAt")
            and t.get("statementId") is None
            and "id" in t}


def _anchors(ds: dict[str, Any], account_id: str) -> list[_Anchor]:
    mirror = _deleted_mirror_ids(ds, account_id)
    anchors: list[_Anchor] = []
    for s in ds.get("statements", []):
        if s.get("accountId") != account_id:
            continue
        if s.get("closingBalance") is None:
            continue
        dt = _to_dt(s.get("periodEnd"))
        if dt is None:
            continue
        anchors.append(_Anchor(date=dt, amount=Decimal(str(s["closingBalance"])),
                               kind="statement"))
    for s in ds.get("snapshots", []):
        if s.get("accountId") != account_id:
            continue
        if s.get("id") in mirror:
            continue
        dt = _to_dt(s.get("date"))
        if dt is None:
            continue
        anchors.append(_Anchor(date=dt, amount=Decimal(str(s.get("amount", 0))),
                               kind=s.get("kind", "manualAdjustment"),
                               snapshot_id=s.get("id")))
    return anchors


def balance_history(ds: dict[str, Any], account_id: str) -> AccountBalanceHistory:
    anchors = tuple(_anchors(ds, account_id))
    txs = tuple(_qualifying_txs(ds, account_id))
    acct = ds.get("accounts", {}).get(account_id, {})
    opened = _to_dt(acct.get("openedAt"))
    has_stmt = any(a.kind == "statement" for a in anchors)
    return AccountBalanceHistory(anchors=anchors, transactions=txs,
                                 has_statement_anchor=has_stmt,
                                 account_opened_at=opened)


def _same_calendar_day(a: datetime, b: datetime) -> bool:
    """Replica Calendar(.gregorian).isDate(_:inSameDayAs:) — tz local del sistema.
    Solo afecta la etiqueta exact/latest_prior, no el monto."""
    a_l = a.astimezone()
    b_l = b.astimezone()
    return a_l.date() == b_l.date()


def resolve(ds: dict[str, Any], account_id: str, as_of: datetime) -> AccountBalanceResolution:
    """Las 4 ramas, siguiendo AccountBalanceResolver.swift lines 86-187."""
    hist = balance_history(ds, account_id)

    # anchors con date <= as_of (inclusivo, igual que Swift).
    # Tie-break: Swift `max {$0.date < $1.date}` devuelve el PRIMER elemento en empate de
    # fecha, y los anchors se construyen statements-first → statement gana sobre snapshot.
    # Replicamos: en empate de fecha, "statement" (1) vence a cualquier snapshot (0) en max.
    through = tuple(a for a in hist.anchors if a.date <= as_of)
    anchor = max(through, key=lambda a: (a.date, 1 if a.kind == "statement" else 0)) if through else None

    # Rama 1: portfolioValuation short-circuit (corre PRIMERO)
    if anchor is not None and anchor.kind == "portfolioValuation":
        kind = "exact" if _same_calendar_day(anchor.date, as_of) else "latest_prior"
        return AccountBalanceResolution(as_of=as_of, amount=anchor.amount,
                                        source_kind=kind, source_date=anchor.date,
                                        source_snapshot_id=anchor.snapshot_id,
                                        anchor_kind=anchor.kind)

    first_anchor = min(through, key=lambda a: a.date) if through else None

    # Rama 2: manualOpening sin anchors de statement en absoluto
    if (not hist.has_statement_anchor
            and first_anchor is not None
            and first_anchor.kind == "manualOpening"):
        later = max((a for a in through if a.date > first_anchor.date),
                    key=lambda a: a.date, default=None)
        if later is not None:
            # B1: base en el anchor posterior
            deltas = _sum_deltas(hist.transactions, later.date, as_of)
            return _finish(later.amount + deltas, later, as_of, bool(deltas))
        # B2: base en opening, suma desde account.openedAt
        base = anchor.amount if anchor is not None else (first_anchor.amount if first_anchor else Decimal(0))
        lo = hist.account_opened_at if hist.account_opened_at is not None else first_anchor.date
        deltas = _sum_deltas_lo(hist.transactions, lo, as_of)
        return _finish(base + deltas, first_anchor, as_of, bool(deltas))

    # Rama 3: general
    if anchor is None and not hist.transactions:
        # Rama 4: insufficient
        return AccountBalanceResolution(as_of=as_of, amount=Decimal(0),
                                        source_kind="insufficient", source_date=None)

    anchor_date = anchor.date if anchor is not None else datetime.min.replace(tzinfo=UTC)
    base = anchor.amount if anchor is not None else Decimal(0)
    deltas = _sum_deltas(hist.transactions, anchor_date, as_of)
    return _finish(base + deltas, anchor, as_of, bool(deltas))


def _sum_deltas(txs: tuple[dict, ...], after: datetime, as_of: datetime) -> Decimal:
    """Σ tx.amount con after < postedAt <= as_of."""
    total = Decimal(0)
    for t in txs:
        p = _to_dt(t["postedAt"])
        if p is not None and after < p <= as_of:
            total += Decimal(str(t["amount"]))
    return total


def _sum_deltas_lo(txs: tuple[dict, ...], lo: datetime, as_of: datetime) -> Decimal:
    """Σ tx.amount con lo <= postedAt <= as_of (caso B2)."""
    total = Decimal(0)
    for t in txs:
        p = _to_dt(t["postedAt"])
        if p is not None and lo <= p <= as_of:
            total += Decimal(str(t["amount"]))
    return total


def _finish(amount: Decimal, anchor: _Anchor | None, as_of: datetime,
            has_deltas: bool) -> AccountBalanceResolution:
    if not has_deltas and anchor is not None:
        kind = "exact" if _same_calendar_day(anchor.date, as_of) else "latest_prior"
    else:
        kind = "reconstructed"
    return AccountBalanceResolution(as_of=as_of, amount=amount, source_kind=kind,
                                    source_date=anchor.date if anchor else None,
                                    source_snapshot_id=anchor.snapshot_id if anchor else None,
                                    anchor_kind=anchor.kind if anchor else None)


def resolve_all(ds: dict[str, Any], as_of: datetime | None = None) -> dict[str, AccountBalanceResolution]:
    if as_of is None:
        as_of = as_of_default(ds)
    return {aid: resolve(ds, aid, as_of) for aid in ds.get("accounts", {})}


def as_of_default(ds: dict[str, Any]) -> datetime:
    """max de postedAt / snapshot.date / statement.periodEnd, tz-aware."""
    cands: list[datetime] = []
    for t in ds.get("transactions", []):
        d = _to_dt(t.get("postedAt"))
        if d:
            cands.append(d)
    for s in ds.get("snapshots", []):
        d = _to_dt(s.get("date"))
        if d:
            cands.append(d)
    for s in ds.get("statements", []):
        d = _to_dt(s.get("periodEnd"))
        if d:
            cands.append(d)
    if not cands:
        return datetime.now(UTC)
    return max(cands)


def _demo() -> None:
    """Self-check: snapshot base + txs posteriores → reconstruido ≠ snapshot crudo."""
    ds = {
        "accounts": {"A": {"id": "A", "type": "checking", "openedAt": "2026-01-01T00:00:00Z"}},
        "transactions": [
            {"id": "t1", "accountId": "A", "amount": 1000, "postedAt": "2026-07-10T00:00:00Z",
             "statementId": None, "isDuplicate": False, "deletedAt": None},
        ],
        "snapshots": [{"id": "s1", "accountId": "A", "amount": 5000,
                       "date": "2026-07-01T00:00:00Z", "kind": "manualAdjustment"}],
        "statements": [],
    }
    as_of = datetime(2026, 7, 15, tzinfo=UTC)
    r = resolve(ds, "A", as_of)
    assert r.source_kind == "reconstructed", r
    assert r.amount == Decimal(6000), r
    print("balance.py self-check OK")


if __name__ == "__main__":
    _demo()
