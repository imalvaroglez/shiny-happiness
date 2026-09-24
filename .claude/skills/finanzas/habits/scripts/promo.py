"""Tracker de gasto elegible para promociones por ventana (p. ej. Amex $15k / $100k / 90 días).

Uso:
    python3 .claude/skills/finanzas/habits/scripts/promo.py \
        --account "The Platinum Credit Card" --start 2026-09-09 --days 90 \
        --targets 100000,105000,110000

Doctrina:
  - Clasifica POR PATRÓN primero, categoría después: la categoría puede mentir hasta
    que aterrice una reclasificación (las cuotas MSI llegaron como "Bank Fees").
  - MSI: solo cuentan las mensualidades PUBLICADAS dentro de la ventana (regla de la
    promo Amex). Las compras nacionales ≥ $6,000 pueden convertirse a MSI después —
    se señalan como riesgo, pero NUNCA se restan del elegible firme.
  - Proyecciones = Inferido, siempre separadas del elegible firme.
  - Solo mide. Nunca recomienda gasto para alcanzar la meta.
"""
from __future__ import annotations

import argparse
import re
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path
from typing import Any

_SHARED = str(Path(__file__).resolve().parents[2] / "_shared")
sys.path.insert(0, _SHARED)
from accounting_gates import Account, Category, account_from_snapshot, category_from_snapshot  # noqa: E402
from load import live_transactions, load_dataset  # noqa: E402

CDMX = timezone(timedelta(hours=-6))

# Categoría dedicada para cuotas MSI genéricas/fusionadas (decisión híbrida del usuario:
# subyacente para cuotas etiquetadas que él captura a mano; dedicada para las que llegan
# sin identidad de compra). kind=expense — las cuotas SON el gasto (doctrina AD-012).
MSI_CATEGORY = {"name": "MSI Installments", "kind": "expense", "parentId": None}

# Specs canónicos de reglas MSI — única fuente de verdad; el skill los pasa a
# writeback.apply_writeback vía resolve_rule_targets(). Prioridad >100 para ganar
# a las user_correction existentes (p. ej. '(?i)MONTO' @100).
MSI_RULES = [
    # R1: cuota etiquetada con contador ('MESES EN AUTOMÁTICO: VERSA 2/3') → dedicada
    # (si el usuario la re-etiqueta a mano a su categoría subyacente, eso gana en la app)
    {"patternRegex": r"(?i)MESES\s+EN\s+AUTOM[AÁ]TICO.*\d{1,2}\s*/\s*\d{1,2}", "priority": 106,
     "targetName": MSI_CATEGORY["name"]},
    # R2: cuota genérica ('MSI 1/3') → dedicada
    {"patternRegex": r"(?i)\bMSI\s*\d{1,2}\s*/\s*\d{1,2}\b", "priority": 106,
     "targetName": MSI_CATEGORY["name"]},
    # R3: crédito MSI (sin contador) → Credit Card Payments (convención histórica may/jun)
    {"patternRegex": r"(?i)MESES\s+EN\s+AUTOM[AÁ]TICO|\bMSI\s+AUTOM[AÁ]TICO\b|MONTO\s+A\s+DIFERIR", "priority": 105,
     "targetName": "Credit Card Payments"},
]
_CUOTA_RES = [re.compile(r["patternRegex"]) for r in MSI_RULES[:2]]
_CREDIT_RE = re.compile(MSI_RULES[2]["patternRegex"])
_AMAZON_MSI_RE = re.compile(r"(?i)\bAMAZON\s+MSI\b")
_COUNTER_RE = re.compile(r"(\d{1,2})\s*/\s*(\d{1,2})")

# 3 MSI automáticos para compras nacionales elegibles ≥ $6,000 (Platinum, sep-2026)
MSI_AUTO_THRESHOLD = Decimal("6000")
MSI_AUTO_MONTHS = 3
# Las cuotas Amex de esta cuenta postean ~día 11 de cada mes (patrón observado)
INSTALLMENT_POST_DAY = 11
# Categorías de fees de la app (excluidas del gasto elegible promocional)
FEES_CATEGORY_NAMES = {"Fees & Charges", "Bank Fees", "Interest Charges", "Commissions", "Late Fees"}


# --- reglas: resolución de targets y simulación del Categorizer -----------------

def resolve_rule_targets(
    specs: Sequence[dict[str, Any]],
    categories: Sequence[dict[str, Any]],
    prefer_ids: dict[str, str] | None = None,
) -> list[dict[str, Any]]:
    """specs → [{patternRegex, priority, categoryId}] listos para apply_category_rules.

    El bundle real tiene categorías duplicadas (p. ej. 3× 'General Merchandise') sin
    raíz compartida entre grupos, así que la instancia correcta se decide por
    CONTINUIDAD: `prefer_ids` mapea targetName → categoryId ya usado por las
    transacciones de la cuenta (evidencia), no por árbol. Sin preferencia, primera
    instancia no borrada (determinístico por orden de archivo).
    """
    prefer_ids = prefer_ids or {}

    def pick(name: str) -> str:
        candidates = [c for c in categories if c.get("name") == name and not c.get("deletedAt")]
        if not candidates:
            raise ValueError(f"Categoría '{name}' no existe en Category.json")
        preferred = prefer_ids.get(name)
        if preferred:
            matching = [c for c in candidates if c["id"] == preferred]
            if not matching:
                raise ValueError(
                    f"prefer_ids['{name}'] = {preferred} no es una categoría '{name}' válida"
                )
            return preferred
        return candidates[0]["id"]

    return [{"patternRegex": s["patternRegex"], "priority": s["priority"], "categoryId": pick(s["targetName"])}
            for s in specs]


def categorize_with_rules(rules: Sequence[dict[str, Any]], description: str) -> str | None:
    """Réplica del Categorizer (Categorizer.swift:17,25-31,43-52): regex sobre
    descriptionRaw, priority DESC, primera match gana."""
    for rule in sorted(rules, key=lambda r: -r.get("priority", 0)):
        try:
            if re.search(rule["patternRegex"], description, re.IGNORECASE):
                return rule["categoryId"]
        except re.error:
            continue  # regex ICU-only que python no compila: ignorar (defensivo)
    return None


# --- clasificación por fila ------------------------------------------------------

@dataclass
class PromoClass:
    kind: str  # normal_charge | msi_installment | msi_installment_probable | credit | payment | fee | excluded
    eligible: Decimal | None
    reason: str


def classify_promo(tx: dict[str, Any], account: Account | None, category: Category | None) -> PromoClass:
    """Clasifica una fila para el conteo promocional. Patrón primero, categoría después."""
    desc = tx.get("descriptionRaw") or ""
    amount = Decimal(str(tx.get("amount", 0)))

    if tx.get("deletedAt") is not None:
        return PromoClass("excluded", None, "soft-deleted")
    if tx.get("isDuplicate"):
        return PromoClass("excluded", None, "duplicado")

    if amount < 0:
        if any(rx.search(desc) for rx in _CUOTA_RES):
            return PromoClass("msi_installment", abs(amount), "cuota MSI (patrón)")
        if _AMAZON_MSI_RE.search(desc):
            return PromoClass("msi_installment_probable", abs(amount), "parece cuota MSI recurrente (Inferido)")

    if amount > 0:
        if category is not None and category.kind == "creditCardPayment":
            return PromoClass("payment", None, "pago de tarjeta")
        return PromoClass("credit", None, "crédito/abono (reversión MSI o reembolso)")

    if tx.get("isTransfer") or (category is not None and category.kind == "transfer"):
        return PromoClass("excluded", None, "transferencia")
    if category is not None and category.kind == "creditCardPayment":
        return PromoClass("payment", None, "pago de tarjeta")
    if category is not None and category.name in FEES_CATEGORY_NAMES:
        return PromoClass("fee", None, "comisión/interés — no elegible para la promo")
    return PromoClass("normal_charge", abs(amount), "compra")


# --- ventana y agregación ---------------------------------------------------------

def window_bounds(start: str, days: int) -> tuple[str, str]:
    """(inicio, fin exclusivo) en UTC. El día local empieza 00:00 CDMX (UTC-6):
    start 2026-09-09 → ('2026-09-09T06:00:00Z', '2026-12-08T06:00:00Z') para 90 días."""
    d = date.fromisoformat(start)
    start_utc = datetime(d.year, d.month, d.day, 6, 0, 0, tzinfo=UTC)
    end_utc = start_utc + timedelta(days=days)
    fmt = lambda dt: dt.isoformat().replace("+00:00", "Z")  # noqa: E731
    return fmt(start_utc), fmt(end_utc)


def _find_account_row(ds: dict[str, Any], account: str) -> dict[str, Any]:
    matching = [a for a in ds["models"]["Account"] if account in (a.get("nickname"), a.get("institution"))]
    if not matching:
        raise ValueError(f"No se encontró la cuenta '{account}'")
    if len(matching) > 1:
        # 'institución' ambigua (p. ej. dos Amex): exige el nickname exacto
        by_nick = [a for a in matching if a.get("nickname") == account]
        if len(by_nick) != 1:
            raise ValueError(f"'{account}' coincide con {len(matching)} cuentas — usa el nickname exacto")
        return by_nick[0]
    return matching[0]


def transactions_in_window(ds: dict[str, Any], account: str, start: str, days: int) -> list[dict[str, Any]]:
    start_iso, end_iso = window_bounds(start, days)
    account_id = _find_account_row(ds, account)["id"]
    return [
        t for t in live_transactions(ds)
        if t.get("accountId") == account_id and start_iso <= (t.get("postedAt") or "") < end_iso
    ]


def _next_installment_dates(last_posted: str, remaining: int) -> list[date]:
    """Fechas proyectadas de las siguientes `remaining` cuotas (~día 11 mensual)."""
    d = datetime.fromisoformat(last_posted.replace("Z", "+00:00")).astimezone(CDMX).date()
    out, y, m = [], d.year, d.month
    for _ in range(remaining):
        m += 1
        if m == 13:
            m, y = 1, y + 1
        out.append(date(y, m, INSTALLMENT_POST_DAY))
    return out


def project_installments(plans: Sequence[dict[str, Any]], window_end_iso: str) -> Decimal:
    """Elegible proyectado (Inferido): cuotas restantes cuya fecha ~11 cae dentro de la ventana."""
    end_date = datetime.fromisoformat(window_end_iso.replace("Z", "+00:00")).astimezone(CDMX).date()
    total = Decimal("0")
    for plan in plans:
        remaining = plan["total"] - plan["n"]
        for when in _next_installment_dates(plan["last_posted"], remaining):
            if when < end_date:
                total += plan["monthly"]
    return total


def _installment_plans_from(window_txs: Sequence[dict[str, Any]]) -> list[dict[str, Any]]:
    """Planes MSI visibles en la ventana, colapsando filas del MISMO plan.

    La identidad del plan es (monto, total, descripción): el contador n avanza por cuota
    (1/3, 2/3…), así que NO forma parte de la key — nos quedamos con el n máximo y la
    fecha más reciente. El contador se toma del ÚLTIMO match de la descripción (una fecha
    '08/05/2026' antes del contador real no debe leerse como n/total).
    """
    best: dict[tuple, dict[str, Any]] = {}
    for t in window_txs:
        desc = t.get("descriptionRaw") or ""
        if Decimal(str(t.get("amount", 0))) >= 0:
            continue
        if not any(rx.search(desc) for rx in _CUOTA_RES):
            continue
        counters = [(int(a), int(b)) for a, b in _COUNTER_RE.findall(desc)]
        counters = [(n, tot) for n, tot in counters if 1 <= n <= tot <= 48]
        if not counters:
            continue
        n, total = counters[-1]
        monthly = abs(Decimal(str(t["amount"])))
        # key sin el contador: 'MSI 1/3' y 'MSI 2/3' son el MISMO plan; 'Compra A 1/3'
        # vs 'Compra B 1/3' siguen siendo planes distintos.
        # ponytail: dos compras distintas con mismo monto + misma descripción sin etiqueta
        # siguen colisionando; la proyección es Inferido y se etiqueta como tal.
        key = (str(t["amount"]), total, _COUNTER_RE.sub("", desc))
        plan = {"monthly": monthly, "n": n, "total": total, "last_posted": t["postedAt"], "id": t["id"]}
        if key not in best or (n, t["postedAt"]) >= (best[key]["n"], best[key]["last_posted"]):
            best[key] = plan
    return list(best.values())


def _msi_conversion_risks(window_txs: Sequence[dict[str, Any]], classes: Sequence[PromoClass],
                          end_iso: str) -> list[dict[str, Any]]:
    """Compras nacionales ≥ umbral aún sin crédito MSI: si Amex las convierte, solo
    cuentan las cuotas que posteen dentro de la ventana (Inferido)."""
    end_date = datetime.fromisoformat(end_iso.replace("Z", "+00:00")).astimezone(CDMX).date()
    risks = []
    for t, c in zip(window_txs, classes, strict=True):
        if c.kind != "normal_charge":
            continue
        amount = c.eligible or Decimal("0")
        if amount < MSI_AUTO_THRESHOLD:
            continue
        monthly = (amount / MSI_AUTO_MONTHS).quantize(Decimal("0.01"))
        posted = datetime.fromisoformat(t["postedAt"].replace("Z", "+00:00")).astimezone(CDMX).date()
        fit = 0
        y, m = posted.year, posted.month
        while True:
            m += 1
            if m == 13:
                m, y = 1, y + 1
            when = date(y, m, INSTALLMENT_POST_DAY)
            if when >= end_date:
                break
            fit += 1
        risks.append({
            "kind": "msi_conversion_risk", "id": t["id"], "amount": amount,
            "description": (t.get("merchantNormalized") or t.get("descriptionRaw") or "")[:40],
            "cuotas_in_window": fit, "projected_impact": amount - monthly * fit,
            "certainty": "Inferido",
        })
    return risks


def promo_report(ds: dict[str, Any], account: str, start: str, days: int,
                 targets: Sequence[int]) -> dict[str, Any]:
    """Reporte completo: bruto, elegible firme (Hecho/Derivado), proyección (Inferido),
    gaps vs targets, día N/90 según la última tx visible, excluidos con razón y riesgos."""
    start_iso, end_iso = window_bounds(start, days)
    window_txs = sorted(transactions_in_window(ds, account, start, days), key=lambda t: t.get("postedAt", ""))
    cats = {c["id"]: category_from_snapshot(c) for c in ds["models"]["Category"]}
    acc = account_from_snapshot(_find_account_row(ds, account))

    classes = [classify_promo(t, acc, cats.get(t.get("categoryId"))) for t in window_txs]

    charge_amounts = [Decimal(str(t["amount"])) for t, c in zip(window_txs, classes, strict=True)]
    gross = sum(
        (a for a, c in zip(charge_amounts, classes, strict=True)
         if c.kind != "excluded" and a < 0),
        Decimal("0"),
    )
    eligible_firm = sum((c.eligible for c in classes if c.eligible is not None), Decimal("0"))

    by_kind: dict[str, list[str]] = {}
    for t, c in zip(window_txs, classes, strict=True):
        by_kind.setdefault(c.kind, []).append(t["id"])
    excluded = [{"id": t["id"], "reason": c.reason}
                for t, c in zip(window_txs, classes, strict=True) if c.eligible is None]

    plans = _installment_plans_from(window_txs)
    projected = project_installments(plans, end_iso)

    last_posted = max((t.get("postedAt", "") for t in window_txs), default=None)
    day = days_remaining = None
    if last_posted:
        last_date = datetime.fromisoformat(last_posted.replace("Z", "+00:00")).astimezone(CDMX).date()
        start_date = date.fromisoformat(start)
        day = (last_date - start_date).days + 1
        days_remaining = max(0, days - day)

    return {
        "account": account, "start": start, "days": days,
        "window": (start_iso, end_iso),
        "gross": gross, "eligible_firm": eligible_firm,
        "projected_installments": projected,  # Inferido
        "eligible_with_projection": eligible_firm + projected,
        "gaps": [{"target": Decimal(str(t)),
                  "remaining": max(Decimal("0"), Decimal(str(t)) - eligible_firm),
                  "pct": (eligible_firm / Decimal(str(t))) if t else Decimal("0")}
                 for t in targets],
        "day": day, "days_remaining": days_remaining,
        "counts": {k: len(v) for k, v in by_kind.items()},
        "ids_by_kind": by_kind,
        "excluded": excluded,
        "warnings": _msi_conversion_risks(window_txs, classes, end_iso),
        "data_through": last_posted,
        "plans": plans,
    }


def render_report(report: dict[str, Any]) -> str:
    """Salida legible con niveles de certeza (Hecho/Derivado/Inferido)."""
    money = lambda d: f"${d:,.2f}"  # noqa: E731
    lines = [
        f"🎯 Promo {report['account']} · ventana {report['start']} + {report['days']} días "
        f"({report['window'][0][:10]} → {report['window'][1][:10]} excl.)",
        f"   día {report['day']}/{report['days']} · quedan {report['days_remaining']} días · "
        f"datos hasta {report['data_through'][:16].replace('T', ' ') if report['data_through'] else '—'} CDMX",
        "",
        f"   Gasto bruto (todos los cargos):        {money(report['gross'])}  [Derivado]",
        f"   Elegible firme:                        {money(report['eligible_firm'])}  [Hecho: cargos publicados]",
    ]
    if report["projected_installments"] > 0:
        lines.append(f"   + cuotas proyectadas en ventana:       {money(report['projected_installments'])}  [Inferido]")
        lines.append(f"   = elegible con proyección:             {money(report['eligible_with_projection'])}")
    lines.append("")
    for gap in report["gaps"]:
        flag = "✅" if gap["remaining"] == 0 else "⏳"
        lines.append(f"   {flag} meta ${gap['target']:,.0f}: falta {money(gap['remaining'])} "
                     f"({float(gap['pct']) * 100:.1f}% avance)")
    if report["excluded"]:
        lines.append("")
        lines.append("   Excluidos del conteo:")
        for ex in report["excluded"]:
            lines.append(f"     · {ex['id'][:8]}  {ex['reason']}")
    for w in report["warnings"]:
        lines.append("")
        lines.append(f"   ⚠️  {w['description']}: {money(w['amount'])} nacional ≥ ${MSI_AUTO_THRESHOLD:,.0f}. "
                     f"Si Amex la convierte a {MSI_AUTO_MONTHS} MSI, contarían solo {w['cuotas_in_window']} "
                     f"cuotas ≤ fin de ventana → elegible bajaría ~{money(w['projected_impact'])}. [Inferido]")
    lines.append("")
    lines.append("   Trazabilidad (ids por clase): " + "; ".join(
        f"{k}={len(v)}" for k, v in sorted(report["ids_by_kind"].items())))
    lines.append("   Este tracker solo mide; no recomienda gastar para llegar a la meta.")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Tracker de gasto elegible promocional")
    parser.add_argument("--account", required=True, help="nickname o institución de la cuenta")
    parser.add_argument("--start", required=True, help="fecha ISO de inicio de la ventana (YYYY-MM-DD)")
    parser.add_argument("--days", type=int, default=90)
    parser.add_argument("--targets", default="100000,105000,110000",
                        help="metas MXN separadas por coma")
    parser.add_argument("--bundle", default=None, help="ruta a un .ftbackup específico")
    args = parser.parse_args(argv)

    ds = load_dataset(Path(args.bundle) if args.bundle else None)
    targets = [int(x) for x in args.targets.split(",") if x.strip()]
    report = promo_report(ds, args.account, args.start, args.days, targets)
    print(render_report(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
