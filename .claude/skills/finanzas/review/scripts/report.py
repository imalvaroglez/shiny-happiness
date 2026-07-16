"""Informe integrado — orquesta hábitos/deuda/patrimonio/ingresos en un dict estructurado.

Cada bloque lleva 'certainty'. Las sub-skills se importan por path (no son paquetes).
"""
from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path
from typing import Any, Dict

_SKILL = Path(__file__).resolve().parents[2]
_SHARED = _SKILL / "_shared"
sys.path.insert(0, str(_SHARED))


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod  # dataclasses lo busca en sys.modules
    spec.loader.exec_module(mod)  # type: ignore
    return mod


def build_report(ds: Dict[str, Any], txs) -> Dict[str, Any]:
    load = _load_module("load", _SHARED / "load.py")
    # recargar txs si no se pasaron
    if txs is None:
        txs = load.live_transactions(ds)

    habits = _load_module("habits_agg", _SKILL / "habits" / "scripts" / "aggregate.py")
    debt = _load_module("debt_agg", _SKILL / "debt" / "scripts" / "aggregate.py")
    wealth = _load_module("wealth_agg", _SKILL / "wealth" / "scripts" / "aggregate.py")
    income = _load_module("income_agg", _SKILL / "income" / "scripts" / "aggregate.py")

    # --- cobertura temporal ---
    dates = sorted(t.get("postedAt", "") for t in txs if t.get("postedAt"))
    span = (dates[0], dates[-1]) if dates else None
    months = sorted({(d[:7]) for d in dates}) if dates else []
    last_month = months[-1] if months else None
    last_month_txs = [t for t in txs if (t.get("postedAt") or "")[:7] == last_month] if last_month else []

    # --- patrimonial ---
    nw, nw_note = wealth.net_worth_at(ds)
    anw, anw_note = wealth.available_net_worth(ds)
    comp = wealth.composition(ds)
    cagr_val, cagr_note = wealth.cagr(ds)
    run, run_note = wealth.liquidity_runway(ds, txs)

    # --- ingresos ---
    inc_sources = income.by_source(txs, ds)
    sav = income.savings_rate(txs, ds)
    conc_pct, conc_note = income.concentration(txs, ds)

    # --- hábitos ---
    top_merchants = habits.top_merchants(txs, ds, months=3)[:8]
    rec = habits.recurring(txs, ds)[:8]
    mom = habits.mom_delta(txs, ds)[:6]

    # --- deuda ---
    cards = debt.liability_balances(ds)
    cards_with_debt = [c for c in cards if c.balance < 0]

    # --- banderas ---
    flags = []
    if conc_pct is not None and conc_pct > 80:
        flags.append(f"⚠ Concentración de ingreso {conc_pct:.0f}% en una fuente (dependencia alta)")
    for c in cards_with_debt:
        if c.utilization_pct is not None and c.utilization_pct > 30:
            flags.append(f"⚠ {c.institution} al {c.utilization_pct:.0f}% de utilización (>30%)")
    if run is not None and run < 6:
        flags.append(f"⚠ Liquidity runway {run} meses (<6)")
    if last_month and len(last_month_txs) < 10:
        flags.append(f"ℹ {last_month} tiene pocas transacciones ({len(last_month_txs)}) — posiblemente incompleto")

    return {
        "coverage": {
            "span": span,
            "months": months,
            "txs_live": len(txs),
            "last_month": last_month,
            "last_month_tx_count": len(last_month_txs),
            "certainty": "Hecho",
        },
        "wealth": {
            "net_worth": nw,
            "net_worth_note": nw_note,
            "available_net_worth": anw,
            "available_net_worth_note": anw_note,
            "composition": {k: str(v) for k, v in comp.items()},
            "cagr": (str(cagr_val) if cagr_val is not None else None, cagr_note),
            "liquidity_runway": (str(run) if run is not None else None, run_note),
            "certainty": "Derivado (punto en el tiempo; proyecciones Supuesto)",
        },
        "income": {
            "sources": [{"label": s.label, "total": str(s.total), "count": s.count} for s in inc_sources],
            "savings_rate": [(m, (str(r) if r else None), note) for m, r, note in sav],
            "concentration": ((str(conc_pct) if conc_pct else None), conc_note),
            "certainty": "Hecho (movimientos) → Derivado (cálculo); riesgo Supuesto",
        },
        "habits": {
            "top_merchants": [{"label": b.label, "total": str(b.total), "count": b.count} for b in top_merchants],
            "recurring": [{"label": b.label, "total": str(b.total), "count": b.count, "certainty": "Inferido"} for b in rec],
            "mom_delta": [(c, str(p), str(cur), str(d)) for c, p, cur, d in mom],
            "certainty": "Derivado; recurrentes Inferido",
        },
        "debt": {
            "cards": [{
                "institution": c.institution, "balance": str(c.balance), "source": c.source,
                "utilization_pct": (str(c.utilization_pct) if c.utilization_pct is not None else None),
                "pay_for_no_interest": (str(c.pay_for_no_interest) if c.pay_for_no_interest is not None else None),
            } for c in cards_with_debt],
            "certainty": "Hecho (saldos) → Supuesto (proyecciones)",
        },
        "flags": flags,
    }


if __name__ == "__main__":
    load = _load_module("load", _SHARED / "load.py")
    import json
    ds = load.load_dataset()
    txs = load.live_transactions(ds)
    print(json.dumps(build_report(ds, txs), indent=2, default=str, ensure_ascii=False))
