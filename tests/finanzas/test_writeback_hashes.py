"""El manifest del bundle generado debe validar igual que BackupArchive.isValidBundle.

La UI real de restore pasa por summary(at:) → isValidBundle, que compara
contentHashes (SHA-256 por modelo) y modelCounts. Un writeback que reescribe
models/*.json sin recalcular el hash produce un bundle que la app rechaza.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

import load
import pytest
import writeback

from conftest import NOW


def validate_bundle_like_app(bundle: Path) -> tuple[bool, str]:
    """Réplica python de BackupArchive.isValidBundle (BackupArchive.swift:53-70)."""
    manifest = json.loads((bundle / "manifest.json").read_text(encoding="utf-8"))
    models_dir = bundle / "models"
    for name, expected_count in manifest["modelCounts"].items():
        rows = json.loads((models_dir / f"{name}.json").read_text(encoding="utf-8"))
        if len(rows) != expected_count:
            return False, f"modelCounts[{name}]: {len(rows)} != {expected_count}"
    for name, expected_hash in manifest["contentHashes"].items():
        actual = hashlib.sha256((models_dir / f"{name}.json").read_bytes()).hexdigest()
        if actual != expected_hash:
            return False, f"contentHashes[{name}] desactualizado"
    return True, "ok"


def test_recategorization_updates_transaction_hash(bundle: Path, tmp_path_factory) -> None:
    out = writeback.apply_recategorizations(
        load.load_dataset(bundle), [{"id": "TX-MSI-1", "categoryId": "ELECTRONICS"}],
        output_dir=str(tmp_path_factory.mktemp("out")), now=NOW,
    )
    ok, why = validate_bundle_like_app(out)
    assert ok, why


def test_rules_writeback_updates_rule_hash_and_count(bundle: Path, tmp_path_factory) -> None:
    out = writeback.apply_category_rules(
        load.load_dataset(bundle),
        [{"patternRegex": r"(?i)\bMSI\s*\d+\s*/\s*\d+\b", "categoryId": "GM", "priority": 106}],
        output_dir=str(tmp_path_factory.mktemp("out")), now=NOW,
    )
    ok, why = validate_bundle_like_app(out)
    assert ok, why
    rules = json.loads((out / "models" / "CategoryRule.json").read_text(encoding="utf-8"))
    assert len(rules) == 3  # 2 existentes + 1 nueva


def test_combined_writeback_validates(bundle: Path, tmp_path_factory) -> None:
    out = writeback.apply_writeback(
        load.load_dataset(bundle),
        changes=[{"id": "TX-MSI-CREDIT", "categoryId": "CC-PAY"}],
        rules=[{"patternRegex": r"(?i)MESES\s+EN\s+AUTOM[AÁ]TICO", "categoryId": "CC-PAY", "priority": 105}],
        output_dir=str(tmp_path_factory.mktemp("out")), now=NOW,
    )
    ok, why = validate_bundle_like_app(out)
    assert ok, why
    # Transaction y CategoryRule ambos con hash fresco, modelos no tocados intactos
    manifest = json.loads((out / "manifest.json").read_text(encoding="utf-8"))
    models = {p.stem: p for p in (out / "models").glob("*.json")}
    for name, path in models.items():
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        assert manifest["contentHashes"][name] == actual
    assert manifest["modelCounts"]["CategoryRule"] == 3
    assert manifest["modelCounts"]["Transaction"] == 4
    assert manifest["schemaVersion"] == 7


def test_failed_validation_writes_nothing(bundle: Path, tmp_path_factory) -> None:
    out_dir = tmp_path_factory.mktemp("out")
    with pytest.raises(writeback.WritebackError):
        writeback.apply_category_rules(
            load.load_dataset(bundle),
            [{"patternRegex": "(((", "categoryId": "GM", "priority": 106}],  # regex inválida
            output_dir=str(out_dir), now=NOW,
        )
    assert list(out_dir.iterdir()) == []
