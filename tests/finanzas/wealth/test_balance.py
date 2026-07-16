"""Tests del resolver de saldo reconstruido (balance.py) — una rama por test.

Usa make_ds() sintético (sin .ftbackup real, sin PII).
"""
from __future__ import annotations

from datetime import UTC, datetime
from decimal import Decimal

import balance as B

from conftest import make_ds

D = Decimal
AS_OF = datetime(2026, 7, 15, tzinfo=UTC)


def test_general_case_with_statement_anchor():
    # statement anchor en jul 1 + txs posteriores → reconstruido
    ds = make_ds(
        statements=[{"id": "st1", "accountId": "ACCT-1", "closingBalance": 5000,
                     "periodEnd": "2026-07-01T00:00:00Z"}],
        transactions=[
            {"id": "t1", "accountId": "ACCT-1", "amount": 1000,
             "postedAt": "2026-07-10T00:00:00Z", "statementId": None,
             "isDuplicate": False, "deletedAt": None},
        ],
    )
    r = B.resolve(ds, "ACCT-1", AS_OF)
    assert r.source_kind == "reconstructed"
    assert r.amount == D(6000)


def test_general_case_no_anchor_with_txs():
    # sin anchor, solo txs → base 0 + suma
    ds = make_ds(transactions=[
        {"id": "t1", "accountId": "ACCT-1", "amount": 300,
         "postedAt": "2026-07-01T00:00:00Z", "statementId": None,
         "isDuplicate": False, "deletedAt": None},
        {"id": "t2", "accountId": "ACCT-1", "amount": 200,
         "postedAt": "2026-07-05T00:00:00Z", "statementId": None,
         "isDuplicate": False, "deletedAt": None},
    ])
    r = B.resolve(ds, "ACCT-1", AS_OF)
    assert r.source_kind == "reconstructed"
    assert r.amount == D(500)


def test_general_case_no_anchor_no_txs_insufficient():
    ds = make_ds()
    r = B.resolve(ds, "ACCT-1", AS_OF)
    assert r.source_kind == "insufficient"
    assert r.amount == 0


def test_portfolio_valuation_short_circuit():
    # portfolioValuation → monto tal cual, sin deltas (incluso con txs)
    ds = make_ds(
        snapshots=[{"id": "pv1", "accountId": "ACCT-1", "amount": 12345,
                    "date": "2026-07-10T00:00:00Z", "kind": "portfolioValuation"}],
        transactions=[
            {"id": "t1", "accountId": "ACCT-1", "amount": 9999,
             "postedAt": "2026-07-12T00:00:00Z", "statementId": None,
             "isDuplicate": False, "deletedAt": None},
        ],
    )
    r = B.resolve(ds, "ACCT-1", AS_OF)
    assert r.amount == D(12345)   # el tx NO se suma
    assert r.source_kind in ("exact", "latest_prior")


def test_b1_manual_opening_with_later_anchor():
    # sin statements; manualOpening + manualAdjustment posterior → B1 usa el posterior
    ds = make_ds(
        accounts=[{"id": "ACCT-1", "type": "checking", "openedAt": "2026-01-01T00:00:00Z"}],
        snapshots=[
            {"id": "o1", "accountId": "ACCT-1", "amount": 0,
             "date": "2026-01-01T00:00:00Z", "kind": "manualOpening"},
            {"id": "a1", "accountId": "ACCT-1", "amount": 2000,
             "date": "2026-06-01T00:00:00Z", "kind": "manualAdjustment"},
        ],
        transactions=[
            {"id": "t1", "accountId": "ACCT-1", "amount": 500,
             "postedAt": "2026-07-05T00:00:00Z", "statementId": None,
             "isDuplicate": False, "deletedAt": None},
        ],
    )
    r = B.resolve(ds, "ACCT-1", AS_OF)
    # base 2000 (a1, posterior al opening) + 500
    assert r.amount == D(2500)


def test_b2_manual_opening_no_later_anchor():
    # sin statements, solo manualOpening, sin anchor posterior → B2 desde openedAt
    ds = make_ds(
        accounts=[{"id": "ACCT-1", "type": "checking", "openedAt": "2026-01-01T00:00:00Z"}],
        snapshots=[{"id": "o1", "accountId": "ACCT-1", "amount": 100,
                    "date": "2026-01-01T00:00:00Z", "kind": "manualOpening"}],
        transactions=[
            {"id": "t1", "accountId": "ACCT-1", "amount": 700,
             "postedAt": "2026-03-01T00:00:00Z", "statementId": None,
             "isDuplicate": False, "deletedAt": None},
        ],
    )
    r = B.resolve(ds, "ACCT-1", AS_OF)
    assert r.amount == D(800)   # 100 + 700


def test_deleted_mirror_snapshot_excluded():
    # snapshot cuyo id colisiona con tx soft-deleted → excluido
    ds = make_ds(
        snapshots=[
            {"id": "MIRROR", "accountId": "ACCT-1", "amount": 99999,
             "date": "2026-07-10T00:00:00Z", "kind": "manualAdjustment"},
        ],
        transactions=[
            {"id": "MIRROR", "accountId": "ACCT-1", "amount": 0,
             "postedAt": "2026-07-10T00:00:00Z", "statementId": None,
             "isDuplicate": False, "deletedAt": "2026-07-11T00:00:00Z"},
        ],
    )
    r = B.resolve(ds, "ACCT-1", AS_OF)
    assert r.source_kind == "insufficient"   # el mirror se excluyó y no hay más


def test_duplicate_and_statement_txs_excluded():
    ds = make_ds(
        snapshots=[{"id": "s1", "accountId": "ACCT-1", "amount": 1000,
                    "date": "2026-07-01T00:00:00Z", "kind": "manualAdjustment"}],
        transactions=[
            {"id": "dup", "accountId": "ACCT-1", "amount": 5000,
             "postedAt": "2026-07-05T00:00:00Z", "statementId": None,
             "isDuplicate": True, "deletedAt": None},
            {"id": "onstmt", "accountId": "ACCT-1", "amount": 5000,
             "postedAt": "2026-07-06T00:00:00Z", "statementId": "ST-1",
             "isDuplicate": False, "deletedAt": None},
            {"id": "ok", "accountId": "ACCT-1", "amount": 200,
             "postedAt": "2026-07-07T00:00:00Z", "statementId": None,
             "isDuplicate": False, "deletedAt": None},
        ],
    )
    r = B.resolve(ds, "ACCT-1", AS_OF)
    assert r.amount == D(1200)   # solo el "ok" se suma; dup y onstmt excluidos


def test_signs_used_as_stored_no_resigning():
    # liability: monto>0 reduce deuda, <0 aumenta. Se suma tal cual.
    ds = make_ds(
        accounts=[{"id": "ACCT-1", "type": "creditCard", "openedAt": "2026-01-01T00:00:00Z"}],
        statements=[{"id": "st1", "accountId": "ACCT-1", "closingBalance": -10000,
                     "periodEnd": "2026-07-01T00:00:00Z"}],
        transactions=[
            {"id": "pay", "accountId": "ACCT-1", "amount": 3000,   # pago reduce deuda
             "postedAt": "2026-07-05T00:00:00Z", "statementId": None,
             "isDuplicate": False, "deletedAt": None},
        ],
    )
    r = B.resolve(ds, "ACCT-1", AS_OF)
    assert r.amount == D(-7000)   # -10000 + 3000


def test_tie_break_prefers_statement_over_snapshot():
    # statement y snapshot con la MISMA fecha → statement gana (igual que Swift).
    ds = make_ds(
        statements=[{"id": "st1", "accountId": "ACCT-1", "closingBalance": 5000,
                     "periodEnd": "2026-07-01T00:00:00Z"}],
        snapshots=[{"id": "s1", "accountId": "ACCT-1", "amount": 9999,
                    "date": "2026-07-01T00:00:00Z", "kind": "manualAdjustment"}],
    )
    r = B.resolve(ds, "ACCT-1", AS_OF)
    assert r.amount == D(5000)   # statement (5000), no snapshot (9999)
    assert r.anchor_kind == "statement"


def test_deleted_mirror_with_statement_tx_not_excluded():
    # un tx soft-deleted CON statementId NO debe contar como mirror (Swift: statement==nil && deletedAt).
    # Su id NO debe excluir el snapshot con mismo id.
    ds = make_ds(
        snapshots=[{"id": "KEEP", "accountId": "ACCT-1", "amount": 3000,
                    "date": "2026-07-01T00:00:00Z", "kind": "manualAdjustment"}],
        transactions=[
            {"id": "KEEP", "accountId": "ACCT-1", "amount": 0,
             "postedAt": "2026-07-01T00:00:00Z", "statementId": "ST-X",
             "isDuplicate": False, "deletedAt": "2026-07-02T00:00:00Z"},
        ],
    )
    r = B.resolve(ds, "ACCT-1", AS_OF)
    # el snapshot KEEP NO se excluye porque el tx mirror tiene statementId
    assert r.amount == D(3000)
    assert r.source_kind != "insufficient"


def test_net_worth_at_respects_as_of():
    # net_worth_at con as_of explícito debe resolver a esa fecha, no al default.
    import aggregate as A
    ds = make_ds(
        snapshots=[{"id": "s1", "accountId": "ACCT-1", "amount": 1000,
                    "date": "2026-07-01T00:00:00Z", "kind": "manualAdjustment"}],
        transactions=[
            {"id": "t1", "accountId": "ACCT-1", "amount": 500,
             "postedAt": "2026-07-20T00:00:00Z", "statementId": None,
             "isDuplicate": False, "deletedAt": None},
        ],
    )
    early, _ = A.net_worth_at(ds, "2026-07-10")
    late, _ = A.net_worth_at(ds, "2026-07-25")
    assert early == D(1000)   # antes del tx
    assert late == D(1500)    # después del tx
