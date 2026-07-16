"""Integration test (SPEC §19) — caso completo Openbank/BondDia/Mifel.

Verifica que assemble_output detecta los errores originales, recomputa, separa
hechos/supuestos, preserva el tramo 13%, alerta el umbral $500k, no asume
futuro de tasas, y emite recomendación condicional.
"""
from __future__ import annotations

from datetime import date
from decimal import Decimal

import products as P
from products import (
    ComparisonValidation,
    Confidence,
    LiquidityClassification,
    LiquidityProfile,
    ProductTerms,
    RateFixity,
    TaxBasis,
    Tier,
    TierApplication,
)

D = Decimal


def _mifel_terms() -> ProductTerms:
    return ProductTerms(
        product_id="Mifel", product_kind="remunerated_account",
        rate_tiers=(Tier(D(0), D(100), D(0)),
                    Tier(D(100), D(500000), D("0.10")),
                    Tier(D(500000), None, D(0))),
        tier_application=TierApplication.UNKNOWN,   # el folleto no aclara
        rate_fixity=RateFixity.FIXED_PROMOTIONAL,
        disclosure_valid_until=date(2026, 10, 31),
        subject_to_change=True,
        tax_basis=TaxBasis.UNKNOWN,
        source_text="10% fija anual bruta. Sujeta a cambios. GAT vigente al 31 oct 2026.",
    )


def _openbank_terms() -> ProductTerms:
    return ProductTerms(
        product_id="Openbank", product_kind="remunerated_account",
        rate_tiers=(Tier(D(0), D(40000), D("0.13")),
                    Tier(D(40000), D(1000000), D("0.073")),
                    Tier(D(1000000), None, D("0.07"))),
        tier_application=TierApplication.MARGINAL,
        rate_fixity=RateFixity.FIXED_PROMOTIONAL, subject_to_change=True,
    )


def _bonddia_terms() -> ProductTerms:
    return ProductTerms(
        product_id="BondDia", product_kind="debt_fund",   # NO cete
        rate_tiers=(Tier(D(0), None, D("0.0643")),),
        tier_application=TierApplication.MARGINAL,
        tax_basis=TaxBasis.PROVISIONAL_WITHHOLDING,
    )


def test_full_case_detects_errors_and_conditions():
    mifel = _mifel_terms()
    ob = _openbank_terms()
    bd = _bonddia_terms()

    # tramo Openbank 7.3% (214363.80) candidato a Mifel 10% — 108 días
    ob_annual = P.marginal_incremental_return(
        ob.rate_tiers, TierApplication.MARGINAL, D("214363.80"),
        D("0.073"), D("0.10"), days=365)
    assert abs(ob_annual - D("5787.82")) < D("1")
    # tramo 40k al 13% NO se mueve
    move40 = P.marginal_incremental_return(
        ob.rate_tiers, TierApplication.MARGINAL, D(40000),
        D("0.13"), D("0.10"), days=365)
    assert move40 < 0

    # BondDia: mayor delta de tasa → candidato principal
    bd_annual = P.marginal_incremental_return(
        bd.rate_tiers, TierApplication.MARGINAL, D("201895.37"),
        D("0.0643"), D("0.10"), days=365)
    assert bd_annual > ob_annual   # BondDia da más incremental absoluto

    # riesgo de umbral: $499,900 @10% cruza $500k
    tr = P.threshold_risk(D("499900"), D("0.10"), D("500000"))
    assert tr.severity == "critical"

    # comparación de capitales distintos RECHAZADA
    alloc_a = P.build_scenario(_flat(D("0.10")), D("499900"), label="A", days=108)
    alloc_b = P.build_scenario(_flat(D("0.10")), D("519643.44"), label="B", days=108)
    cv = P.validate_comparison((alloc_a, alloc_b))
    assert not cv.comparable

    # liquidez: sin gasto mensual → unevaluable
    lc = P.classify_liquidity(LiquidityProfile(access="instant"),
                              instant_liquidity=D("5758.83"), monthly_expense=None)
    assert lc.bucket == "unevaluable"

    # ensamblaje A-H
    conf = P.score_confidence(mifel, cv, tr, lc)
    out = P.assemble_output(
        {"Mifel": mifel, "Openbank": ob, "BondDia": bd},
        scenarios={"Mifel": (P.project_scenario(alloc_a, _flat(D("0.10"))),)},
        comparison=cv, threshold=tr, liquidity=lc, confidence=conf,
        move_options=("BondDia: mayor delta de tasa (6.43%→10%)",
                      "Openbank: mover solo el tramo 7.3%, preservar 13%"),
        audit=True,
    )
    # A–H poblados
    assert out.A_datos_confirmados and out.B_no_confirmados
    assert out.C_validaciones and out.H_alertas
    # NO contiene afirmaciones de garantía temporal
    alltext = " ".join(out.A_datos_confirmados + out.B_no_confirmados +
                       out.G_recomendacion + out.H_alertas + out.audit).lower()
    assert "vence" not in alltext
    assert "bajará a 0%" not in alltext
    assert "garantizado" not in alltext
    # sí alerta umbral y liquidez
    assert any("500000" in h or "umbral" in h.lower() for h in out.H_alertas) or any(
        "umbral" in g.lower() for g in out.G_recomendacion)
    assert any("no garantizada" in h.lower() for h in out.H_alertas)
    # recomendación condicional
    assert any("condicional" in g.lower() for g in out.G_recomendacion)
    # auditoría presente
    assert out.audit and "AUDITORÍA" in out.audit[0]


def _flat(rate: Decimal) -> ProductTerms:
    return ProductTerms(product_id="flat", rate_tiers=(Tier(D(0), None, rate),),
                        tier_application=TierApplication.MARGINAL,
                        rate_fixity=RateFixity.FIXED_PROMOTIONAL,
                        subject_to_change=True)


_ = (ComparisonValidation, Confidence, LiquidityClassification)  # evita unused-import
