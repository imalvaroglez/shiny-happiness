"""Tracker de promoción: clasificación por patrón primero, ventana 90 días y proyecciones."""
from __future__ import annotations

from decimal import Decimal
from pathlib import Path

import pytest

from conftest import load_module_by_path

promo = load_module_by_path("promo_tracker", Path(__file__).resolve().parents[2] / ".claude" / "skills" / "finanzas" / "habits" / "scripts" / "promo.py")


# --- ds sintético en memoria (shape de load.load_dataset) --------------------

CATS = {
    "GM": {"id": "GM", "name": "General Merchandise", "parentId": None, "kind": "expense", "deletedAt": None},
    "BANK-FEES": {"id": "BANK-FEES", "name": "Bank Fees", "parentId": None, "kind": "expense", "deletedAt": None},
    "CC-PAY": {"id": "CC-PAY", "name": "Credit Card Payments", "parentId": None, "kind": "creditCardPayment", "deletedAt": None},
    "SHOPPING": {"id": "SHOPPING", "name": "Shopping", "parentId": None, "kind": "expense", "deletedAt": None},
}
ACCOUNT = {"id": "AMEX", "type": "creditCard", "nickname": "The Platinum Credit Card",
           "institution": "American Express Mexico", "currency": "MXN",
           "includeInCashFlow": True, "includeInRegularIncome": True, "lastModifiedAt": "2026-09-21T00:00:00Z"}


def tx(tx_id: str, amount: str, posted: str, desc: str, cat: str = "SHOPPING", **extra) -> dict:
    row = {"id": tx_id, "accountId": "AMEX", "amount": float(amount), "postedAt": posted,
           "descriptionRaw": desc, "categoryId": cat, "deletedAt": None, "isDuplicate": False,
           "isTransfer": False, "lastModifiedAt": "2026-09-21T00:00:00Z"}
    row.update(extra)
    return row


def make_ds(rows: list[dict]) -> dict:
    return {
        "accounts": {ACCOUNT["id"]: ACCOUNT},
        "categories": CATS,
        "transactions": rows,
        "models": {"Account": [ACCOUNT], "Category": list(CATS.values()), "Transaction": rows},
    }


# --- clasificación por fila ---------------------------------------------------

@pytest.mark.parametrize("row, expected_kind", [
    (tx("t1", "-100.00", "2026-09-10T06:00:00Z", "OXXO 123"), "normal_charge"),
    # cuota MSI: el PATRÓN manda aunque la categoría mienta (Bank Fees)
    (tx("t2", "-10018.38", "2026-09-11T06:00:00Z", "MSI 1/3", cat="BANK-FEES"), "msi_installment"),
    (tx("t3", "-6062.87", "2026-09-11T06:00:00Z", "MSI 3/3", cat="BANK-FEES"), "msi_installment"),
    (tx("t4", "-1029.53", "2026-09-11T06:00:00Z", "MESES EN AUTOMÁTICO: VERSA 1/3"), "msi_installment"),
    (tx("t5", "-1333.56", "2026-09-12T06:00:00Z", "Amazon MSI"), "msi_installment_probable"),
    # créditos: excluidos (reversión MSI / reembolso)
    (tx("t6", "30055.12", "2026-09-11T06:00:00Z", "MESES EN AUTOMÁTICO", cat="BANK-FEES"), "credit"),
    (tx("t7", "150.00", "2026-09-14T06:00:00Z", "BONIFICACION WALMART"), "credit"),
    # pagos: excluidos
    (tx("t8", "20265.46", "2026-09-01T06:00:00Z", "GRACIAS POR SU PAGO EN LINEA", cat="CC-PAY"), "payment"),
    # fee real (categoría fees SIN patrón MSI): no elegible
    (tx("t9", "-696.00", "2026-09-17T06:00:00Z", "CARGO POR PAGO TARDÍO + IVA", cat="BANK-FEES"), "fee"),
    # transferencia marcada: excluida
    (tx("t10", "-500.00", "2026-09-16T06:00:00Z", "TRANSFER", isTransfer=True), "excluded"),
    # soft-deleted / duplicado: excluidos
    (tx("t11", "-50.00", "2026-09-16T06:00:00Z", "X", deletedAt="2026-09-20T00:00:00Z"), "excluded"),
    (tx("t12", "-50.00", "2026-09-16T06:00:00Z", "Y", isDuplicate=True), "excluded"),
])
def test_classify_promo_kinds(row: dict, expected_kind: str) -> None:
    from accounting_gates import account_from_snapshot, category_from_snapshot
    result = promo.classify_promo(
        row, account_from_snapshot(ACCOUNT), category_from_snapshot(CATS[row["categoryId"]])
    )
    assert result.kind == expected_kind
    if expected_kind in ("normal_charge", "msi_installment", "msi_installment_probable"):
        assert result.eligible is not None
    else:
        assert result.eligible is None


def test_eligible_amounts_are_positive_decimals() -> None:
    from accounting_gates import account_from_snapshot, category_from_snapshot
    row = tx("t", "-10018.38", "2026-09-11T06:00:00Z", "MSI 1/3", cat="BANK-FEES")
    result = promo.classify_promo(row, account_from_snapshot(ACCOUNT), category_from_snapshot(CATS["BANK-FEES"]))
    assert result.eligible == Decimal("10018.38")


# --- ventana -------------------------------------------------------------------

def test_window_bounds_cdmx() -> None:
    start, end = promo.window_bounds("2026-09-09", days=90)
    assert start == "2026-09-09T06:00:00Z"   # 00:00 CDMX (UTC-6)
    assert end == "2026-12-08T06:00:00Z"     # exclusive: día 90 = 7-dic inclusive


def test_window_filters_edges() -> None:
    rows = [
        tx("pre-1", "-10", "2026-09-08T23:00:00Z", "PRE1"),
        tx("pre-2", "-10", "2026-09-09T05:59:59Z", "PRE2"),
        tx("in-1", "-10", "2026-09-09T06:00:00Z", "IN1"),
        tx("in-2", "-10", "2026-12-07T23:00:00Z", "IN2"),
        tx("post", "-10", "2026-12-08T06:00:00Z", "POST"),
    ]
    ds = make_ds(rows)
    in_window = promo.transactions_in_window(ds, "The Platinum Credit Card", "2026-09-09", 90)
    assert [t["id"] for t in in_window] == ["in-1", "in-2"]


# --- reporte -------------------------------------------------------------------

def test_report_totals_and_targets() -> None:
    rows = [
        tx("a", "-10000.00", "2026-09-10T06:00:00Z", "SGMM GNP"),
        tx("b", "-10018.38", "2026-09-11T06:00:00Z", "MSI 1/3", cat="BANK-FEES"),
        tx("c", "30055.12", "2026-09-11T06:00:00Z", "MESES EN AUTOMÁTICO", cat="BANK-FEES"),
        tx("d", "-696.00", "2026-09-17T06:00:00Z", "CARGO POR PAGO TARDÍO", cat="BANK-FEES"),
        tx("e", "-5000.00", "2026-09-20T18:00:00Z", "AEROMEXICO"),
    ]
    report = promo.promo_report(make_ds(rows), account="The Platinum Credit Card",
                                start="2026-09-09", days=90, targets=[100000, 105000, 110000])
    assert report["gross"] == Decimal("-25714.38")  # todos los cargos, fees incluidos
    assert report["eligible_firm"] == Decimal("25018.38")  # sin el fee tardío
    assert report["excluded"][0]["id"] == "c"
    gap100k = next(g for g in report["gaps"] if g["target"] == 100000)
    assert gap100k["remaining"] == Decimal("100000") - Decimal("25018.38")
    assert 0 < gap100k["pct"] < 1
    # día N/90 se calcula contra la última tx visible, no contra el reloj
    assert report["day"] == 12  # 9-sep día 1 → 20-sep día 12
    assert report["days_remaining"] == 90 - 12


def test_report_flags_big_national_charge_msi_risk() -> None:
    rows = [tx("big", "-31674.00", "2026-09-15T06:00:00Z", "AEROMEXICO")]
    report = promo.promo_report(make_ds(rows), account="The Platinum Credit Card",
                                start="2026-09-09", days=90, targets=[100000])
    risks = [w for w in report["warnings"] if w["kind"] == "msi_conversion_risk"]
    assert risks and risks[0]["id"] == "big"


def test_projection_counts_only_installments_inside_window() -> None:
    # plan 1/3 visto el 11-sep → 2/3 ~11-oct, 3/3 ~11-nov: ambos ≤ 7-dic
    plans = [{"monthly": Decimal("10018.38"), "n": 1, "total": 3, "last_posted": "2026-09-11"}]
    assert promo.project_installments(plans, "2026-12-08T06:00:00Z") == Decimal("20036.76")
    # plan 1/12 visto el 11-sep → solo cuotas 2 (11-oct) y 3 (11-nov) caen ≤ 7-dic
    plans = [{"monthly": Decimal("1000"), "n": 1, "total": 12, "last_posted": "2026-09-11"}]
    assert promo.project_installments(plans, "2026-12-08T06:00:00Z") == Decimal("2000")


def test_projection_collapses_same_plan_rows() -> None:
    """Bug review #1: dos cuotas del MISMO plan en ventana → un plan, proyecta solo las restantes."""
    rows = [
        tx("c1", "-10018.38", "2026-09-11T06:00:00Z", "MSI 1/3", cat="BANK-FEES"),
        tx("c2", "-10018.38", "2026-10-11T06:00:00Z", "MSI 2/3", cat="BANK-FEES"),
    ]
    plans = promo._installment_plans_from(rows)
    assert len(plans) == 1 and plans[0]["n"] == 2
    assert promo.project_installments(plans, "2026-12-08T06:00:00Z") == Decimal("10018.38")


def test_projection_keeps_distinct_plans_same_amount() -> None:
    """Bug review #2: dos planes distintos con mismo monto y distinta descripción → ambos proyectan."""
    rows = [
        tx("p1", "-1000", "2026-09-11T06:00:00Z", "MESES EN AUTOMÁTICO: Compra A 1/3"),
        tx("p2", "-1000", "2026-09-12T06:00:00Z", "MESES EN AUTOMÁTICO: Compra B 1/3"),
    ]
    plans = promo._installment_plans_from(rows)
    assert len(plans) == 2
    assert promo.project_installments(plans, "2026-12-08T06:00:00Z") == Decimal("4000")


def test_counter_ignores_embedded_dates() -> None:
    """Hardening review #4: una fecha '08/05/2026' antes del contador no debe leerse como n/total."""
    rows = [tx("d1", "-1000", "2026-09-11T06:00:00Z", "COMPRA 08/05/2026 MSI 2/3", cat="BANK-FEES")]
    plans = promo._installment_plans_from(rows)
    assert plans and plans[0]["n"] == 2 and plans[0]["total"] == 3


def test_find_account_ambiguous_institution_requires_nickname() -> None:
    """Nota review: institución ambigua (dos Amex) → exige nickname exacto."""
    ds = make_ds([])
    ds["models"]["Account"].append({**ACCOUNT, "id": "AMEX2", "nickname": "Otra Amex"})
    with pytest.raises(ValueError, match="nickname"):
        promo._find_account_row(ds, "American Express Mexico")
    assert promo._find_account_row(ds, "The Platinum Credit Card")["id"] == "AMEX"
