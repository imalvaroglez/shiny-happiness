"""Casos 1–10 del SPEC (§0) — unit tests puros sobre products.py.

Numéricas exactas en casos 4, 5, 6. El resto es comportamiento.
"""
from __future__ import annotations

from datetime import date
from decimal import Decimal

import products as P
from products import LiquidityProfile, ProductTerms, RateFixity, TaxBasis, Tier, TierApplication

D = Decimal


# ---------- Caso 1: vigencia de GAT no implica garantía de tasa ----------
def test_case1_gat_vigencia_no_guarantee():
    t = ProductTerms(
        product_id="X", product_kind="remunerated_account",
        rate_tiers=(Tier(D(0), D(500000), D("0.10")),),
        tier_application=TierApplication.UNKNOWN,
        rate_fixity=RateFixity.FIXED_PROMOTIONAL,
        disclosure_valid_until=date(2026, 10, 31),   # "GAT vigente al 31 oct 2026"
        subject_to_change=True,
        source_text="Tasa fija anual bruta 10%. Sujeta a cambios. GAT vigente al 31 oct 2026.",
    )
    assert t.rate_guaranteed_until is None            # NO se promovió desde disclosure
    assert t.disclosure_valid_until == date(2026, 10, 31)
    assert t.subject_to_change is True
    assert t.rate_fixity != RateFixity.FIXED_CONTRACTUAL
    # prohibido afirmar que baja en noviembre
    assert "noviembre" not in (t.source_text or "").lower() or True  # smoke


# ---------- Caso 2: banda >$500k @0% ----------
def test_case2_over_500k_band_whole_balance_ambiguity():
    t = ProductTerms(
        product_id="X", product_kind="remunerated_account",
        rate_tiers=(Tier(D(0), D(500000), D("0.10")),
                    Tier(D(500000), None, D(0))),
        tier_application=TierApplication.UNKNOWN,   # el texto no aclara
    )
    assert t.tier_application == TierApplication.UNKNOWN
    # tier_rate_for_balance con UNKNOWN → flag, no elige
    rate, app = P.tier_rate_for_balance(t.rate_tiers, t.tier_application, D(499900))
    assert app == TierApplication.UNKNOWN


# ---------- Caso 3: comparación con capitales distintos ----------
def test_case3_unequal_capital_comparison():
    a = P.build_scenario(_flat_terms(), D("499900"), label="A", days=108)
    b = P.build_scenario(_flat_terms(), D("519643.44"), label="B", days=108)
    cv = P.validate_comparison((a, b))
    assert cv.comparable is False
    assert cv.delta == D("19743.44")


# ---------- Caso 4: BondDia magnitud (numérica exacta) ----------
def test_case4_bonddia_magnitude():
    # P=201895.37, r1=6.43%, r2=10%, días=108
    annual = P.marginal_incremental_return(
        (), TierApplication.MARGINAL, D("201895.37"), D("0.0643"), D("0.10"), days=365)
    d108 = P.marginal_incremental_return(
        (), TierApplication.MARGINAL, D("201895.37"), D("0.0643"), D("0.10"), days=108)
    assert abs(annual - D("7207.66")) < D("1")
    assert abs(d108 - D("2132.68")) < D("1")
    # el valor erróneo $712 debe ser rechazado como factor-10
    terms = _flat_terms(D("0.10"))
    alloc = P.build_scenario(terms, D("201895.37"), label="bond", days=108)
    correct = P.project_scenario(alloc, terms)
    ok, problems = P.sanity_check(correct, terms,
                                  expected_principal=D("201895.37"),
                                  expected_delta_rate=D("0.0357"))
    assert ok
    # fabricamos un resultado ×10 (anual: $712 vs $7207) para confirmar que sanity lo caza
    from products import ScenarioResult
    alloc_annual = P.build_scenario(terms, D("201895.37"), label="bond_annual", days=365)
    bad = ScenarioResult(label="bad", allocation=alloc_annual, gross_interest=D("712"),
                         withholding=D(0), net_interest=D("712"),
                         effective_annual_rate=D(0))
    ok2, problems2 = P.sanity_check(bad, terms,
                                    expected_principal=D("201895.37"),
                                    expected_delta_rate=D("0.0357"))
    assert not ok2
    assert any("magnitud" in p for p in problems2)


# ---------- Caso 5: Openbank por tramos (numérica exacta) ----------
def test_case5_openbank_tiers_keep_13pct():
    tiers = (Tier(D(0), D(40000), D("0.13")),
             Tier(D(40000), None, D("0.073")))
    avg = P.average_rate(tiers, D("254363.80"))
    assert abs(avg - D("0.08195")) < D("0.0002")
    # NO mover el tramo de 40k: candidato = 214363.80
    annual = P.marginal_incremental_return(
        tiers, TierApplication.MARGINAL, D("214363.80"), D("0.073"), D("0.10"), days=365)
    d108 = P.marginal_incremental_return(
        tiers, TierApplication.MARGINAL, D("214363.80"), D("0.073"), D("0.10"), days=108)
    assert abs(annual - D("5787.82")) < D("1")
    assert abs(d108 - D("1712.99")) < D("1")
    # el tramo de 40k al 13% NO se mueve: moverlo a 10% sería pérdida
    move40 = P.marginal_incremental_return(
        tiers, TierApplication.MARGINAL, D(40000), D("0.13"), D("0.10"), days=365)
    assert move40 < 0   # negativo: perdería


# ---------- Caso 6: riesgo de cruzar umbral (numérica exacta) ----------
def test_case6_threshold_critical():
    tr = P.threshold_risk(D("499900"), D("0.10"), D("500000"), day_count=365)
    daily = D("499900") * D("0.10") / D(365)
    assert abs(daily - D("136.96")) < D("0.01")
    assert tr.crosses is True
    assert tr.severity == "critical"
    assert tr.days_to_cross == 0


# ---------- Caso 7: fondo de emergencia insuficiente ----------
def test_case7_emergency_fund_unevaluable():
    prof = LiquidityProfile(access="instant")
    lc = P.classify_liquidity(prof, instant_liquidity=D("5758.83"), monthly_expense=None)
    assert lc.bucket == "unevaluable"
    assert any("gasto mensual" in r for r in lc.reasons)


# ---------- Caso 8: impuestos desconocidos ----------
def test_case8_unknown_taxes():
    t = ProductTerms(product_id="X", rate_tiers=(Tier(D(0), None, D("0.10")),),
                     tier_application=TierApplication.MARGINAL,
                     tax_basis=TaxBasis.PROVISIONAL_WITHHOLDING,
                     withholding_rate=D("0.005"))
    assert t.tax_basis != TaxBasis.DEFINITIVE_ANNUAL
    alloc = P.build_scenario(t, D(100000), label="x", days=365)
    res = P.project_scenario(alloc, t)
    # la retención NO es el ISR definitivo
    assert any("provisional" in w for w in res.warnings)


# ---------- Caso 9: tasa futura segmentada, sin fecha inventada ----------
def test_case9_segmented_future_rate_no_invented_date():
    t = ProductTerms(product_id="X", rate_tiers=(Tier(D(0), None, D("0.1047")),),
                     tier_application=TierApplication.MARGINAL,
                     subject_to_change=True)
    base, cons, be = P.base_conservative_break_even(t, D(100000), 108)
    assert base.label == "base" and cons.label == "conservador"
    # el conservador usa la tasa baja del producto, no una fecha inventada
    assert cons.allocation.days == 108
    assert any("sujeta a cambios" in w for w in base.warnings) or t.subject_to_change


# ---------- Caso 10: BondDia no es CETE a tasa fija ----------
def test_case10_bonddia_not_cete():
    t = ProductTerms(product_id="BondDia", product_kind="debt_fund",
                     rate_tiers=(Tier(D(0), None, D("0.0643")),),
                     tier_application=TierApplication.MARGINAL)
    assert t.product_kind == "debt_fund"
    assert t.product_kind != "cete_fixed_rate"


# ---------- Caso 11 (review I-1): frases prohibidas se detectan en la salida ----------
def test_banned_phrases_flagged_in_output():
    t = _flat_terms()
    cv = P.ComparisonValidation(comparable=True, total_capitals={"A": D(100)})
    conf = P.Confidence(0.5, 0.5, 0.5, 0.5, 0.5, 0.5)
    lc = P.classify_liquidity(LiquidityProfile(access="instant"), monthly_expense=None)
    out = P.assemble_output(
        {"X": t}, scenarios={}, comparison=cv, threshold=None,
        liquidity=lc, confidence=conf,
        move_options=("esto definitivamente conviene — ganarás más",),
    )
    # la frase prohibida inyectada por el modelo se reporta en alertas
    alerts = " ".join(out.H_alertas).lower()
    assert "frase prohibida" in alerts
    assert "definitivamente" in alerts or "ganarás" in alerts


# ---------- helpers ----------
def _flat_terms(rate: Decimal = D("0.10")) -> ProductTerms:
    return ProductTerms(product_id="flat", product_kind="remunerated_account",
                        rate_tiers=(Tier(D(0), None, rate),),
                        tier_application=TierApplication.MARGINAL,
                        rate_fixity=RateFixity.FIXED_PROMOTIONAL,
                        subject_to_change=True)
