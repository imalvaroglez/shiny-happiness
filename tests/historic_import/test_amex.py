"""Synthetic Amex-layout fixtures; no personal statement excerpts are committed."""

from decimal import Decimal

import amex
import pytest

HEADER_2021 = """
       1,000.00 - 300.00 + 500.00 = 1,200.00 50.00
Período de Facturación Del 1 de Enero al 31 de Enero de 2021
Fecha límite de pago: 15 de Febrero de 2021
Nuevos Cargos incluyen los siguientes conceptos:
Nuevas transacciones: 400.00
Interés Financiero: 20.00
Comisiones: 50.00
IVA: 30.00
Total Nuevos Cargos: 500.00
"""

DETAIL_2021 = """
Fecha y Detalle de las operaciones
14 de Enero PAGO RECIBIDO, GRACIAS 300.00
                                                                                         CR
5 de Enero MERCADO LOCAL 300.00
8 de Enero RESTAURANTE LOCAL 100.00
31 de Enero INTERÉS FINANCIERO 20.00
31 de Enero COMISIÓN DE SERVICIO 50.00
31 de Enero IVA DE COMISIÓN 30.00
"""

SUMMARY_2022 = """
       2,000.00 - 550.00 + 450.00 = 1,900.00 50.00
Período de Facturación Del 12 de Enero al 11 de Febrero de 2022
Fecha límite de pago: 4 de Marzo de 2022
Nuevos Cargos incluyen los siguientes conceptos:
Nuevas transacciones: 340.00
Interés Financiero: 20.00
IVA: 10.00
Comisiones: 80.00
Total Nuevos Cargos: 450.00
"""

DETAIL_2022 = """
Fecha y Detalle de las operaciones
20 de Enero PAGO RECIBIDO, GRACIAS 500.00
25 de Enero TIENDA LOCAL 200.00
1 de Febrero FARMACIA LOCAL 100.00
3 de Febrero MERCADO DEVOLUCIÓN 50.00
RFCXX000000 /REF123 CR
11 de Febrero MESES EN AUTOMÁTICO NACIONAL 40.00
31 de Enero CARGO POR PAGO TARDÍO 80.00
11 de Febrero INTERÉS FINANCIERO 20.00
11 de Febrero IVA DE COMISIÓN 10.00
"""

WRAP_2025 = """
       1,000.00 - 500.00 + 300.00 = 800.00 50.00
Período de Facturación Del 12 de Diciembre al 11 de Enero de 2025
Fecha límite de pago: 31 de Enero de 2025
Fecha y Detalle de las operaciones
14 de Diciembre SUPERMERCADO LOCAL 100.00
4 de Enero FARMACIA LOCAL 150.00
5 de Enero PAPELERÍA LOCAL 50.00
20 de Diciembre PAGO RECIBIDO 500.00 CR
"""


def test_synthetic_statement_summary_and_transaction_totals_reconcile():
    parsed = amex.parse_pdf(HEADER_2021 + DETAIL_2021)
    assert parsed.period_start == "2021-01-01"
    assert parsed.period_end == "2021-01-31"
    assert parsed.opening_balance == Decimal("1000.00")
    assert parsed.closing_balance == Decimal("1200.00")
    assert parsed.minimum_payment == Decimal("50.00")
    assert parsed.payment_due_date == "2021-02-15"
    assert parsed.interest == Decimal("20.00")
    assert parsed.fees == Decimal("50.00")
    assert parsed.iva == Decimal("30.00")
    assert parsed.summary_credit_total == Decimal("300.00")
    assert parsed.summary_charge_total == Decimal("500.00")
    assert sum((tx.amount for tx in parsed.transactions if tx.is_credit), Decimal(0)) == Decimal("300.00")
    assert sum((tx.amount for tx in parsed.transactions if not tx.is_credit), Decimal(0)) == Decimal("500.00")


def test_synthetic_credit_and_refund_continuation():
    parsed = amex.parse_pdf(SUMMARY_2022 + DETAIL_2022)
    assert len(parsed.transactions) == 8
    payment, store, pharmacy, refund, installment, fee, interest, iva = parsed.transactions
    assert payment.is_credit and payment.description.startswith("PAGO RECIBIDO")
    assert not store.is_credit and store.amount == Decimal("200.00")
    assert not pharmacy.is_credit
    assert refund.is_credit and refund.posted_date == "2022-02-03"
    assert installment.description.startswith("MESES EN AUTOMÁTICO")
    assert fee.amount == Decimal("80.00")
    assert interest.amount == Decimal("20.00")
    assert iva.amount == Decimal("10.00")


def test_synthetic_statement_crossing_year():
    parsed = amex.parse_pdf(WRAP_2025)
    assert parsed.period_start == "2024-12-12"
    assert parsed.period_end == "2025-01-11"
    assert parsed.payment_due_date == "2025-01-31"
    assert [tx.posted_date for tx in parsed.transactions] == [
        "2024-12-14", "2025-01-04", "2025-01-05", "2024-12-20"
    ]


def test_unrecognized_dated_row_blocks_statement():
    with pytest.raises(ValueError, match="unrecognized dated transaction row"):
        amex.parse_pdf(HEADER_2021 + DETAIL_2021 + "12 de Enero DESCRIPCIÓN SIN IMPORTE\n")


def test_transaction_totals_must_match_statement_summary():
    text = HEADER_2021 + DETAIL_2021.replace("MERCADO LOCAL 300.00", "MERCADO LOCAL 301.00")
    with pytest.raises(ValueError, match="do not reconcile"):
        amex.parse_pdf(text)


def test_statement_with_charges_but_no_detail_rows_is_rejected():
    with pytest.raises(ValueError, match="no transaction detail rows"):
        amex.parse_pdf(HEADER_2021)


def test_transaction_dates_must_fall_inside_billing_period():
    outside = HEADER_2021.replace("Del 1 de Enero", "Del 6 de Enero") + DETAIL_2021
    with pytest.raises(ValueError, match="outside the billing period"):
        amex.parse_pdf(outside)


def test_no_billing_period_is_an_error():
    with pytest.raises(ValueError, match="Período de Facturación"):
        amex.parse_pdf("synthetic text with no billing period")
