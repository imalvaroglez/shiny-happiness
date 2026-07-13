"""Agregaciones de patrimonio — net worth puntual, composición, CAGR, posiciones, runway.

Patrimonio = Σ de saldos resueltos (snapshots + closingBalance), NO suma de transacciones.
"""
from __future__ import annotations

import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

_SHARED = str(Path(__file__).resolve().parents[2] / "_shared")
sys.path.insert(0, _SHARED)

LIQUIDITY_RAW_LIQUID = {"liquid"}


@dataclass
class AccountView:
    id: str
    institution: str
    nickname: str
    type: str
    currency: str
    liquidity_raw: Optional[str]
    include_in_net_worth: Optional[bool]
    latest_balance: Optional[Decimal]
    latest_balance_date: Optional[str]
    source: str  # "snapshot" | "statement" | "none"


def _effective_include_nw(a: Dict[str, Any]) -> bool:
    v = a.get("includeInNetWorth")
    if v is None:
        return a.get("type") != "other"
    return v


def _account_views(ds) -> List[AccountView]:
    out = []
    for a in ds["models"]["Account"]:
        aid = a["id"]
        snaps = [s for s in ds["snapshots"] if s.get("accountId") == aid]
        latest_snap = max(snaps, key=lambda s: s.get("date", "")) if snaps else None
        stmts = [s for s in ds["statements"] if s.get("accountId") == aid and s.get("closingBalance") is not None]
        latest_stmt = max(stmts, key=lambda s: s.get("periodEnd", "")) if stmts else None

        balance, date, source = None, None, "none"
        # snapshot > statement para activos; statement (closing) es buen anchor para pasivos
        if latest_snap and latest_snap.get("amount") is not None:
            balance = Decimal(str(latest_snap["amount"]))
            date = (latest_snap.get("date") or "")[:10]
            source = "snapshot"
        elif latest_stmt:
            balance = Decimal(str(latest_stmt["closingBalance"]))
            date = (latest_stmt.get("periodEnd") or "")[:10]
            source = "statement"

        out.append(AccountView(
            id=aid,
            institution=a.get("institution", ""),
            nickname=a.get("nickname") or a.get("institution", ""),
            type=a.get("type", "other"),
            currency=a.get("currency", "MXN"),
            liquidity_raw=a.get("liquidityRaw"),
            include_in_net_worth=a.get("includeInNetWorth"),
            latest_balance=balance,
            latest_balance_date=date,
            source=source,
        ))
    return out


def net_worth_at(ds, as_of: Optional[str] = None) -> Tuple[Decimal, str]:
    """Net worth a una fecha (None = último conocido). Devuelve (monto, nota de fuente)."""
    views = [v for v in _account_views(ds) if _effective_include_nw({
        "includeInNetWorth": v.include_in_net_worth, "type": v.type}) and v.latest_balance is not None]
    total = sum((v.latest_balance for v in views), Decimal(0))
    # nota de frescura
    dates = [v.latest_balance_date for v in views if v.latest_balance_date]
    note = "Σ de saldos resueltos (último snapshot/cierre por cuenta)"
    if dates:
        note += f"; snapshot más reciente {max(dates)}"
    return total, note


def net_worth_series(ds) -> List[Tuple[str, Decimal]]:
    """Serie de net worth a lo largo del tiempo, sampleando en cada fecha de snapshot única.
    Simplificado: para cada fecha-distinta de snapshot, suma el último saldo conocido de cada
    cuenta hasta esa fecha. Es una aproximación del AccountBalanceResolver (Derivado)."""
    # todas las fechas de snapshot
    all_dates = sorted({(s.get("date") or "")[:10] for s in ds["snapshots"] if s.get("date")})
    if not all_dates:
        return []
    series = []
    for d in all_dates:
        total = Decimal(0)
        any_balance = False
        for a in ds["models"]["Account"]:
            if not _effective_include_nw(a):
                continue
            snaps = [s for s in ds["snapshots"]
                     if s.get("accountId") == a["id"] and (s.get("date") or "")[:10] <= d]
            if snaps:
                latest = max(snaps, key=lambda s: s.get("date", ""))
                if latest.get("amount") is not None:
                    total += Decimal(str(latest["amount"]))
                    any_balance = True
        if any_balance:
            series.append((d, total))
    return series


def composition(ds) -> Dict[str, Decimal]:
    """Composición: liquidity / patrimonial / retirement / liability / uncategorized.
    Mismo bucketing que NetWorthComposition.swift."""
    buckets = {k: Decimal(0) for k in ("liquidity", "patrimonial", "retirement", "liability", "uncategorized")}
    for v in _account_views(ds):
        if not _effective_include_nw({"includeInNetWorth": v.include_in_net_worth, "type": v.type}):
            continue
        bal = v.latest_balance
        if bal is None:
            continue
        if v.type in ("creditCard", "loan"):
            buckets["liability"] += bal
        elif v.type == "retirement":
            buckets["retirement"] += bal
        elif v.type in ("checking", "savings", "wallet"):
            buckets["liquidity"] += bal
        elif v.type == "investment":
            if v.liquidity_raw == "liquid":
                buckets["liquidity"] += bal
            else:
                buckets["patrimonial"] += bal
        else:
            buckets["uncategorized"] += bal
    return buckets


def available_net_worth(ds) -> Tuple[Decimal, str]:
    """net liquidity + patrimonial (excluye retiro). La métrica hero de la app."""
    c = composition(ds)
    net_liq = c["liquidity"] + c["liability"]  # liability es negativo
    return net_liq + c["patrimonial"], "availableNetWorth = netLiquidity + patrimonial (excluye retiro)"


def cagr(ds, months_min: int = 6) -> Tuple[Optional[Decimal], str]:
    """CAGR anualizado desde la primera a la última medición de net worth."""
    series = net_worth_series(ds)
    if len(series) < 2:
        return None, "Datos insuficientes para CAGR"
    first_date, first_val = series[0]
    last_date, last_val = series[-1]
    try:
        d0 = datetime.fromisoformat(first_date + "T00:00:00+00:00")
        d1 = datetime.fromisoformat(last_date + "T00:00:00+00:00")
    except ValueError:
        return None, "Fechas inválidas"
    days = (d1 - d0).days
    if days <= 0:
        return None, "Ventana no positiva"
    years = Decimal(days) / Decimal(365)
    if years < Decimal(months_min) / Decimal(12):
        growth = ((last_val - first_val) / abs(first_val) * Decimal(100)) if first_val != 0 else None
        return (growth, f"Crecimiento absoluto {growth:.1f}% en {days} días (CAGR no fiable con <{months_min}m; Supuesto si se anualiza)")
    if first_val <= 0:
        return None, ("Patrimonio inicial ≤ 0 o reconstruido parcialmente (los snapshots de inversión "
                      "inician a mediados de año). CAGR no aplicable aún — revisar con ~12 meses de datos.")
    ratio = last_val / first_val
    cagr_val = (ratio ** (Decimal(1) / years) - Decimal(1)) * Decimal(100)
    return cagr_val.quantize(Decimal("0.1")), f"CAGR {cagr_val:.1f}% anualizado sobre {days} días (Derivado)"


def positions(ds) -> List[Dict[str, Any]]:
    """Posiciones con costo, valor (lastPrice×shares), growth%."""
    out = []
    for p in ds["positions"]:
        shares = Decimal(str(p.get("shares", 0)))
        avg_cost = Decimal(str(p.get("averageCost", 0)))
        last_price = Decimal(str(p.get("lastPrice"))) if p.get("lastPrice") is not None else avg_cost
        cost = shares * avg_cost
        val = shares * last_price
        growth = ((val - cost) / cost * Decimal(100)) if cost != 0 else None
        a = ds["accounts"].get(p.get("accountId"))
        stale = ""
        if p.get("lastPriceAt"):
            try:
                lp = datetime.fromisoformat(p["lastPriceAt"].replace("Z", "+00:00"))
                age = (datetime.now(timezone.utc) - lp).days
                if age > 14:
                    stale = f" (valuación de hace {age}d — posiblemente desactualizada)"
            except ValueError:
                pass
        out.append({
            "ticker": p.get("emisoraSerie", ""),
            "shares": shares,
            "cost": cost,
            "value": val,
            "growth_pct": growth.quantize(Decimal("0.1")) if growth is not None else None,
            "institution": a.get("institution") if a else "?",
            "stale_note": stale,
        })
    out.sort(key=lambda x: x["value"], reverse=True)
    return out


def liquidity_runway(ds, txs) -> Tuple[Optional[Decimal], str]:
    """Meses de gastos cubiertos por liquidez. Requiere txs para gasto mensual promedio."""
    c = composition(ds)
    liquid = c["liquidity"]
    # gasto mensual promedio (de la sub-skill ingresos, replicado mínimo)
    from accounting_gates import classify, account_from_snapshot, category_from_snapshot
    acc = {a["id"]: account_from_snapshot(a) for a in ds["models"]["Account"]}
    cat = {c2["id"]: category_from_snapshot(c2) for c2 in ds["models"]["Category"]}
    pl = lambda pid: ds["plans"].get(pid)
    by_month = defaultdict(lambda: Decimal(0))
    months_set = set()
    for t in txs:
        if t.get("deletedAt"):
            continue
        cl = classify(t, acc.get(t.get("accountId")), cat.get(t.get("categoryId")), pl)
        if cl.counts_as_regular_expense:
            mk = (t.get("postedAt") or "")[:7]
            by_month[mk] += Decimal(str(abs(t["amount"])))
            months_set.add(mk)
    if not months_set:
        return None, "Sin gastos para calcular runway"
    # excluir último mes si está incompleto (mismo criterio que savings rate)
    sorted_m = sorted(months_set)
    if len(sorted_m) > 1:
        sorted_m = sorted_m[:-1]
    avg = sum((by_month[m] for m in sorted_m), Decimal(0)) / Decimal(len(sorted_m))
    if avg <= 0:
        return None, "Gasto promedio ≤ 0"
    months = (liquid / avg).quantize(Decimal("0.1"))
    return months, f"{months} meses de gastos (~${avg:,.0f}/mes) cubiertos por ${liquid:,.0f} en liquidez (Supuesto)"
