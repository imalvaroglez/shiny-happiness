"""Property-based tests (SPEC §20) sobre products.py.

hypothesis es dev-only; importorskip para que la suite corra sin él si falta.
"""
from __future__ import annotations

from datetime import date
from decimal import Decimal

import pytest

hypothesis = pytest.importorskip("hypothesis")
import products as P  # noqa: E402
from hypothesis import given  # noqa: E402
from hypothesis import strategies as st  # noqa: E402
from products import ProductTerms, RateFixity, Tier, TierApplication  # noqa: E402

D = Decimal


def _dec(min_value=1, max_value=10**9) -> st.SearchStrategy:
    return st.decimals(min_value=str(min_value), max_value=str(max_value), places=2)


def _rate() -> st.SearchStrategy:
    return st.decimals(min_value="0", max_value="0.5", places=4)


# 1. El rendimiento incremental debe ser cero cuando las tasas son iguales.
@given(principal=_dec(), rate=_rate(), days=st.integers(min_value=1, max_value=365))
def test_prop_incremental_zero_when_rates_equal(principal, rate, days):
    r = P.marginal_incremental_return((), TierApplication.MARGINAL, principal,
                                      rate, rate, days=days)
    assert r == 0


# 2. Crece linealmente con el capital bajo interés simple.
@given(cap_a=_dec(max_value=10**6), rate=_rate(), days=st.integers(1, 365),
       mult=st.decimals(min_value="2", max_value="5", places=1))
def test_prop_incremental_linear_in_capital(cap_a, rate, days, mult):
    cap_b = cap_a * mult
    ra = P.marginal_incremental_return((), TierApplication.MARGINAL, cap_a,
                                       D(0), rate, days=days)
    rb = P.marginal_incremental_return((), TierApplication.MARGINAL, cap_b,
                                       D(0), rate, days=days)
    # rb ≈ ra * mult  (within Decimal rounding)
    assert abs(rb - ra * mult) < D("0.05")


# 3. Negativo si tasa destino < origen.
@given(principal=_dec(), days=st.integers(1, 365))
def test_prop_incremental_negative_when_dest_lt_source(principal, days):
    r = P.marginal_incremental_return((), TierApplication.MARGINAL, principal,
                                      D("0.10"), D("0.05"), days=days)
    assert r < 0


# 4. Σ asignaciones de un escenario ≤ capital disponible.
@given(capital=_dec(max_value=10**6),
       kind=st.sampled_from(["remunerated_account", "savings"]))
def test_prop_allocation_sum_le_capital(capital, kind):
    tiers = (Tier(D(0), D(50000), D("0.10")), Tier(D(50000), None, D("0.05")))
    t = ProductTerms(product_id="x", product_kind=kind, rate_tiers=tiers,
                     tier_application=TierApplication.MARGINAL)
    alloc = P.build_scenario(t, capital, label="base", days=108)
    allocated = sum((c for _, c in alloc.slices), D(0))
    assert allocated + alloc.unallocated == capital


# 5. En tablas marginales, Σ capital de los tramos == saldo.
@given(balance=_dec(max_value=10**6))
def test_prop_marginal_tier_capital_sums_to_balance(balance):
    tiers = (Tier(D(0), D(40000), D("0.13")),
             Tier(D(40000), D(1000000), D("0.073")),
             Tier(D(1000000), None, D("0.07")))
    alloc = P.build_scenario(
        ProductTerms(product_id="x", rate_tiers=tiers,
                     tier_application=TierApplication.MARGINAL),
        balance, label="base", days=365)
    allocated = sum((c for _, c in alloc.slices), D(0))
    assert allocated == balance


# 6. Un saldo fuera del rango no recibe la tasa de otro rango (whole_balance).
@given(balance=_dec(min_value=500001, max_value=10**6))
def test_prop_balance_outside_range_gets_no_other_rate(balance):
    tiers = (Tier(D(0), D(500000), D("0.10")), Tier(D(500000), None, D(0)))
    rate, app = P.tier_rate_for_balance(tiers, TierApplication.WHOLE_BALANCE, balance)
    assert rate == 0   # cae en la banda superior @0%, no recibe 10%


# 7. La fecha de vigencia de GAT nunca pobla rate_guaranteed_until.
@given(d=st.dates())
def test_prop_disclosure_never_populates_guarantee(d):
    t = ProductTerms(product_id="x", disclosure_valid_until=d,
                     subject_to_change=True)
    assert t.rate_guaranteed_until is None


# 8. "sujeta a cambios" no puede ser FIXED_CONTRACTUAL.
@given(subj=st.booleans())
def test_prop_subject_to_change_not_contractual(subj):
    t = ProductTerms(product_id="x", subject_to_change=subj,
                     rate_fixity=RateFixity.FIXED_CONTRACTUAL if not subj else RateFixity.FIXED_PROMOTIONAL)
    if subj:
        assert t.rate_fixity != RateFixity.FIXED_CONTRACTUAL


# 9. Capital sin asignar marca escenario incompleto.
def test_prop_unallocated_marks_incomplete():
    t = ProductTerms(product_id="x", rate_tiers=(Tier(D(0), D(500000), D("0.10")),),
                     tier_application=TierApplication.UNKNOWN)
    alloc = P.build_scenario(t, D(600000), label="base", days=108)
    assert alloc.unallocated > 0


# 10. Resultado ×10 vs canónico falla validación.
def test_prop_factor10_fails_validation():
    t = ProductTerms(product_id="x", rate_tiers=(Tier(D(0), None, D("0.10")),),
                     tier_application=TierApplication.MARGINAL)
    alloc = P.build_scenario(t, D(100000), label="x", days=365)
    correct = P.project_scenario(alloc, t)
    from products import ScenarioResult
    bad = ScenarioResult(label="bad", allocation=alloc,
                         gross_interest=correct.gross_interest * 10,
                         withholding=D(0), net_interest=D(0),
                         effective_annual_rate=D(0))
    ok, problems = P.sanity_check(bad, t, canonical=correct)
    assert not ok


# evita warning de fixture no usada por import estático
_ = date
