"""Synthetic backup compatibility tests for the finanzas shared loader."""
from __future__ import annotations

import json
import sys
from datetime import UTC, datetime
from pathlib import Path

import pytest

SHARED_DIR = Path(__file__).resolve().parents[2] / ".claude" / "skills" / "finanzas" / "_shared"
sys.path.insert(0, str(SHARED_DIR))

import load  # noqa: E402
import writeback  # noqa: E402


def make_backup(tmp_path: Path, schema: int, *, include_due_date_override: bool = False) -> Path:
    bundle = tmp_path / f"synthetic-v{schema}.ftbackup"
    models = bundle / "models"
    models.mkdir(parents=True)
    (bundle / "manifest.json").write_text(
        json.dumps({"schemaVersion": schema, "appVersion": "test", "createdAt": "2026-08-04T00:00:00Z"}),
        encoding="utf-8",
    )
    (models / "Account.json").write_text(json.dumps([{"id": "account-1"}]), encoding="utf-8")
    (models / "Category.json").write_text(json.dumps([{"id": "category-1"}]), encoding="utf-8")
    (models / "Transaction.json").write_text(
        json.dumps([{"id": "transaction-1", "categoryId": "category-1", "lastModifiedAt": "2026-01-01T00:00:00Z"}]),
        encoding="utf-8",
    )
    if include_due_date_override:
        (models / "SettlementDueDateOverride.json").write_text(
            json.dumps(
                [{
                    "id": "override-1",
                    "transactionID": "transaction-1",
                    "dueDate": "2026-08-15T00:00:00Z",
                    "lastModifiedAt": "2026-08-04T00:00:00Z",
                }]
            ),
            encoding="utf-8",
        )
    return bundle


@pytest.mark.parametrize("schema", [4, 5, 6, 7])
def test_load_dataset_accepts_supported_schemas(tmp_path: Path, schema: int) -> None:
    dataset = load.load_dataset(make_backup(tmp_path, schema, include_due_date_override=schema == 7))

    assert dataset["manifest"]["schemaVersion"] == schema
    assert dataset["transactions"] == dataset["models"]["Transaction"]
    assert dataset["settlement_due_date_overrides"] == (
        dataset["models"]["SettlementDueDateOverride"]
    )


def test_load_dataset_exposes_synthetic_due_date_sidecar(tmp_path: Path) -> None:
    dataset = load.load_dataset(make_backup(tmp_path, 7, include_due_date_override=True))

    assert dataset["settlement_due_date_overrides"] == [{
        "id": "override-1",
        "transactionID": "transaction-1",
        "dueDate": "2026-08-15T00:00:00Z",
        "lastModifiedAt": "2026-08-04T00:00:00Z",
    }]


def test_load_dataset_rejects_newer_schema_clearly(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="más reciente.*\\[4, 5, 6, 7\\]"):
        load.load_dataset(make_backup(tmp_path, 8))


def test_writeback_preserves_schema_seven_and_due_date_sidecar(tmp_path: Path) -> None:
    dataset = load.load_dataset(make_backup(tmp_path, 7, include_due_date_override=True))

    output = writeback.apply_recategorizations(
        dataset,
        [{"id": "transaction-1", "categoryId": None}],
        output_dir=tmp_path,
        now=datetime(2026, 8, 4, tzinfo=UTC),
    )

    assert json.loads((output / "manifest.json").read_text(encoding="utf-8"))["schemaVersion"] == 7
    assert json.loads((output / "models" / "SettlementDueDateOverride.json").read_text(encoding="utf-8")) == (
        dataset["settlement_due_date_overrides"]
    )


def test_writeback_rejects_unsupported_schema(tmp_path: Path) -> None:
    dataset = load.load_dataset(make_backup(tmp_path, 7))
    dataset["manifest"]["schemaVersion"] = 8

    with pytest.raises(writeback.WritebackError, match="schemaVersion=8"):
        writeback.apply_recategorizations(dataset, [{"id": "transaction-1", "categoryId": None}])
