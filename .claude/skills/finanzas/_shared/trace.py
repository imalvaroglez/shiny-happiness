"""Trazabilidad — desglosa un agregado a las Transaction.id concretas que lo produjeron.

Toda afirmación cuantitativa del skill se respalda listando los ids. Esto es lo que
separa "un número que suena bien" de "un número que puedes auditar".

Uso típico desde una sub-skill:
    from inspect import explain
    explain(txs_in_aggregate, label="Gasto en comida, jul 2026")
"""
from __future__ import annotations

from decimal import Decimal
from typing import Any, Dict, Iterable, List


def _fmt(d: Decimal) -> str:
    return f"{d:,.2f}"


def explain(txs: List[Dict[str, Any]], label: str = "") -> str:
    """Devuelve un string legible: total (abs), # txs, y lista de (fecha, monto, merchant, id)."""
    if not txs:
        return f"{'— ' + label if label else ''}(sin transacciones)"

    total = sum((Decimal(str(abs(t.get("amount", 0)))) for t in txs), Decimal(0))
    lines = []
    if label:
        lines.append(f"{label}")
    lines.append(f"  total |abs|: {_fmt(total)}  transacciones: {len(txs)}")
    for t in sorted(txs, key=lambda x: x.get("postedAt", "")):
        amt = Decimal(str(t.get("amount", 0)))
        date = (t.get("postedAt") or "")[:10]
        merch = t.get("merchantNormalized") or (t.get("descriptionRaw") or "")[:40]
        lines.append(f"    {date}  {_fmt(amt):>12}  {merch:<30}  id={t.get('id','')[:8]}")
    return "\n".join(lines)


def ids_of(txs: Iterable[Dict[str, Any]]) -> List[str]:
    return [t.get("id", "") for t in txs]
