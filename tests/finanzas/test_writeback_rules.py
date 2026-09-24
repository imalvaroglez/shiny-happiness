"""apply_category_rules: shape exacto de CategoryRuleSnapshot (BackupModels.swift:151-161)."""
from __future__ import annotations

import json
import re
import uuid
from pathlib import Path

import load
import pytest
import writeback

from conftest import NOW

SNAPSHOT_FIELDS = {
    "id", "patternRegex", "merchantMatch", "categoryId", "priority",
    "source", "matchCount", "createdFrom", "lastModifiedAt",
}


def rules_of(bundle: Path) -> list[dict]:
    return json.loads((bundle / "models" / "CategoryRule.json").read_text(encoding="utf-8"))


def test_rule_row_matches_snapshot_shape(bundle: Path, tmp_path: Path) -> None:
    out = writeback.apply_category_rules(
        load.load_dataset(bundle),
        [{"patternRegex": r"(?i)\bMSI\s*\d+\s*/\s*\d+\b", "categoryId": "GM", "priority": 106}],
        output_dir=str(tmp_path / "a"), now=NOW,
    )
    new = [r for r in rules_of(out) if r["id"] not in {"RULE-MONTO", "RULE-AMAZON"}]
    assert len(new) == 1
    row = new[0]
    assert set(row.keys()) == SNAPSHOT_FIELDS
    uuid.UUID(row["id"])  # uuid válido…
    assert row["id"] == row["id"].upper()  # …uppercase como Swift UUID.uuidString
    assert row["merchantMatch"] == ""
    assert row["matchCount"] == 0
    assert row["source"] == "user_correction"
    assert row["createdFrom"] == "skill:msi-convention"
    assert row["lastModifiedAt"] == "2026-09-22T00:00:00Z"
    assert row["categoryId"] == "GM"
    assert re.compile(row["patternRegex"])  # compila


def test_dedup_identical_pattern_and_category(bundle: Path, tmp_path: Path) -> None:
    ds = load.load_dataset(bundle)
    rule = {"patternRegex": r"(?i)\bMSI\s*\d+\s*/\s*\d+\b", "categoryId": "GM", "priority": 106}
    out = writeback.apply_category_rules(ds, [rule], output_dir=str(tmp_path / "a"), now=NOW)
    # segunda pasada contra el bundle YA con la regla → no-op, no duplica
    out2 = writeback.apply_category_rules(
        load.load_dataset(out), [rule], output_dir=str(tmp_path / "b"), now=NOW
    )
    assert len(rules_of(out2)) == len(rules_of(out))


def test_rejects_unknown_category_and_bad_payload(bundle: Path, tmp_path: Path) -> None:
    ds = load.load_dataset(bundle)
    with pytest.raises(writeback.WritebackError, match="categoryId"):
        writeback.apply_category_rules(
            ds, [{"patternRegex": "(?i)x", "categoryId": "NO-EXISTE", "priority": 106}],
            output_dir=str(tmp_path / "a"), now=NOW,
        )
    with pytest.raises(writeback.WritebackError, match="patternRegex"):
        writeback.apply_category_rules(
            ds, [{"categoryId": "GM", "priority": 106}],  # sin pattern
            output_dir=str(tmp_path / "b"), now=NOW,
        )
    with pytest.raises(writeback.WritebackError, match="patternRegex"):
        writeback.apply_category_rules(
            ds, [{"patternRegex": "(?i)\\bMSI\\s*\\d+\\s*/\\s*\\d+\\b", "categoryId": "GM",
                  "priority": 106, "amount": -1}],  # campo extra no permitido
            output_dir=str(tmp_path / "c"), now=NOW,
        )
    assert not (tmp_path / "a").exists() and not (tmp_path / "b").exists() and not (tmp_path / "c").exists()


def test_recategorizations_unchanged_behavior(bundle: Path, tmp_path: Path) -> None:
    """La refactorización no rompe el flujo existente de recategorize/."""
    out = writeback.apply_recategorizations(
        load.load_dataset(bundle), [{"id": "TX-MSI-1", "categoryId": "ELECTRONICS"}],
        output_dir=str(tmp_path / "a"), now=NOW,
    )
    txs = {t["id"]: t for t in json.loads((out / "models" / "Transaction.json").read_text(encoding="utf-8"))}
    assert txs["TX-MSI-1"]["categoryId"] == "ELECTRONICS"
    assert txs["TX-MSI-1"]["lastModifiedAt"] == "2026-09-22T00:00:00Z"
    assert len(rules_of(out)) == 2  # reglas intactas


def test_new_category_creation_shape_and_dedup(bundle: Path, tmp_path: Path) -> None:
    """Crear categoría: shape CategorySnapshot, id explícito referenciable por changes/rules."""
    msi_id = "11111111-2222-3333-4444-555555555555"
    out = writeback.apply_writeback(
        load.load_dataset(bundle),
        changes=[{"id": "TX-MSI-1", "categoryId": msi_id}],
        rules=[{"patternRegex": r"(?i)\bMSI\s*\d+\s*/\s*\d+\b", "categoryId": msi_id, "priority": 106}],
        new_categories=[{"id": msi_id, "name": "Deferred Payments", "kind": "expense"}],
        output_dir=str(tmp_path / "a"), now=NOW,
    )
    cats = json.loads((out / "models" / "Category.json").read_text(encoding="utf-8"))
    new = [c for c in cats if c["id"] == msi_id]
    assert new and set(new[0].keys()) == {"id", "name", "parentId", "kind", "deletedAt", "lastModifiedAt"}
    assert new[0]["kind"] == "expense" and new[0]["deletedAt"] is None
    txs = {t["id"]: t for t in json.loads((out / "models" / "Transaction.json").read_text(encoding="utf-8"))}
    assert txs["TX-MSI-1"]["categoryId"] == msi_id
    rules = json.loads((out / "models" / "CategoryRule.json").read_text(encoding="utf-8"))
    assert any(r["categoryId"] == msi_id for r in rules)

    # re-aplicar la misma categoría → dedup no-op (misma cuenta de categorías)
    out2 = writeback.apply_writeback(
        load.load_dataset(out), new_categories=[{"name": "Deferred Payments", "kind": "expense"}],
        output_dir=str(tmp_path / "b"), now=NOW,
    )
    assert len(json.loads((out2 / "models" / "Category.json").read_text(encoding="utf-8"))) == len(cats)

    # kind inválido → rechazo limpio, sin escribir
    with pytest.raises(writeback.WritebackError, match="kind"):
        writeback.apply_writeback(
            load.load_dataset(bundle), new_categories=[{"name": "X", "kind": "no-existe"}],
            output_dir=str(tmp_path / "c"), now=NOW,
        )
    assert not (tmp_path / "c").exists()


def test_new_category_rejects_unknown_parent(bundle: Path, tmp_path: Path) -> None:
    """Bug review #3: parentId inexistente → rechazo (sin aterrizar en raíz silenciosamente)."""
    with pytest.raises(writeback.WritebackError, match="parentId"):
        writeback.apply_writeback(
            load.load_dataset(bundle),
            new_categories=[{"name": "X", "kind": "expense", "parentId": "NO-EXISTE"}],
            output_dir=str(tmp_path / "x"), now=NOW,
        )
    assert not (tmp_path / "x").exists()
