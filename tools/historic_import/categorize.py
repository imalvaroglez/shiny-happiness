"""Port de Categorizer.swift: reglas del backup de referencia, prioridad DESC,
primer match case-insensitive sobre descriptionRaw. Las 125 reglas del backup
ya incluyen las seed migradas — no hay fallback a SeedData."""

import json
import re
from pathlib import Path


class Matcher:
    def __init__(self, compiled: list[tuple[re.Pattern, str]], payment_category_id: str | None):
        self._compiled = compiled
        self.payment_category_id = payment_category_id

    def match(self, description_raw: str) -> str | None:
        for regex, category_id in self._compiled:
            if regex.search(description_raw):
                return category_id
        return None


def build(backup_models_dir: Path) -> Matcher:
    categories = json.loads((backup_models_dir / "Category.json").read_text())
    rules = json.loads((backup_models_dir / "CategoryRule.json").read_text())
    alive = {c["id"] for c in categories if not c.get("deletedAt")}
    compiled = sorted(
        ((rule["priority"], re.compile(rule["patternRegex"]), rule["categoryId"])
         for rule in rules if rule.get("categoryId") in alive),
        key=lambda t: -t[0],
    )
    return Matcher([(regex, cid) for _, regex, cid in compiled],
                   _payment_category(categories))


def _payment_category(categories: list[dict]) -> str | None:
    """Categoría 'Card Payment Received' activa cuyo padre (si tiene) también
    esté activo — hay una jerarquía vieja borrada que no debe usarse."""
    by_id = {c["id"]: c for c in categories}
    fallback = None
    for cat in categories:
        if cat.get("kind") != "creditCardPayment" or cat.get("deletedAt"):
            continue
        parent = cat.get("parentId")
        if parent and by_id.get(parent, {}).get("deletedAt"):
            continue
        if cat["name"] == "Card Payment Received":
            return cat["id"]
        if fallback is None:
            fallback = cat["id"]
    return fallback
