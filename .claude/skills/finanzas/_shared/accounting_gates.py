"""Accounting gates — replica fiel de TransactionClassifier.swift sobre los dicts del .ftbackup.

Esto es la ÚNICA fuente de verdad para qué cuenta como ingreso/gasto/flujo de caja.
Toda sub-skill importa desde aquí; nunca reimplementes estos filtros.

Replica:
  - TransactionClassifier.classify (fast-path + full-path)
  - Transaction.flowKind / movementKind / treatmentKind (raw o derivado)
  - isSynthesizedMSIPurchase
  - ownAccountPatterns (regex de movimientos entre cuentas propias)
  - Account.effectiveIncludeInCashFlow / effectiveIncludeInRegularIncome

Trabaja con dicts planos (los TransactionSnapshot del JSON), no con @Model.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from decimal import Decimal
from typing import Any, Dict, Optional

# --- rawValues canónicos (de ValueObjects/*.swift) ---
LIABILITY_TYPES = {"creditCard", "loan"}

_OWN_ACCOUNT_PATTERNS = [
    r"(?i)PAGO\s+RECIBIDO\s+DE\s+STP\s+POR\s+ORDEN\s+DE\s+TITULAR",
    r"(?i)recibida\s+(de\s+la\s+)?cuenta\s+4444\s+BANAMEX",
    r"(?i)PAGO\s+INTERBANCARIO\s+PAGO\s+RECIBIDO\s+DE.*STP.*TITULAR",
]
_OWN_ACCOUNT_COMPILED = [re.compile(p) for p in _OWN_ACCOUNT_PATTERNS]


def _might_be_own_account(description: str) -> bool:
    d = description or ""
    return ("STP" in d.upper()) or ("BANAMEX" in d.upper()) or ("CUENTA" in d.upper())


def is_own_account_movement(tx: Dict[str, Any]) -> bool:
    """Regex full-match contra los 3 patrones de movimientos entre cuentas propias."""
    d = tx.get("descriptionRaw") or ""
    if not _might_be_own_account(d):
        return False
    return any(p.search(d) for p in _OWN_ACCOUNT_COMPILED)


@dataclass
class Account:
    """Vista mínima de AccountSnapshot — solo lo que los gates necesitan."""
    id: str
    type: str
    include_in_cash_flow: Optional[bool]
    include_in_regular_income: Optional[bool]

    @property
    def is_liability(self) -> bool:
        return self.type in LIABILITY_TYPES

    @property
    def effective_include_in_cash_flow(self) -> bool:
        # default true; false si la app lo marca explícitamente
        v = self.include_in_cash_flow
        if v is None:
            # default por tipo: investment/retirement → false; resto → true
            return self.type not in ("investment", "retirement")
        return v

    @property
    def effective_include_in_regular_income(self) -> bool:
        v = self.include_in_regular_income
        if v is None:
            return self.type not in ("investment", "retirement", "creditCard", "loan")
        return v


@dataclass
class Category:
    id: str
    name: str
    kind: str  # income | expense | transfer | investment | creditCardPayment
    deleted_at: Optional[str]


def account_from_snapshot(snap: Dict[str, Any]) -> Account:
    return Account(
        id=snap["id"],
        type=snap.get("type", "other"),
        include_in_cash_flow=snap.get("includeInCashFlow"),
        include_in_regular_income=snap.get("includeInRegularIncome"),
    )


def category_from_snapshot(snap: Dict[str, Any]) -> Category:
    return Category(
        id=snap["id"],
        name=snap.get("name", ""),
        kind=snap.get("kind", "expense"),
        deleted_at=snap.get("deletedAt"),
    )


# --- derivaciones (Transaction.swift) ---
def flow_kind(
    tx: Dict[str, Any],
    account: Optional[Account],
    category: Optional[Category],
) -> str:
    raw = tx.get("flowKindRaw")
    if raw in ("income", "expense", "transfer", "charge", "cardCredit", "payment"):
        return raw
    if tx.get("isTransfer"):
        return "transfer"
    if account is not None and account.is_liability:
        amount = Decimal(str(tx.get("amount", 0)))
        if amount > 0:
            return "payment" if (category and category.kind == "creditCardPayment") else "cardCredit"
        return "charge"
    return "income" if Decimal(str(tx.get("amount", 0))) >= 0 else "expense"


def movement_kind(tx: Dict[str, Any], flow: str) -> str:
    raw = tx.get("movementKindRaw")
    if raw in ("income", "expense", "transfer", "adjustment"):
        return raw
    if tx.get("isTransfer"):
        return "transfer"
    return {
        "income": "income",
        "expense": "expense",
        "charge": "expense",
        "transfer": "transfer",
        "payment": "transfer",
        "cardCredit": "adjustment",
    }[flow]


def treatment_kind(tx: Dict[str, Any]) -> str:
    raw = tx.get("treatmentKindRaw")
    valid = {
        "regular",
        "retirementContributionUserFunded",
        "retirementContributionEmployerFunded",
        "statutoryRetirementContribution",
        "investmentReturn",
        "fee",
        "valuationAdjustment",
    }
    return raw if raw in valid else "regular"


def is_synthesized_msi_purchase(tx: Dict[str, Any], plan_lookup) -> bool:
    """plan_lookup: callable(installmentPlanId) -> Optional[dict con originalAmount]."""
    pid = tx.get("installmentPlanId")
    if not pid:
        return False
    plan = plan_lookup(pid)
    if not plan:
        return False
    orig = Decimal(str(plan.get("originalAmount", 0)))
    if orig == 0:
        return False
    return abs(Decimal(str(tx.get("amount", 0)))) == abs(orig)


@dataclass
class Classification:
    is_transfer: bool
    affects_balance: bool
    counts_as_regular_income: bool
    counts_as_regular_expense: bool
    counts_as_operating_cash_flow: bool
    counts_as_retirement_contribution: bool
    counts_as_investment_return: bool
    counts_as_valuation_adjustment: bool
    excluded_from_cash_flow: bool  # conveniencia para agregaciones


def classify(
    tx: Dict[str, Any],
    account: Optional[Account] = None,
    category: Optional[Category] = None,
    plan_lookup=None,
) -> Classification:
    """Réplica de TransactionClassifier.classify. plan_lookup obligatorio para MSI."""
    if plan_lookup is None:
        plan_lookup = lambda _pid: None

    deleted = tx.get("deletedAt") is not None
    duplicate = bool(tx.get("isDuplicate"))

    # --- fast path (idéntico al Swift) ---
    if (
        tx.get("flowKindRaw") is None
        and tx.get("movementKindRaw") is None
        and tx.get("treatmentKindRaw") is None
        and not tx.get("isTransfer")
        and not duplicate
        and not deleted
        and tx.get("installmentPlanId") is None
        and category is None
        and not (account is not None and account.is_liability)
        and (account.effective_include_in_cash_flow if account else True)
        and not _might_be_own_account(tx.get("descriptionRaw") or "")
    ):
        amount = Decimal(str(tx.get("amount", 0)))
        reg_income = amount > 0 and (account.effective_include_in_regular_income if account else True)
        reg_expense = amount < 0
        return Classification(
            is_transfer=False,
            affects_balance=True,
            counts_as_regular_income=reg_income,
            counts_as_regular_expense=reg_expense,
            counts_as_operating_cash_flow=reg_income or reg_expense,
            counts_as_retirement_contribution=False,
            counts_as_investment_return=False,
            counts_as_valuation_adjustment=False,
            excluded_from_cash_flow=False,
        )

    # --- full path ---
    flow = flow_kind(tx, account, category)
    movement = movement_kind(tx, flow)
    treatment = treatment_kind(tx)

    is_transfer = (
        movement == "transfer"
        or bool(tx.get("isTransfer"))
        or (category is not None and category.kind == "transfer")
        or (category is not None and category.kind == "creditCardPayment")
    )
    retirement = treatment in (
        "retirementContributionUserFunded",
        "retirementContributionEmployerFunded",
        "statutoryRetirementContribution",
    )
    investment_return = treatment == "investmentReturn"
    valuation = treatment == "valuationAdjustment"
    fee = treatment == "fee"

    old_excluded = (
        duplicate
        or is_transfer
        or (account is not None and account.is_liability and Decimal(str(tx.get("amount", 0))) > 0)
        or is_own_account_movement(tx)
        or is_synthesized_msi_purchase(tx, plan_lookup)
    )
    semantic_excluded = retirement or investment_return or valuation or fee
    account_allows = account.effective_include_in_cash_flow if account else True
    cash_flow_eligible = not old_excluded and not semantic_excluded and account_allows

    amount = Decimal(str(tx.get("amount", 0)))
    reg_income = (
        cash_flow_eligible
        and amount > 0
        and movement == "income"
        and treatment == "regular"
        and (account.effective_include_in_regular_income if account else True)
    )
    reg_expense = cash_flow_eligible and amount < 0 and movement == "expense" and treatment == "regular"

    return Classification(
        is_transfer=is_transfer,
        affects_balance=not deleted and not duplicate,
        counts_as_regular_income=reg_income,
        counts_as_regular_expense=reg_expense,
        counts_as_operating_cash_flow=reg_income or reg_expense,
        counts_as_retirement_contribution=retirement,
        counts_as_investment_return=investment_return,
        counts_as_valuation_adjustment=valuation,
        excluded_from_cash_flow=not cash_flow_eligible,
    )
