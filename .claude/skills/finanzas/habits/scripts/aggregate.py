"""Agregaciones de hábitos de gasto — lo que la app NO hace: merchant-level, recurrentes, deltas MoM.

Todas las funciones respetan accounting_gates (solo counts_as_regular_expense).
Devuelven structs con nivel de certeza y ids para trazabilidad.
"""
from __future__ import annotations

import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime
from decimal import Decimal
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

_SHARED = str(Path(__file__).resolve().parents[2] / "_shared")
sys.path.insert(0, _SHARED)
from accounting_gates import classify, account_from_snapshot, category_from_snapshot  # noqa: E402


def _build_lookups(ds: Dict[str, Any]):
    acc = {a["id"]: account_from_snapshot(a) for a in ds["models"]["Account"]}
    cat = {c["id"]: category_from_snapshot(c) for c in ds["models"]["Category"]}
    plans = ds["plans"]
    return acc, cat, (lambda pid: plans.get(pid))


def _expense_txs(txs: List[Dict[str, Any]], ds: Dict[str, Any]):
    """Filtra solo transacciones que cuentan como gasto ordinario (gates aplicados)."""
    acc, cat, pl = _build_lookups(ds)
    out = []
    for t in txs:
        cl = classify(t, acc.get(t.get("accountId")), cat.get(t.get("categoryId")), pl)
        if cl.counts_as_regular_expense:
            out.append(t)
    return out


def _month_key(posted_at: str) -> str:
    return (posted_at or "")[:7]  # YYYY-MM


def _category_name(ds: Dict[str, Any], cat_id: Optional[str]) -> Tuple[str, str]:
    """Devuelve (parent, child) o ('Uncategorized','') si no hay."""
    if not cat_id:
        return ("Uncategorized", "")
    c = ds["categories"].get(cat_id)
    if not c or c.get("deletedAt"):
        return ("Uncategorized", "")
    name = c.get("name", "")
    parent_id = c.get("parentId")
    if parent_id and parent_id in ds["categories"]:
        return (ds["categories"][parent_id].get("name", ""), name)
    return (name, "")


@dataclass
class Bucket:
    label: str
    total: Decimal
    count: int
    ids: List[str] = field(default_factory=list)
    certainty: str = "Derivado"


def top_merchants(txs: List[Dict[str, Any]], ds: Dict[str, Any], months: Optional[int] = None) -> List[Bucket]:
    """Top comercios por gasto. Hecho (montos) → Derivado (ranking)."""
    exp = _expense_txs(txs, ds)
    now = None
    if months:
        # fecha de referencia = la última transacción disponible (no hoy, por datos hasta última importación)
        dates = [t.get("postedAt", "") for t in exp if t.get("postedAt")]
        if dates:
            latest = max(dates)[:10]
            cutoff = datetime.fromisoformat(latest + "T00:00:00+00:00")
            from datetime import timedelta

            floor = cutoff - timedelta(days=months * 30)
            exp = [t for t in exp if (t.get("postedAt", "")[:10] + "T00:00:00+00:00") >= floor.isoformat()]

    agg: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
    for t in exp:
        m = (t.get("merchantNormalized") or "").strip() or (t.get("descriptionRaw") or "").strip()[:40] or "(sin descripción)"
        agg[m].append(t)
    buckets = []
    for merchant, items in agg.items():
        total = sum((Decimal(str(abs(t["amount"]))) for t in items), Decimal(0))
        buckets.append(Bucket(merchant, total, len(items), [t["id"] for t in items]))
    buckets.sort(key=lambda b: b.total, reverse=True)
    return buckets


def spending_by_category(txs: List[Dict[str, Any]], ds: Dict[str, Any], months: Optional[int] = None) -> List[Bucket]:
    """Gasto por categoría (parent.child). Útil para deltas MoM."""
    exp = _expense_txs(txs, ds)
    if months:
        dates = [t.get("postedAt", "") for t in exp if t.get("postedAt")]
        if dates:
            latest = max(dates)[:10]
            from datetime import datetime, timedelta

            floor = datetime.fromisoformat(latest + "T00:00:00+00:00") - timedelta(days=months * 30)
            exp = [t for t in exp if (t.get("postedAt", "")[:10] + "T00:00:00+00:00") >= floor.isoformat()]

    agg: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
    for t in exp:
        parent, child = _category_name(ds, t.get("categoryId"))
        label = f"{parent}.{child}" if child else parent
        agg[label].append(t)
    buckets = []
    for label, items in agg.items():
        total = sum((Decimal(str(abs(t["amount"]))) for t in items), Decimal(0))
        buckets.append(Bucket(label, total, len(items), [t["id"] for t in items]))
    buckets.sort(key=lambda b: b.total, reverse=True)
    return buckets


def recurring(txs: List[Dict[str, Any]], ds: Dict[str, Any]) -> List[Bucket]:
    """Suscripciones/gastos recurrentes PROBABLES. Nivel: Inferido.

    Heurística: mismo merchant (o categoría Subscriptions), monto dentro de ±10%, aparición
    en ≥2 meses distintos con periodicidad ~mensual. Presentar siempre como "parece recurrente".
    """
    exp = _expense_txs(txs, ds)
    by_merchant: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
    for t in exp:
        m = (t.get("merchantNormalized") or "").strip()
        if not m:
            continue
        by_merchant[m].append(t)

    found = []
    for merchant, items in by_merchant.items():
        months_seen = {_month_key(t.get("postedAt", "")) for t in items}
        if len(months_seen) < 2:
            continue
        amts = [Decimal(str(abs(t["amount"]))) for t in items]
        if not amts:
            continue
        mean = sum(amts, Decimal(0)) / Decimal(len(amts))
        if mean == 0:
            continue
        # ¿montos similares? (tolerancia 10%)
        similar = all(abs(a - mean) <= mean * Decimal("0.1") for a in amts)
        # categoría Subscriptions refuerza la señal
        parent, _ = _category_name(ds, items[0].get("categoryId"))
        is_sub_cat = parent == "Subscriptions"
        if similar or is_sub_cat:
            found.append(Bucket(
                merchant,
                sum(amts, Decimal(0)),
                len(items),
                [t["id"] for t in items],
                certainty="Inferido",
            ))
    found.sort(key=lambda b: b.total, reverse=True)
    return found


def mom_delta(txs: List[Dict[str, Any]], ds: Dict[str, Any]) -> List[Tuple[str, Decimal, Decimal, Decimal]]:
    """Delta mes-a-mes por categoría (últimos 2 meses con datos).

    Devuelve [(categoria, mes_prev, mes_actual, delta_absoluta)]. Ordenado por |delta| desc.
    """
    exp = _expense_txs(txs, ds)
    by_cat_month: Dict[Tuple[str, str], Decimal] = defaultdict(lambda: Decimal(0))
    for t in exp:
        parent, child = _category_name(ds, t.get("categoryId"))
        label = f"{parent}.{child}" if child else parent
        mk = _month_key(t.get("postedAt", ""))
        by_cat_month[(label, mk)] += Decimal(str(abs(t["amount"])))

    months_sorted = sorted({mk for (_, mk) in by_cat_month})
    if len(months_sorted) < 2:
        return []
    cur_m, prev_m = months_sorted[-1], months_sorted[-2]
    rows = []
    cats = {c for (c, _) in by_cat_month}
    for c in cats:
        prev = by_cat_month.get((c, prev_m), Decimal(0))
        cur = by_cat_month.get((c, cur_m), Decimal(0))
        rows.append((c, prev, cur, cur - prev))
    rows.sort(key=lambda r: abs(r[3]), reverse=True)
    return rows
