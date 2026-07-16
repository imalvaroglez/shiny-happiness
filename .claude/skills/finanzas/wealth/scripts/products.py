"""Análisis de productos de ahorro / remuneradas / liquidez / corto plazo.

Funciones PURAS sobre dataclasses: ninguna lee `.ftbackup` ni hace I/O. El modelo
llena `ProductTerms` a partir del texto fuente; estas funciones hacen TODA la
matemática y validación. Esto las hace testeables sin fixtures.

Spec normativo: `../SPEC.md`. Referencia canónica del saldo reconstruido:
`balance.py` (puerto de AccountBalanceResolver.swift).

Invariante: tasas como FRACCIÓN (0.13 = 13%), dinero siempre Decimal, runtime
stdlib-only (pytest/hypothesis son dev-only, nunca se importan aquí).
"""
from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import date
from decimal import Decimal
from enum import StrEnum


# --------------------------------------------------------------------------- #
# Enums
# --------------------------------------------------------------------------- #
class TierApplication(StrEnum):
    MARGINAL = "marginal"            # cada tasa aplica a la porción del saldo en su banda
    WHOLE_BALANCE = "whole_balance"  # una tasa al saldo completo según el rango del total
    UNKNOWN = "unknown"              # ambiguo → flaggear, nunca elegir en silencio


class RateNature(StrEnum):
    NOMINAL_ANNUAL = "nominal_annual"
    EFFECTIVE_ANNUAL = "effective_annual"
    GROSS_PERIOD = "gross_period"
    UNKNOWN = "unknown"


class RateFixity(StrEnum):
    FIXED_CONTRACTUAL = "fixed_contractual"
    FIXED_PROMOTIONAL = "fixed_promotional"   # fija ahora, "sujeta a cambios"
    VARIABLE = "variable"
    UNKNOWN = "unknown"


class TaxBasis(StrEnum):
    GROSS = "gross"
    PROVISIONAL_WITHHOLDING = "provisional_withholding"  # retención 0.5% etc.
    DEFINITIVE_ANNUAL = "definitive_annual"              # ISR anual — nunca asumir
    UNKNOWN = "unknown"


class Certainty(StrEnum):
    HECHO = "hecho"
    DERIVADO = "derivado"
    INFERIDO = "inferido"
    SUPUESTO = "supuesto"
    NO_CONFIRMADO = "no_confirmado"


# --------------------------------------------------------------------------- #
# Dataclasses
# --------------------------------------------------------------------------- #
@dataclass(frozen=True)
class Tier:
    lower: Decimal                      # inclusive
    upper: Decimal | None = None     # None = tope abierto
    rate_annual: Decimal = Decimal(0)   # fracción (0.13)
    rate_nature: RateNature = RateNature.NOMINAL_ANNUAL
    note: str = ""


@dataclass(frozen=True)
class LiquidityProfile:
    access: str = "unknown"             # instant|same_day|t+1|t+2|term|unknown
    weekend_access: bool = False
    settlement_days: int = 0
    penalty: Decimal | None = None
    penalty_note: str = ""
    withdrawal_limit: Decimal | None = None
    operational_notes: str = ""


@dataclass(frozen=True)
class ProductTerms:
    """Términos extraídos de UN producto. Lo llena el modelo desde el texto."""
    product_id: str
    product_kind: str = "unknown"        # remunerated_account|savings|liquidity_fund|...
    rate_tiers: tuple[Tier, ...] = ()
    tier_application: TierApplication = TierApplication.UNKNOWN
    rate_fixity: RateFixity = RateFixity.UNKNOWN
    rate_guaranteed_until: date | None = None   # garantía contractual; None = desconocido
    disclosure_valid_until: date | None = None  # "GAT vigente al" — NUNCA auto-promovido
    subject_to_change: bool = False
    rate_nature: RateNature = RateNature.UNKNOWN
    tax_basis: TaxBasis = TaxBasis.UNKNOWN
    withholding_rate: Decimal | None = None     # fracción (0.005), solo provisional
    day_count_basis: int = 365
    currency: str = "MXN"
    liquidity: LiquidityProfile | None = None
    source_text: str = ""
    extraction_notes: tuple[str, ...] = ()


@dataclass(frozen=True)
class ScenarioAllocation:
    """Dónde está el capital en un escenario. Σ slices + unallocated == total_capital."""
    label: str
    total_capital: Decimal
    slices: tuple[tuple[Tier, Decimal], ...] = ()  # (tier, capital en esa banda)
    unallocated: Decimal = Decimal(0)              # > 0 → escenario incompleto
    days: int | None = None
    assumptions: tuple[str, ...] = ()


@dataclass(frozen=True)
class ScenarioResult:
    label: str
    allocation: ScenarioAllocation
    gross_interest: Decimal
    withholding: Decimal
    net_interest: Decimal
    effective_annual_rate: Decimal
    formula_trace: tuple[str, ...] = ()
    warnings: tuple[str, ...] = ()


@dataclass(frozen=True)
class ComparisonValidation:
    comparable: bool
    total_capitals: dict[str, Decimal]
    delta: Decimal | None = None
    omitted_capital: Decimal | None = None
    double_counted: Decimal | None = None
    unaligned_horizons: bool = False
    reasons: tuple[str, ...] = ()


@dataclass(frozen=True)
class ThresholdRisk:
    limit: Decimal
    applies_to: str
    projected_balance: Decimal
    crosses: bool
    days_to_cross: int | None = None
    safety_margin: Decimal = Decimal(0)
    severity: str = "none"   # none|warn|critical


@dataclass(frozen=True)
class Confidence:
    rate_extraction: float
    tier_interpretation: float
    horizon: float
    liquidity: float
    tax: float
    recommendation: float

    @property
    def overall(self) -> float:
        return min(self.rate_extraction, self.tier_interpretation, self.horizon,
                   self.liquidity, self.tax, self.recommendation)


@dataclass(frozen=True)
class LiquidityClassification:
    bucket: str   # operational_liquidity|emergency_fund|tactical|optimizable|term_committed|unevaluable
    reasons: tuple[str, ...] = ()
    monthly_expense_known: bool = False
    runway_months: Decimal | None = None


@dataclass(frozen=True)
class ProductAnalysisOutput:
    A_datos_confirmados: tuple[str, ...] = ()
    B_no_confirmados: tuple[str, ...] = ()
    C_validaciones: tuple[str, ...] = ()
    D_rendimiento_actual: tuple[str, ...] = ()
    E_opciones: tuple[str, ...] = ()
    F_escenarios: tuple[str, ...] = ()
    G_recomendacion: tuple[str, ...] = ()
    H_alertas: tuple[str, ...] = ()
    confidence: Confidence | None = None
    audit: tuple[str, ...] = ()


# --------------------------------------------------------------------------- #
# Prohibiciones de lenguaje (R4 del SPEC, §4)
# --------------------------------------------------------------------------- #
BANNED_PHRASES: tuple[str, ...] = (
    "definitivamente", "garantizado", "vence", "bajará", "quedará fija",
    "queda fija", "conviene", "no conviene", "ganarás", "ganaras",
    "neto después de impuestos", "neto despues de impuestos",
)


def flag_banned(text: str) -> tuple[str, ...]:
    """Devuelve las frases prohibidas presentes en text (case-insensitive)."""
    low = text.lower()
    found = tuple(p for p in BANNED_PHRASES if p in low)
    return found


# --------------------------------------------------------------------------- #
# Tramos — interpretación
# --------------------------------------------------------------------------- #
def interpret_tiers(
    raw_bands: tuple[tuple[Decimal | None, Decimal | None, Decimal], ...],
    source_text: str = "",
    *,
    tier_application_hint: TierApplication = TierApplication.UNKNOWN,
) -> tuple[tuple[Tier, ...], TierApplication]:
    """Construye la tupla de Tier. Si hay >1 banda y hint UNKNOWN → UNKNOWN.

    raw_bands: ((lower, upper, rate), ...). lower/upper None = abierto.
    """
    tiers = tuple(
        Tier(lower=(b[0] if b[0] is not None else Decimal(0)),
             upper=b[1], rate_annual=b[2])
        for b in raw_bands
    )
    app = tier_application_hint
    if len(tiers) > 1 and app == TierApplication.UNKNOWN:
        app = TierApplication.UNKNOWN  # sigue ambiguo: el caller debe modelar ambas
    return tiers, app


_WHOLE_BALANCE_HINTS = ("todo el saldo", "según el saldo total", "por saldo total",
                        "banda", "el saldo completo")
_MARGINAL_HINTS = ("a partir de", "por la porción", "excedente", "los primeros",
                   "tramos", "marginal")


def infer_tier_application(text: str) -> TierApplication:
    """Heurística SOLO sobre frases explícitas. Sin señal → UNKNOWN."""
    low = text.lower()
    if any(h in low for h in _WHOLE_BALANCE_HINTS):
        return TierApplication.WHOLE_BALANCE
    if any(h in low for h in _MARGINAL_HINTS):
        return TierApplication.MARGINAL
    return TierApplication.UNKNOWN


def _tier_for_balance(tiers: tuple[Tier, ...], balance: Decimal) -> Tier | None:
    """El Tier cuyo [lower, upper) contiene balance."""
    for t in tiers:
        upper = t.upper if t.upper is not None else Decimal("Infinity")
        if t.lower <= balance < upper:
            return t
    return None


def tier_rate_for_balance(
    tiers: tuple[Tier, ...], app: TierApplication, balance: Decimal,
) -> tuple[Decimal, TierApplication]:
    """Tasa que aplica a `balance`.
    WHOLE_BALANCE → la del rango donde cae el total.
    MARGINAL → blended (el caller decide si tiene sentido).
    UNKNOWN → (0, UNKNOWN) y flag.
    """
    if app == TierApplication.UNKNOWN:
        return Decimal(0), TierApplication.UNKNOWN
    if not tiers:
        return Decimal(0), app
    t = _tier_for_balance(tiers, balance)
    return (t.rate_annual if t else Decimal(0), app)


# --------------------------------------------------------------------------- #
# Marginal vs promedio (R5)
# --------------------------------------------------------------------------- #
def average_rate(tiers: tuple[Tier, ...], balance: Decimal) -> Decimal:
    """Tasa promedio efectiva sobre `balance` asumiendo MARGINAL.
    Expuesta SOLO como contraste de auditoría — NUNCA como base de decisión.
    """
    if balance <= 0 or not tiers:
        return Decimal(0)
    remaining = balance
    weighted = Decimal(0)
    for t in sorted(tiers, key=lambda x: x.lower):
        if remaining <= 0:
            break
        upper = t.upper if t.upper is not None else balance
        slice_cap = max(Decimal(0), min(remaining, upper - t.lower))
        if slice_cap > 0:
            weighted += slice_cap * t.rate_annual
            remaining -= slice_cap
    return weighted / balance


def marginal_incremental_return(
    tiers: tuple[Tier, ...],
    app: TierApplication,
    principal_slice: Decimal,
    source_rate: Decimal,
    dest_rate: Decimal,
    days: int = 365,
    day_count: int = 365,
) -> Decimal:
    """Rendimiento incremental de mover `principal_slice` de source_rate a dest_rate.

    El SPEC: calcular interés sobre el SLICE que se mueve, no la tasa promedio
    del saldo entero. `tiers`/`app` se aceptan para firma uniforme pero la decisión
    marginal ya está resuelta por el caller (que eligió el slice).

    days=365 → beneficio anual. days=108 → prorrateado a 365.
    """
    if app == TierApplication.UNKNOWN:
        raise ValueError(
            "tier_application UNKNOWN: no se puede promediar en silencio. "
            "Resuelve la ambigüedad (marginal vs saldo total) antes de calcular."
        )
    delta = dest_rate - source_rate
    if days <= 0:
        days = 1
    return (principal_slice * delta * Decimal(days)) / Decimal(day_count)


# --------------------------------------------------------------------------- #
# Escenarios
# --------------------------------------------------------------------------- #
def build_scenario(
    terms: ProductTerms,
    total_capital: Decimal,
    *,
    label: str,
    days: int | None = None,
    rate_override: Decimal | None = None,
) -> ScenarioAllocation:
    """Asigna total_capital entre tramos. MARGINAL → por banda; WHOLE_BALANCE →
    todo al tier donde cae; UNKNOWN → unallocated (incompleto)."""
    assumptions: list[str] = []
    if terms.subject_to_change:
        assumptions.append("tasa sujeta a cambios sin previo aviso (no garantizada)")
    if rate_override is not None:
        assumptions.append(f"se asume tasa {rate_override} (override de escenario)")

    app = terms.tier_application
    tiers = terms.rate_tiers

    if not tiers or (rate_override is not None and len(tiers) <= 1):
        rate = rate_override if rate_override is not None else (
            tiers[0].rate_annual if tiers else Decimal(0))
        flat = Tier(lower=Decimal(0), upper=None, rate_annual=rate)
        return ScenarioAllocation(label=label, total_capital=total_capital,
                                  slices=((flat, total_capital),), days=days,
                                  assumptions=tuple(assumptions))

    if app == TierApplication.UNKNOWN:
        return ScenarioAllocation(label=label, total_capital=total_capital,
                                  slices=(), unallocated=total_capital, days=days,
                                  assumptions=tuple(assumptions) + (
                                      "tier_application ambiguo: modelar marginal y saldo total",
                                  ))

    if app == TierApplication.WHOLE_BALANCE:
        t = _tier_for_balance(tiers, total_capital)
        if t is None:
            return ScenarioAllocation(label=label, total_capital=total_capital,
                                      slices=(), unallocated=total_capital, days=days,
                                      assumptions=tuple(assumptions))
        return ScenarioAllocation(label=label, total_capital=total_capital,
                                  slices=((t, total_capital),), days=days,
                                  assumptions=tuple(assumptions))

    # MARGINAL
    slices: list[tuple[Tier, Decimal]] = []
    remaining = total_capital
    for t in sorted(tiers, key=lambda x: x.lower):
        if remaining <= 0:
            break
        upper = t.upper if t.upper is not None else total_capital
        cap = max(Decimal(0), min(remaining, upper - t.lower))
        if cap > 0:
            slices.append((t, cap))
            remaining -= cap
    unalloc = max(Decimal(0), total_capital - sum((c for _, c in slices), Decimal(0)))
    return ScenarioAllocation(label=label, total_capital=total_capital,
                              slices=tuple(slices), unallocated=unalloc, days=days,
                              assumptions=tuple(assumptions))


def project_scenario(alloc: ScenarioAllocation, terms: ProductTerms) -> ScenarioResult:
    """Gross/withholding/net/effective. Decimal puro. Traza de fórmulas."""
    if alloc.unallocated > Decimal("0.01"):
        return ScenarioResult(
            label=alloc.label, allocation=alloc, gross_interest=Decimal(0),
            withholding=Decimal(0), net_interest=Decimal(0),
            effective_annual_rate=Decimal(0),
            warnings=("capital sin asignar: escenario incompleto",))

    days = alloc.days if alloc.days is not None else terms.day_count_basis
    dc = Decimal(terms.day_count_basis)
    gross = Decimal(0)
    trace: list[str] = []
    for tier, cap in alloc.slices:
        seg = cap * tier.rate_annual * Decimal(days) / dc
        gross += seg
        trace.append(f"{cap} × {tier.rate_annual} × {days}/{terms.day_count_basis} = {seg:.4f}")

    withholding = Decimal(0)
    if terms.withholding_rate is not None:
        withholding = gross * terms.withholding_rate
        trace.append(f"retención provisional = {gross} × {terms.withholding_rate} = {withholding:.4f}")

    net = gross - withholding
    eff = (gross / alloc.total_capital * (dc / Decimal(days))) if (alloc.total_capital > 0 and days > 0) else Decimal(0)

    warns: list[str] = []
    if terms.subject_to_change:
        warns.append("tasa futura no garantizada (sujeta a cambios)")
    if terms.tax_basis == TaxBasis.PROVISIONAL_WITHHOLDING:
        warns.append("withholding es retención provisional, NO impuesto definitivo")

    return ScenarioResult(label=alloc.label, allocation=alloc,
                          gross_interest=gross, withholding=withholding,
                          net_interest=net, effective_annual_rate=eff,
                          formula_trace=tuple(trace), warnings=tuple(warns))


def base_conservative_break_even(
    terms: ProductTerms, total_capital: Decimal, days: int,
    *, reference_rate: Decimal | None = None,
) -> tuple[ScenarioResult, ScenarioResult, ScenarioResult]:
    """base = tasa actual; conservador = tasa baja plausible (no inventa fecha);
    break_even = tasa que iguala reference_rate (o 0 si no hay referencia)."""
    base_alloc = build_scenario(terms, total_capital, label="base", days=days)
    base = project_scenario(base_alloc, terms)

    # conservador: override con la tasa más baja del producto (o 0 si variable)
    low = min((t.rate_annual for t in terms.rate_tiers), default=Decimal(0))
    cons_alloc = build_scenario(terms, total_capital, label="conservador", days=days,
                                rate_override=low)
    cons = project_scenario(cons_alloc, terms)
    cons = replace(cons, warnings=cons.warnings + (
        "escenario conservador: si la tasa cae, el resultado sería menor",))

    # break-even: tasa destino que iguala el rendimiento de reference_rate
    if reference_rate is not None:
        be_alloc = build_scenario(terms, total_capital, label="punto_equilibrio",
                                  days=days, rate_override=reference_rate)
    else:
        be_alloc = build_scenario(terms, total_capital, label="punto_equilibrio",
                                  days=days, rate_override=Decimal(0))
    be = project_scenario(be_alloc, terms)
    return base, cons, be


# --------------------------------------------------------------------------- #
# Comparabilidad (R6)
# --------------------------------------------------------------------------- #
def validate_comparison(
    scenarios: tuple[ScenarioAllocation, ...],
    reference_capital: Decimal | None = None,
) -> ComparisonValidation:
    capitals = {s.label: s.total_capital for s in scenarios}
    vals = list(capitals.values())
    if not vals:
        return ComparisonValidation(comparable=True, total_capitals=capitals,
                                    reasons=("sin escenarios",))
    lo, hi = min(vals), max(vals)
    delta = hi - lo
    comparable = delta <= Decimal("0.01")
    reasons: list[str] = []
    if not comparable:
        reasons.append(f"capitales no comparables: rango {lo}–{hi}, delta {delta}")
    # horizontes desalineados
    days_set = {s.days for s in scenarios if s.days is not None}
    if len(days_set) > 1:
        reasons.append(f"horizontes distintos: {sorted(days_set)}")
    # capital sin asignar
    omitted = sum((s.unallocated for s in scenarios), Decimal(0))
    if omitted > Decimal("0.01"):
        reasons.append(f"capital sin asignar entre escenarios: {omitted}")
    if reference_capital is not None:
        for lbl, cap in capitals.items():
            if abs(cap - reference_capital) > Decimal("0.01"):
                reasons.append(f"{lbl} ({cap}) difiere del capital de referencia {reference_capital}")
    unaligned = len(days_set) > 1
    return ComparisonValidation(
        comparable=comparable and not unaligned, total_capitals=capitals,
        delta=delta, omitted_capital=omitted if omitted > Decimal("0.01") else None,
        unaligned_horizons=unaligned, reasons=tuple(reasons))


# --------------------------------------------------------------------------- #
# Sanity / orden de magnitud (R7)
# --------------------------------------------------------------------------- #
def sanity_check(
    result: ScenarioResult, terms: ProductTerms,
    *, canonical: ScenarioResult | None = None,
    expected_principal: Decimal | None = None,
    expected_delta_rate: Decimal | None = None,
) -> tuple[bool, tuple[str, ...]]:
    """Valida magnitud. Devuelve (ok, problemas)."""
    problems: list[str] = []
    # ruta independiente: interés simple Σ cap×rate×days/dc
    dc = Decimal(terms.day_count_basis)
    days = result.allocation.days if result.allocation.days is not None else dc
    indep = Decimal(0)
    for tier, cap in result.allocation.slices:
        indep += cap * tier.rate_annual * Decimal(days) / dc
    if abs(indep - result.gross_interest) > Decimal("0.01"):
        problems.append(f"rutas independientes no cuadran: {indep:.4f} vs {result.gross_interest:.4f}")

    # spot check P × delta_rate
    if expected_principal is not None and expected_delta_rate is not None:
        spot = expected_principal * expected_delta_rate * Decimal(days) / dc
        if abs(spot) > Decimal("0.01") and result.gross_interest != 0:
            ratio = abs(result.gross_interest / spot)
            if ratio >= 9 or 0 < ratio <= 1 / 9:
                problems.append(
                    f"posible error de orden de magnitud: resultado {result.gross_interest:.2f} "
                    f"vs spot {spot:.2f} (ratio {ratio:.3f})")

    # factor-10 vs canónico
    if canonical is not None and canonical.gross_interest != 0:
        ratio = result.gross_interest / canonical.gross_interest
        if ratio != 0 and (abs(ratio) >= 9 or 0 < abs(ratio) <= 1 / 9):
            problems.append(
                f"factor-10/100 frente al canónico: {result.gross_interest:.2f} "
                f"vs {canonical.gross_interest:.2f} (ratio {ratio:.3f})")

    return (len(problems) == 0, tuple(problems))


# --------------------------------------------------------------------------- #
# Riesgo de umbral (R10)
# --------------------------------------------------------------------------- #
def threshold_risk(
    initial_balance: Decimal, rate_annual: Decimal, limit: Decimal,
    *, day_count: int = 365, interest_to_same_account: bool = True,
) -> ThresholdRisk:
    """Si los intereses se acumulan en la misma cuenta y hay una banda que pierde
    tasa al superar `limit`, calcula cuándo se cruza."""
    daily_interest = initial_balance * rate_annual / Decimal(day_count)
    headroom = limit - initial_balance

    # Ya por encima del límite (o justo en él)
    if headroom <= 0:
        return ThresholdRisk(limit=limit, applies_to="whole_balance",
                             projected_balance=initial_balance, crosses=True,
                             days_to_cross=0, safety_margin=headroom,
                             severity="critical")

    # Sin acumulación de intereses en la misma cuenta → no se cruza por esta vía
    if not interest_to_same_account or daily_interest <= 0:
        return ThresholdRisk(limit=limit, applies_to="whole_balance",
                             projected_balance=initial_balance, crosses=False,
                             days_to_cross=None, safety_margin=headroom,
                             severity="none")

    # Días completos que caben antes de cruzar (piso). Si daily >= headroom,
    # se cruza dentro del primer día → days_to_cross = 0, severity critical.
    days_to_cross = int(headroom // daily_interest)
    projected = initial_balance + daily_interest  # tras 1 día
    crosses = projected >= limit
    severity = "critical" if days_to_cross < 1 else ("warn" if days_to_cross <= 30 else "none")
    return ThresholdRisk(limit=limit, applies_to="whole_balance",
                         projected_balance=projected, crosses=crosses,
                         days_to_cross=max(0, days_to_cross),
                         safety_margin=headroom, severity=severity)


# --------------------------------------------------------------------------- #
# Liquidez (R11)
# --------------------------------------------------------------------------- #
def classify_liquidity(
    profile: LiquidityProfile | None,
    *,
    instant_liquidity: Decimal | None = None,
    monthly_expense: Decimal | None = None,
) -> LiquidityClassification:
    """Clasifica el rol de liquidez. monthly_expense desconocido + bucket
    emergency_fund → 'unevaluable' (nunca aprueba un mínimo arbitrario)."""
    reasons: list[str] = []
    access = profile.access if profile else "unknown"

    if access in ("instant", "same_day"):
        bucket = "operational_liquidity"
    elif access in ("t+1", "t+2"):
        bucket = "tactical"
    elif access == "term":
        bucket = "term_committed"
    else:
        bucket = "unevaluable"
        reasons.append("perfil de liquidez desconocido")

    runway: Decimal | None = None
    if monthly_expense is not None and monthly_expense > 0 and instant_liquidity is not None:
        runway = (instant_liquidity / monthly_expense)
        if bucket == "operational_liquidity":
            bucket = "emergency_fund"
        reasons.append(f"runway ≈ {runway:.1f} meses de gasto")
    elif bucket == "emergency_fund" or (bucket == "operational_liquidity"
                                         and instant_liquidity is not None
                                         and monthly_expense is None):
        bucket = "unevaluable"
        reasons.append("gasto mensual desconocido: no se puede evaluar suficiencia del fondo de emergencia")

    return LiquidityClassification(
        bucket=bucket, reasons=tuple(reasons),
        monthly_expense_known=monthly_expense is not None, runway_months=runway)


# --------------------------------------------------------------------------- #
# Confidence (§5)
# --------------------------------------------------------------------------- #
def score_confidence(
    terms: ProductTerms, comparison: ComparisonValidation,
    threshold: ThresholdRisk | None, liquidity: LiquidityClassification,
) -> Confidence:
    rate_ext = 0.9 if (terms.rate_guaranteed_until is not None
                       or terms.rate_fixity == RateFixity.FIXED_CONTRACTUAL) else 0.5
    if terms.subject_to_change:
        rate_ext = min(rate_ext, 0.4)
    tier_int = 0.5 if terms.tier_application == TierApplication.UNKNOWN else 0.85
    horizon = 0.4 if terms.subject_to_change else 0.7
    if terms.rate_guaranteed_until is not None:
        horizon = 0.9
    liq = 0.3 if (terms.liquidity is None or terms.liquidity.access == "unknown") else 0.8
    if liquidity.bucket == "unevaluable":
        liq = min(liq, 0.3)
    tax = 0.3 if terms.tax_basis in (TaxBasis.UNKNOWN,) else 0.6
    if terms.tax_basis == TaxBasis.PROVISIONAL_WITHHOLDING:
        tax = 0.4  # conocido pero no definitivo
    rec = 0.5
    if not comparison.comparable:
        rec = min(rec, 0.2)
    if threshold is not None and threshold.severity == "critical":
        rec = min(rec, 0.3)
    return Confidence(rate_extraction=rate_ext, tier_interpretation=tier_int,
                      horizon=horizon, liquidity=liq, tax=tax, recommendation=rec)


# --------------------------------------------------------------------------- #
# Auditoría (§6)
# --------------------------------------------------------------------------- #
def render_audit(
    terms: ProductTerms, scenarios: tuple[ScenarioResult, ...],
    comparison: ComparisonValidation, confidence: Confidence,
) -> tuple[str, ...]:
    lines: list[str] = ["--- MODO AUDITORÍA ---"]
    if terms.source_text:
        lines.append(f"Fuente: {terms.source_text!r}")
    lines.append(f"product_kind={terms.product_kind} "
                 f"tier_application={terms.tier_application.value} "
                 f"rate_fixity={terms.rate_fixity.value}")
    lines.append(f"rate_guaranteed_until={terms.rate_guaranteed_until} "
                 f"disclosure_valid_until={terms.disclosure_valid_until} "
                 f"subject_to_change={terms.subject_to_change}")
    for s in scenarios:
        lines.append(f"[{s.label}] gross={s.gross_interest:.4f} "
                     f"withholding={s.withholding:.4f} net={s.net_interest:.4f} "
                     f"eff_annual={s.effective_annual_rate:.6f}")
        for tr in s.formula_trace:
            lines.append(f"    {tr}")
    lines.append(f"comparable={comparison.comparable} delta={comparison.delta} "
                 f"reasons={comparison.reasons}")
    lines.append(f"confidence overall={confidence.overall:.2f} "
                 f"(rate={confidence.rate_extraction:.2f} tier={confidence.tier_interpretation:.2f} "
                 f"horizon={confidence.horizon:.2f} liq={confidence.liquidity:.2f} "
                 f"tax={confidence.tax:.2f} rec={confidence.recommendation:.2f})")
    return tuple(lines)


# --------------------------------------------------------------------------- #
# Ensamblador A–H (§3)
# --------------------------------------------------------------------------- #
def assemble_output(
    terms_map: dict[str, ProductTerms],
    scenarios: dict[str, tuple[ScenarioResult, ...]],
    comparison: ComparisonValidation,
    threshold: ThresholdRisk | None,
    liquidity: LiquidityClassification,
    confidence: Confidence,
    *,
    move_options: tuple[str, ...] | None = None,
    audit: bool = False,
) -> ProductAnalysisOutput:
    """Orquestador puro. Arma A–H. Lenguaje condicional por construcción."""
    # A — datos confirmados
    a: list[str] = []
    for pid, t in terms_map.items():
        rate_str = ", ".join(f"{ti.lower}-{ti.upper}@{ti.rate_annual}" for ti in t.rate_tiers) or "—"
        vig = (f"vigencia informativa {t.disclosure_valid_until}"
               if t.disclosure_valid_until else "vigencia no declarada")
        a.append(f"{pid}: {t.product_kind}; tasa {rate_str}; aplicación {t.tier_application.value}; {vig}")

    # B — no confirmados
    b: list[str] = []
    for pid, t in terms_map.items():
        if t.tier_application == TierApplication.UNKNOWN:
            b.append(f"{pid}: ¿los tramos son marginales o por saldo total?")
        if t.subject_to_change and t.rate_guaranteed_until is None:
            b.append(f"{pid}: tasa sujeta a cambios — ¿hay garantía contractual? no confirmada")
        if t.tax_basis in (TaxBasis.UNKNOWN, TaxBasis.PROVISIONAL_WITHHOLDING):
            b.append(f"{pid}: tratamiento fiscal definitivo no confirmado")
        if t.liquidity is None or t.liquidity.access == "unknown":
            b.append(f"{pid}: liquidez/disponibilidad no confirmada")
        if t.product_kind == "unknown":
            b.append(f"{pid}: naturaleza del producto no confirmada")

    # C — validaciones
    c = [f"capitales por escenario: {comparison.total_capitals}",
         f"comparable={comparison.comparable} delta={comparison.delta}"]
    c.extend(comparison.reasons)

    # D — rendimiento actual
    d: list[str] = []
    for pid, t in terms_map.items():
        if t.rate_tiers:
            d.append(f"{pid}: tramos " + ", ".join(
                f"{ti.rate_annual:.2%} en [{ti.lower},{ti.upper}]" for ti in t.rate_tiers))

    # E — opciones
    e = list(move_options) if move_options else ()

    # F — escenarios
    f_lines: list[str] = []
    for label, results in scenarios.items():
        for r in results:
            f_lines.append(f"[{label}/{r.label}] bruto≈{r.gross_interest:.2f} "
                           f"retención≈{r.withholding:.2f} neto≈{r.net_interest:.2f}")

    # G — recomendación (condicional)
    g: list[str] = ["Recomendación condicional — válida solo si se mantienen los supuestos listados."]
    if threshold is not None and threshold.severity == "critical":
        g.append(f"NO colocar el máximo: riesgo crítico de cruzar {threshold.limit} por intereses.")
    if liquidity.bucket == "unevaluable":
        g.append("Fondo de emergencia no evaluable sin gasto mensual — no recomiendo dejar un mínimo arbitrario.")

    # H — alertas
    h: list[str] = []
    for pid, t in terms_map.items():
        if t.subject_to_change:
            h.append(f"{pid}: tasa futura NO garantizada (sujeta a cambios)")
    if threshold is not None and threshold.crosses:
        h.append(f"umbral {threshold.limit}: se cruza en ~{threshold.days_to_cross} día(s), "
                 f"severidad {threshold.severity}")
    if liquidity.bucket == "unevaluable":
        h.append("liquidez: deterioro no evaluable (gasto mensual desconocido)")
    if not comparison.comparable:
        h.append("escenarios no comparables — no emitir delta de rendimiento como válido")

    out = ProductAnalysisOutput(
        A_datos_confirmados=tuple(a), B_no_confirmados=tuple(b),
        C_validaciones=tuple(c), D_rendimiento_actual=tuple(d),
        E_opciones=tuple(e), F_escenarios=tuple(f_lines),
        G_recomendacion=tuple(g), H_alertas=tuple(h),
        confidence=confidence,
    )

    # Cumplimiento de lenguaje (SPEC §4): revisar TODA la salida ensamblada en busca
    # de frases prohibidas. Las que vengan de entrada del modelo (p.ej. move_options)
    # no fluyen en silencio: se reportan como alerta para que el modelo las reescriba.
    banned_found: list[str] = []
    for section in (out.A_datos_confirmados, out.B_no_confirmados, out.C_validaciones,
                    out.D_rendimiento_actual, out.E_opciones, out.F_escenarios,
                    out.G_recomendacion, out.H_alertas):
        for line in section:
            for phrase in flag_banned(line):
                tag = f'frase prohibida «{phrase}»: reescribe en lenguaje condicional'
                if tag not in banned_found:
                    banned_found.append(tag)
    if banned_found:
        out = replace(out, H_alertas=out.H_alertas + tuple(banned_found))
    if audit:
        all_scn = tuple(r for results in scenarios.values() for r in results)
        out = replace(out, audit=render_audit(next(iter(terms_map.values())), all_scn,
                                              comparison, confidence))
    return out


def _demo() -> None:
    """Self-check del SPEC — corre los casos numéricos clave (4,5,6)."""
    # Caso 4: BondDia magnitud
    bond = Decimal("201895.37")
    annual = marginal_incremental_return((), TierApplication.MARGINAL, bond,
                                         Decimal("0.0643"), Decimal("0.10"), days=365)
    d108 = marginal_incremental_return((), TierApplication.MARGINAL, bond,
                                       Decimal("0.0643"), Decimal("0.10"), days=108)
    assert abs(annual - Decimal("7207.66")) < 1, annual
    assert abs(d108 - Decimal("2132.68")) < 1, d108
    # Caso 5: Openbank tramos
    tiers = (Tier(Decimal(0), Decimal(40000), Decimal("0.13")),
             Tier(Decimal(40000), None, Decimal("0.073")))
    avg = average_rate(tiers, Decimal("254363.80"))
    assert abs(avg - Decimal("0.08195")) < Decimal("0.0002"), avg
    annual5 = marginal_incremental_return(tiers, TierApplication.MARGINAL,
                                          Decimal("214363.80"), Decimal("0.073"),
                                          Decimal("0.10"), days=365)
    assert abs(annual5 - Decimal("5787.82")) < 1, annual5
    # Caso 6: umbral
    tr = threshold_risk(Decimal("499900"), Decimal("0.10"), Decimal("500000"))
    assert tr.severity == "critical", tr
    print("products.py self-check OK")


if __name__ == "__main__":
    _demo()
