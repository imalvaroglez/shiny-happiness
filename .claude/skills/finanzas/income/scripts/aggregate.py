"""Agregaciones de ingresos — diversificación, estabilidad, savings rate.

Solo counts_as_regular_income (gates). Savings rate = (income - expense)/income.
"""
from __future__ import annotations

import sys
from collections import defaultdict
from dataclasses import dataclass, field
from decimal import Decimal
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

_SHARED = str(Path(__file__).resolve().parents[2] / "_shared")
sys.path.insert(0, _SHARED)
from accounting_gates import classify, account_from_snapshot, category_from_snapshot  # noqa: E402


def _build(ds):
    acc = {a["id"]: account_from_snapshot(a) for a in ds["models"]["Account"]}
    cat = {c["id"]: category_from_snapshot(c) for c in ds["models"]["Category"]}
    pl = lambda pid: ds["plans"].get(pid)
    return acc, cat, pl


def _income_expense(txs, ds):
    acc, cat, pl = _build(ds)
    income, expense = [], []
    for t in txs:
        cl = classify(t, acc.get(t.get("accountId")), cat.get(t.get("categoryId")), pl)
        if cl.counts_as_regular_income:
            income.append(t)
        elif cl.counts_as_regular_expense:
            expense.append(t)
    return income, expense


def _cat_label(ds, cat_id):
    if not cat_id:
        return "Uncategorized"
    c = ds["categories"].get(cat_id)
    if not c or c.get("deletedAt"):
        return "Uncategorized"
    name = c.get("name", "")
    pid = c.get("parentId")
    if pid and pid in ds["categories"]:
        return f"{ds['categories'][pid].get('name','')}.{name}"
    return name


@dataclass
class Source:
    label: str
    total: Decimal
    count: int
    ids: List[str] = field(default_factory=list)


def by_source(txs, ds) -> List[Source]:
    """Ingreso por subcategoría Income. Solo Income.* (kind=income)."""
    income, _ = _income_expense(txs, ds)
    agg = defaultdict(list)
    for t in income:
        c = ds["categories"].get(t.get("categoryId"))
        # solo contar si la categoría es kind=income (evita Income.Interest colado)
        if c and c.get("kind") == "income":
            agg[_cat_label(ds, t.get("categoryId"))].append(t)
        elif not c:
            agg["Uncategorized"].append(t)
    out = []
    for label, items in agg.items():
        total = sum((Decimal(str(t["amount"])) for t in items), Decimal(0))
        out.append(Source(label, total, len(items), [t["id"] for t in items]))
    out.sort(key=lambda s: s.total, reverse=True)
    return out


def _month(posted):
    return (posted or "")[:7]


def monthly_series(txs, ds) -> List[Tuple[str, Decimal, Decimal, Decimal]]:
    """[(mes, ingreso, gasto(abs), neto)] por mes. Derivado."""
    income, expense = _income_expense(txs, ds)
    inc_m = defaultdict(lambda: Decimal(0))
    exp_m = defaultdict(lambda: Decimal(0))
    for t in income:
        inc_m[_month(t.get("postedAt"))] += Decimal(str(t["amount"]))
    for t in expense:
        exp_m[_month(t.get("postedAt"))] += Decimal(str(abs(t["amount"])))
    months = sorted(set(list(inc_m) + list(exp_m)))
    return [(m, inc_m[m], exp_m[m], inc_m[m] - exp_m[m]) for m in months]


def savings_rate(txs, ds) -> List[Tuple[str, Optional[Decimal], str]]:
    """[(mes, savings_rate_pct, nota)]. None si ingreso=0 o mes incompleto.

    El último mes con datos suele estar incompleto (nómina aún no cobrada, estados
    sin importar). Si el savings rate calculado es absurdo (|rate| > 200%), lo
    degradamos a None con nota, en vez de reportar un número sin sentido.
    """
    series = monthly_series(txs, ds)
    if not series:
        return []
    last_month = series[-1][0]
    rows = []
    for m, inc, exp, net in series:
        if inc <= 0:
            rows.append((m, None, "Sin ingreso registrado este mes"))
            continue
        rate = net / inc * Decimal(100)
        is_last = (m == last_month)
        if is_last and abs(rate) > Decimal(200):
            rows.append((m, None,
                         f"Mes posiblemente incompleto (último con datos, ingreso ${inc:,.0f} "
                         f"inusualmente bajo). No se reporta savings rate."))
            continue
        caveat = "Derivado" + (" (último mes con datos — verificar cobertura)" if is_last else "")
        rows.append((m, rate.quantize(Decimal("0.1")), caveat))
    return rows


def concentration(txs, ds) -> Tuple[Optional[Decimal], str]:
    """% del ingreso total que viene de la fuente #1. Derivado."""
    sources = by_source(txs, ds)
    total = sum((s.total for s in sources), Decimal(0))
    if not sources or total <= 0:
        return (None, "Sin ingreso")
    top = sources[0].total
    pct = top / total * Decimal(100)
    label = sources[0].label
    return (pct.quantize(Decimal("0.1")), f"{pct:.1f}% del ingreso viene de '{label}'")
