"""Las reglas MSI nuevas deben comportarse bien dentro del conjunto existente.

Simula el Categorizer de la app (Categorizer.swift:17,25-31,43-52): regex sobre
descriptionRaw, priority DESC, primera match gana. Los specs canónicos viven en
promo.MSI_RULES (única fuente de verdad para skill y tests).
"""
from __future__ import annotations

from pathlib import Path

import pytest

from conftest import CATS, load_module_by_path

REPO = Path(__file__).resolve().parents[2]
promo = load_module_by_path("promo_msi_rules", REPO / ".claude" / "skills" / "finanzas" / "habits" / "scripts" / "promo.py")


@pytest.fixture(scope="module")
def rules() -> list[dict]:
    """Las 2 reglas existentes del bundle sintético + las 3 nuevas resueltas por nombre."""
    existing = [
        {"patternRegex": "(?i)MONTO", "priority": 100, "categoryId": "CC-PAY"},
        {"patternRegex": "(?i)AMAZON|AMZN", "priority": 10, "categoryId": "SHOPPING"},
    ]
    return existing + promo.resolve_rule_targets(promo.MSI_RULES, list(CATS.values()))


def categorize(rules: list[dict], description: str) -> str | None:
    return promo.categorize_with_rules(rules, description)


@pytest.mark.parametrize("description, expected", [
    # cuotas → categoría dedicada MSI Installments (R1/R2 @106)
    ("MSI 1/3", "MSI"),
    ("MSI 3/3", "MSI"),
    ("MSI 10/12", "MSI"),
    ("MESES EN AUTOMÁTICO: Versa 2/3", "MSI"),
    ("MESES EN AUTOMÁTICO: Galas de Mariachi + Seguro Versa 1/3", "MSI"),
    # créditos MSI → Credit Card Payments (R3 @105; sin contador n/N)
    ("MESES EN AUTOMÁTICO", "CC-PAY"),
    ("MONTO A DIFERIR MESES EN AUTOMÁTICO", "CC-PAY"),
    ("MSI AUTOMÁTICO", "CC-PAY"),
])
def test_positive_matches(rules: list[dict], description: str, expected: str) -> None:
    assert categorize(rules, description) == expected


@pytest.mark.parametrize("description", [
    "PAGO INTERBANCARIO PAGO RECIBIDO DE STP 09:23:25 08/05/2026 TITULAR",  # fecha no es n/N
    "GRACIAS POR SU PAGO EN LINEA",
    "WALMART SUPER VENTA EN CIUDAD DE MEXICO /REF19201401",
    "Qualitas 1/3",  # sin MSI/MESES: no matchea las nuevas (el usuario la etiqueta a mano)
])
def test_no_false_positives(rules: list[dict], description: str) -> None:
    assert categorize(rules, description) is None


def test_amazon_msi_stays_shopping(rules: list[dict]) -> None:
    """'Amazon MSI' (sin contador) no es crédito MSI: cae a la regla AMAZON @10 → Shopping."""
    assert categorize(rules, "Amazon MSI") == "SHOPPING"


def test_rule_targets_resolve_to_existing_categories() -> None:
    resolved = promo.resolve_rule_targets(promo.MSI_RULES, list(CATS.values()))
    names = {c["name"] for c in CATS.values()}
    ids = {c["id"] for c in CATS.values()}
    for spec, rule in zip(promo.MSI_RULES, resolved, strict=True):
        assert rule["categoryId"] in ids
        assert spec["targetName"] in names
        assert rule["patternRegex"] == spec["patternRegex"]
        assert rule["priority"] == spec["priority"]


def test_resolution_prefers_evidence_ids() -> None:
    """Con categorías duplicadas (mismo nombre), gana la instancia de prefer_ids (continuidad)."""
    def cat(cid, name, kind="expense"):
        return {"id": cid, "name": name, "parentId": None, "kind": kind, "deletedAt": None}
    cats = [
        cat("ROOT", "Fees & Charges"), cat("BF-A", "Bank Fees"),
        cat("GM-FIRST", "General Merchandise"), cat("GM-A", "General Merchandise"),
        cat("MSI-FIRST", "MSI Installments"), cat("MSI-A", "MSI Installments"),
        cat("CCP-FIRST", "Credit Card Payments", kind="creditCardPayment"),
        cat("CCP-A", "Credit Card Payments", kind="creditCardPayment"),
    ]
    prefer = {"MSI Installments": "MSI-A", "Credit Card Payments": "CCP-A"}
    resolved = promo.resolve_rule_targets(promo.MSI_RULES, cats, prefer_ids=prefer)
    by_target = {spec["targetName"]: rule["categoryId"]
                 for spec, rule in zip(promo.MSI_RULES, resolved, strict=True)}
    assert by_target["MSI Installments"] == "MSI-A"
    assert by_target["Credit Card Payments"] == "CCP-A"

    # sin preferencia: primera instancia determinística
    fallback = promo.resolve_rule_targets(promo.MSI_RULES, cats)
    fb = {spec["targetName"]: rule["categoryId"]
          for spec, rule in zip(promo.MSI_RULES, fallback, strict=True)}
    assert fb["MSI Installments"] == "MSI-FIRST"

    # preferencia inválida (no es instancia de ese nombre): error explícito
    with pytest.raises(ValueError, match="no es una categoría"):
        promo.resolve_rule_targets(promo.MSI_RULES, cats, prefer_ids={"MSI Installments": "BF-A"})
