"""Fixtures for finanzas/wealth tests — synthetic `ds` builder, no real .ftbackup.

`make_ds()` builds the exact dict shape load.load_dataset() produces, with the
REAL field names confirmed against a live bundle:
  Transaction:   id, accountId, amount, postedAt, deletedAt, isDuplicate, statementId
  Snapshot:      id, accountId, amount, date, kind (manualOpening|manualAdjustment|portfolioValuation)
  Statement:     id, accountId, closingBalance, periodEnd
  Account:       id, type, institution, nickname, openedAt, liquidityRaw, includeInNetWorth, currency

Never commit a real .ftbackup (it holds PII). All test data is fabricated here.
"""
from __future__ import annotations

from typing import Any

import pytest

AID = "ACCT-1"


def _tx(id_: str, amount: float, posted_at: str, *, account=AID,
        statement_id=None, deleted_at=None, is_duplicate=False,
        movement="regular", treatment="regular", flow="expense") -> dict[str, Any]:
    return {
        "id": id_, "accountId": account, "amount": amount, "postedAt": posted_at,
        "deletedAt": deleted_at, "isDuplicate": is_duplicate, "statementId": statement_id,
        "movementKindRaw": movement, "treatmentKindRaw": treatment, "flowKindRaw": flow,
        "currency": "MXN",
    }


def _snap(id_: str, amount: float, date_: str, *, account=AID, kind="manualAdjustment") -> dict[str, Any]:
    return {"id": id_, "accountId": account, "amount": amount, "date": date_, "kind": kind}


def _stmt(id_: str, closing: float, period_end: str, *, account=AID) -> dict[str, Any]:
    return {"id": id_, "accountId": account, "closingBalance": closing, "periodEnd": period_end}


def _acct(*, account=AID, type_="checking", opened_at="2026-01-01T00:00:00Z",
          institution="TestBank", nickname="Test", liquidity="liquid",
          include_nw=True) -> dict[str, Any]:
    return {
        "id": account, "type": type_, "institution": institution, "nickname": nickname,
        "openedAt": opened_at, "liquidityRaw": liquidity, "includeInNetWorth": include_nw,
        "currency": "MXN",
    }


def make_ds(
    *,
    accounts: list[dict] | None = None,
    transactions: list[dict] | None = None,
    snapshots: list[dict] | None = None,
    statements: list[dict] | None = None,
) -> dict[str, Any]:
    """Build a minimal ds dict. Defaults to one empty checking account."""
    accounts = accounts if accounts is not None else [_acct()]
    transactions = transactions or []
    snapshots = snapshots or []
    statements = statements or []
    return {
        "accounts": {a["id"]: a for a in accounts},
        "transactions": transactions,
        "snapshots": snapshots,
        "statements": statements,
        "positions": [],
        "plans": {},
        "categories": {},
        "rules": [],
        "models": {
            "Account": accounts,
            "Transaction": transactions,
            "AccountBalanceSnapshot": snapshots,
            "Statement": statements,
            "Category": [],
            "StockPosition": [],
        },
        "bundle": None,
        "manifest": {"schemaVersion": 6, "appVersion": "0.11.0"},
    }


@pytest.fixture
def ds():
    return make_ds()
