"""Agregaciones de deuda — saldos de tarjetas/préstamos, utilización, avalancha/bola de nieve, runway.

Combina Statement.closingBalance y AccountBalanceSnapshot para resolver el saldo actual
(como AccountBalanceResolver, simplificado). Proyecciones marcadas como Supuesto.
"""
from __future__ import annotations

import sys
from dataclasses import dataclass, field
from decimal import Decimal
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

_SHARED = str(Path(__file__).resolve().parents[2] / "_shared")
sys.path.insert(0, _SHARED)


@dataclass
class CardBalance:
    account_id: str
    institution: str
    nickname: str
    balance: Decimal            # negativo = deuda (convención de la app)
    source: str                 # "statement.closingBalance" | "balanceSnapshot" | "none"
    credit_limit: Optional[Decimal]
    utilization_pct: Optional[Decimal]
    pay_for_no_interest: Optional[Decimal]   # PGI del último estado
    minimum_payment: Optional[Decimal]
    payment_due_date: Optional[str]


def _latest_statement(ds, account_id):
    stmts = [s for s in ds["statements"] if s.get("accountId") == account_id]
    if not stmts:
        return None
    return max(stmts, key=lambda s: s.get("periodEnd", ""))


def _latest_balance_snapshot(ds, account_id):
    snaps = [s for s in ds["snapshots"] if s.get("accountId") == account_id]
    if not snaps:
        return None
    return max(snaps, key=lambda s: s.get("date", ""))


def liability_balances(ds: Dict[str, Any]) -> List[CardBalance]:
    """Saldo actual por cuenta de pasivo. Combina statement closing + balance snapshot."""
    out = []
    for a in ds["models"]["Account"]:
        if a.get("type") not in ("creditCard", "loan"):
            continue
        aid = a["id"]
        stmt = _latest_statement(ds, aid)
        snap = _latest_balance_snapshot(ds, aid)

        balance = None
        source = "none"
        # preferimos closingBalance del último statement que lo tenga
        if stmt and stmt.get("closingBalance") is not None:
            balance = Decimal(str(stmt["closingBalance"]))
            source = "statement.closingBalance"
        elif snap and snap.get("amount") is not None:
            balance = Decimal(str(snap["amount"]))
            source = "balanceSnapshot"
        if balance is None:
            balance = Decimal(0)
            source = "none"

        limit = Decimal(str(a["creditLimit"])) if a.get("creditLimit") is not None else None
        util = (abs(balance) / limit * Decimal(100)) if (limit and limit > 0) else None

        out.append(CardBalance(
            account_id=aid,
            institution=a.get("institution", ""),
            nickname=a.get("nickname") or a.get("institution", ""),
            balance=balance,
            source=source,
            credit_limit=limit,
            utilization_pct=util,
            pay_for_no_interest=(Decimal(str(stmt["paymentForNoInterest"]))
                                 if stmt and stmt.get("paymentForNoInterest") is not None else None),
            minimum_payment=(Decimal(str(stmt["minimumPayment"]))
                             if stmt and stmt.get("minimumPayment") is not None else None),
            payment_due_date=(stmt.get("paymentDueDate")[:10] if stmt and stmt.get("paymentDueDate") else None),
        ))
    # tarjetas con deuda primero
    out.sort(key=lambda c: c.balance)
    return out


def _estimate_apr(card: CardBalance, ds, account_id) -> Optional[Decimal]:
    """APR estimada anual desde el interés cobrado en el último estado. None si no hay datos."""
    stmt = _latest_statement(ds, account_id)
    if not stmt:
        return None
    interest = stmt.get("interestCharged")
    if interest is None or Decimal(str(interest)) == 0:
        return None
    # interés mensual / saldo promedio ≈ tasa mensual; ×12 = APR aprox
    if card.balance == 0:
        return None
    monthly_rate = Decimal(str(interest)) / abs(card.balance)
    return monthly_rate * Decimal(12) * Decimal(100)


def avalanche(ds: Dict[str, Any], monthly_budget: Decimal) -> List[Tuple[CardBalance, Optional[Decimal], str]]:
    """Orden de ataque: mayor APR primero. Supuesto. Devuelve [(card, apr_pct%, nota)]."""
    cards = [c for c in liability_balances(ds) if c.balance < 0]
    scored = []
    for c in cards:
        apr = _estimate_apr(c, ds, c.account_id)
        scored.append((c, apr))
    # mayor APR primero; sin APR → al final (deuda sin interés es barata de mantener)
    scored.sort(key=lambda x: (x[1] is None, -(x[1] or Decimal(0))))
    return [(c, apr, "Supuesto: budget fijo, sin cargos nuevos") for c, apr in scored]


def snowball(ds: Dict[str, Any], monthly_budget: Decimal) -> List[Tuple[CardBalance, str]]:
    """Orden de ataque: menor saldo primero. Supuesto."""
    cards = [c for c in liability_balances(ds) if c.balance < 0]
    cards.sort(key=lambda c: abs(c.balance))
    return [(c, "Supuesto: budget fijo, sin cargos nuevos") for c in cards]


def runway(ds: Dict[str, Any]) -> List[Tuple[CardBalance, Decimal, str]]:
    """Para cada tarjeta con PGI: meses al pago-para-no-generar-intereses asumiendo
    que pagas el mínimo (Derivado). Si mínimo ≥ PGI → 0 meses (ya cubierto)."""
    out = []
    for c in liability_balances(ds):
        if c.balance >= 0:
            continue
        if c.pay_for_no_interest is None or c.pay_for_no_interest == 0:
            continue
        pgi = c.pay_for_no_interest
        monthly = c.minimum_payment or Decimal(0)
        if monthly <= 0:
            out.append((c, pgi, "Sin mínimo conocido — no se puede proyectar"))
            continue
        months = (pgi / monthly).quantize(Decimal("0.1"))
        note = f"Derivado: a ${monthly:,.0f}/mes serían ~{months} meses para cubrir el PGI de ${pgi:,.0f}"
        out.append((c, pgi, note))
    return out
