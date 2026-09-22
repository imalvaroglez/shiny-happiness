"""Fixtures = snippets recortados de los PDFs reales (pdftotext -layout),
201902.pdf y 202502.pdf, + caso sintético de wrap Dic→Ene."""

from decimal import Decimal

import amex

# --- Recortes reales de 201902.pdf -----------------------------------------
HEADER_2019 = """
  Saldo Anterior   Créditos      Cargos generar intereses          Mínimo
       6,264.76 - 6,339.07 +   5,301.72 =        5,227.41          362.50

Pago mínimo más mensualidades sin intereses: $1,956.13
Fecha límite de pago: 4 de Marzo

Período de Facturación Del 12 de Enero al 11 de Febrero de 2019   Días del periodo: 31 días

Nuevos Cargos incluyen los siguientes conceptos:
Nuevas transacciones:                       4,550.88
Interés Financiero:                              0.00
Comisiones:                                      0.00

 Total Nuevos Cargos:                               5,301.72

Pago Mínimo: $ 362.50
Fecha límite de pago: 04 de Marzo 2019
"""

DETAIL_2019 = """
Fecha y Detalle de las operaciones                                            Importe en MN.
23 de Enero    PAGO RECIBIDO, GRACIAS                                               6,264.76
                                                                                         CR
11 de Enero    CINEPOLIS0485 000000000 DF                                              44.00
               RFCCME981208VE4 /REF04850100207214
11 de Enero    ITUNES.COM/BILL     CUPERTINO                                           9.00
"""

# --- Recortes reales de 202502.pdf -----------------------------------------
CHARGES_2025 = """
Nuevos Cargos incluyen los siguientes conceptos:
Nuevas transacciones:                       4,810.02
Interés Financiero:                           288.70
IVA:                                          142.20
Comisiones:                                   600.00

 Total Nuevos Cargos:                               6,879.92
"""

DETAIL_2025 = """
Fecha y Detalle de las operaciones                                                                    Importe en MN.
1 de Febrero   PAGO RECIBIDO, GRACIAS                                                                        7,126.20
                                                                                                                  CR
14 de Enero     CAFE SIRENA SOCIEDAD DE MEXICO CITY                                                            267.00
                RFCCSI020226MV4 /REFP3LDW24PH5XDFVF3
1 de Febrero WALMART CASHI VENTA EN CIUDAD DE MEXIC                                                            998.02
                RFCNWM9709244W4 /REF91750101
3 de Febrero AMAZON MX*AMAZON RETAIL MEXICO CITY                                                                49.50
                RFCANE140618P37 /REF11qpsZKBU3D3t4XaJb9r                                                            CR
11 de Febrero MESES EN AUTOMÁTICO NACIONAL                                                                   1,039.00
                CARGO 03 DE 03
31 de Enero     CARGO POR PAGO TARDÍO                                                                         600.00
11 de Febrero INTERÉS FINANCIERO                                                     288.70
"""

PERIOD_2025 = """
Período de Facturación Del 12 de Enero al 11 de Febrero de 2025   Días del periodo: 31 días
Fecha límite de pago: 03 de Marzo 2025
"""

# --- Wrap Dic→Ene (estructura real de 202501.pdf, montos reales) -----------
WRAP_2025 = """
       4,643.20 - 7,175.70 +   6,879.92 =        4,347.42        3,600.00
Período de Facturación Del 12 de Diciembre al 11 de Enero de 2025   Días del periodo: 31 días
Fecha límite de pago: 31 de Enero 2025
Fecha y Detalle de las operaciones                                                                            Importe en MN.
4 de Diciembre  WALMART CASHI VENTA EN CIUDAD DE MEXIC                                                        417.51
4 de Enero      WALMART CASHI VENTA EN CIUDAD DE MEXIC                                                             91.62
5 de Enero      AMERICA MOVIL MI TELCEL DF                                                                         15.00
"""


def test_resumen_2019():
    parsed = amex.parse_pdf(HEADER_2019 + DETAIL_2019)
    assert parsed.period_start == "2019-01-12"
    assert parsed.period_end == "2019-02-11"
    assert parsed.opening_balance == Decimal("6264.76")
    assert parsed.closing_balance == Decimal("5227.41")
    assert parsed.minimum_payment == Decimal("362.50")
    assert parsed.payment_due_date == "2019-03-04"
    assert parsed.interest == Decimal("0.00")
    assert parsed.fees == Decimal("0.00")
    assert parsed.iva is None  # 2019 no traía IVA en el bloque


def test_transacciones_2019():
    txs = amex.parse_pdf(HEADER_2019 + DETAIL_2019).transactions
    assert len(txs) == 3
    pago, cinepolis, itunes = txs
    assert pago.posted_date == "2019-01-23"
    assert pago.amount == Decimal("6264.76")
    assert pago.is_credit  # CR en línea de continuación
    assert "PAGO RECIBIDO" in pago.description
    assert cinepolis.posted_date == "2019-01-11"
    assert not cinepolis.is_credit  # continuación RFC sin CR
    assert cinepolis.amount == Decimal("44.00")
    assert itunes.posted_date == "2019-01-11"
    assert itunes.amount == Decimal("9.00")


def test_cr_al_final_de_linea_rfc_2025():
    txs = amex.parse_pdf(PERIOD_2025 + CHARGES_2025 + DETAIL_2025).transactions
    assert len(txs) == 7
    pago, sirena, walmart, amazon, msi, tardio, interes = txs
    assert pago.is_credit and pago.amount == Decimal("7126.20")
    assert not sirena.is_credit
    assert not walmart.is_credit and walmart.posted_date == "2025-02-01"
    assert amazon.is_credit  # CR al final de la línea RFC de continuación
    assert amazon.posted_date == "2025-02-03"
    assert msi.amount == Decimal("1039.00") and not msi.is_credit
    assert tardio.amount == Decimal("600.00")
    assert interes.amount == Decimal("288.70") and interes.posted_date == "2025-02-11"


def test_charges_meta_2025():
    parsed = amex.parse_pdf(PERIOD_2025 + CHARGES_2025 + DETAIL_2025)
    assert parsed.interest == Decimal("288.70")
    assert parsed.fees == Decimal("600.00")
    assert parsed.iva == Decimal("142.20")


def test_wrap_dic_a_enero():
    parsed = amex.parse_pdf(WRAP_2025)
    assert parsed.period_start == "2024-12-12"
    assert parsed.period_end == "2025-01-11"
    assert parsed.payment_due_date == "2025-01-31"
    fechas = [t.posted_date for t in parsed.transactions]
    assert fechas == ["2024-12-04", "2025-01-04", "2025-01-05"]


def test_sin_periodo_es_error():
    import pytest
    with pytest.raises(ValueError):
        amex.parse_pdf("texto sin periodo ni nada reconocible")
