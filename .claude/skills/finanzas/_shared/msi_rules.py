"""Reglas MSI canónicas del skill finanzas — única fuente de verdad.

Extraídas de promo.py cuando el tracker de promociones fue retirado
(2026-09-30): el categorizador MSI que usa el writeback y sus tests vive
aquí; el tracking de promociones ahora es la adjudicación manual de la
app (AD-025).
"""
from __future__ import annotations

import re
from collections.abc import Sequence
from typing import Any

# Categoría dedicada para cuotas MSI genéricas/fusionadas (decisión híbrida del usuario:
# subyacente para cuotas etiquetadas que él captura a mano; dedicada para las que llegan
# sin identidad de compra). kind=expense — las cuotas SON el gasto (doctrina AD-012).
MSI_CATEGORY = {"name": "MSI Installments", "kind": "expense", "parentId": None}

# Specs canónicos de reglas MSI; el skill los pasa a writeback.apply_writeback
# vía resolve_rule_targets(). Prioridad >100 para ganar a las user_correction
# existentes (p. ej. '(?i)MONTO' @100).
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
