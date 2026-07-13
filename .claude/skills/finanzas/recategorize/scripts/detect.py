"""Detección de transacciones mal categorizadas (Inferido).

Heurísticas:
  - merchant_category_mismatch: un merchant aparece mayoritariamente en categoría A pero
    algunas txs están en categoría B → sugiere mover las de B a A.
  - uncategorized_with_known_merchant: tx sin categoría pero con merchant que sí tiene
    categoría en otras txs → sugiere esa categoría.

Todo resultado es una propuesta (Inferido) que el usuario debe aprobar.
"""
from __future__ import annotations

import sys
from collections import defaultdict, Counter
from dataclasses import dataclass, field
from decimal import Decimal
from pathlib import Path
from typing import Any, Dict, List, Optional

_SHARED = str(Path(__file__).resolve().parents[2] / "_shared")
sys.path.insert(0, _SHARED)


@dataclass
class Proposal:
    tx_id: str
    posted_at: str
    merchant: str
    amount: Decimal
    current_category: str
    proposed_category_id: Optional[str]
    proposed_category: str
    reason: str
    certainty: str = "Inferido"


def _cat_name(ds, cat_id):
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


def _cat_id_for_name(ds, cat_id):
    """Si es hijo, devuelve su id; si es parent ya resuelto, el id."""
    return cat_id


def _cat_kind(ds, cat_id):
    """kind (income/expense/transfer/...) de una categoría, subiendo al parent si hace falta."""
    if not cat_id:
        return None
    c = ds["categories"].get(cat_id)
    if not c:
        return None
    # las subcategorías heredan kind del parent en la app; el JSON lo guarda en cada nodo
    return c.get("kind") or None


# pares de kinds entre los que NO proponemos mover: ambos son no-operativos
# (la distinción transfer↔creditCardPayment es semántica, no de gasto, y moverlos no cambia nada)
_NON_OPERATIVE_KINDS = {"transfer", "creditCardPayment"}


def merchant_category_mismatch(txs, ds) -> List[Proposal]:
    """Para cada merchant, encuentra su categoría modal (la más frecuente). Las txs del mismo
    merchant en otra categoría son candidatos a moverse (Inferido)."""
    by_merchant: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
    for t in txs:
        m = (t.get("merchantNormalized") or "").strip()
        if m:
            by_merchant[m].append(t)

    proposals = []
    for merchant, items in by_merchant.items():
        if len(items) < 3:
            continue  # necesitas volumen para que la categoría modal sea confiable
        cat_counter = Counter(_cat_name(ds, t.get("categoryId")) for t in items)
        modal_cat, modal_count = cat_counter.most_common(1)[0]
        # la moda debe ser clara (≥60% de las txs del merchant)
        if modal_count / len(items) < 0.6:
            continue
        modal_tx = next((x for x in items if _cat_name(ds, x.get("categoryId")) == modal_cat), None)
        modal_kind = _cat_kind(ds, modal_tx.get("categoryId")) if modal_tx else None
        # las txs que NO están en la categoría modal son candidatas
        for t in items:
            cur = _cat_name(ds, t.get("categoryId"))
            if cur != modal_cat and cur != "Uncategorized":
                cur_kind = _cat_kind(ds, t.get("categoryId"))
                # no proponer mover entre dos categorías no-operativas (transfer/ccPayment):
                # no cambia el cash flow y la distinción es semántica
                if (cur_kind in _NON_OPERATIVE_KINDS and modal_kind in _NON_OPERATIVE_KINDS):
                    continue
                proposed_id = modal_tx.get("categoryId") if modal_tx else None
                proposals.append(Proposal(
                    tx_id=t["id"],
                    posted_at=(t.get("postedAt") or "")[:10],
                    merchant=merchant,
                    amount=Decimal(str(t.get("amount", 0))),
                    current_category=cur,
                    proposed_category_id=proposed_id,
                    proposed_category=modal_cat,
                    reason=f"'{merchant}' aparece {modal_count}/{len(items)} veces en '{modal_cat}'",
                ))
    return proposals


def uncategorized_with_known_merchant(txs, ds) -> List[Proposal]:
    """Tx sin categoría cuyo merchant sí tiene categoría en otras txs → proponer esa."""
    by_merchant: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
    for t in txs:
        m = (t.get("merchantNormalized") or "").strip()
        if m:
            by_merchant[m].append(t)

    proposals = []
    for merchant, items in by_merchant.items():
        # ¿hay categoría conocida para este merchant?
        with_cat = [t for t in items if t.get("categoryId") and _cat_name(ds, t.get("categoryId")) != "Uncategorized"]
        if not with_cat:
            continue
        modal = Counter(_cat_name(ds, t.get("categoryId")) for t in with_cat).most_common(1)[0]
        modal_cat_name, modal_count = modal
        modal_tx = next(t for t in with_cat if _cat_name(ds, t.get("categoryId")) == modal_cat_name)
        proposed_id = modal_tx.get("categoryId")
        for t in items:
            if not t.get("categoryId") or _cat_name(ds, t.get("categoryId")) == "Uncategorized":
                proposals.append(Proposal(
                    tx_id=t["id"],
                    posted_at=(t.get("postedAt") or "")[:10],
                    merchant=merchant,
                    amount=Decimal(str(t.get("amount", 0))),
                    current_category="Uncategorized",
                    proposed_category_id=proposed_id,
                    proposed_category=modal_cat_name,
                    reason=f"'{merchant}' ya estaba categorizado como '{modal_cat_name}' en otras {modal_count} txs",
                ))
    return proposals
