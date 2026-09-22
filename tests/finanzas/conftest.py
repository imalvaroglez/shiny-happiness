"""Fixtures para tests de writeback/promo — bundles sintéticos con manifest estilo app.

Replica lo que BackupArchive.export escribe: manifest.json con schemaVersion,
contentHashes (SHA-256 hex de los bytes de cada models/*.json) y modelCounts.
Nunca se commitea un .ftbackup real (PII); todo es fabricado aquí.
"""
from __future__ import annotations

import hashlib
import json
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import pytest

SKILL_DIR = Path(__file__).resolve().parents[2] / ".claude" / "skills" / "finanzas"
# OJO: solo _shared va al sys.path global (load/writeback/accounting_gates son únicos).
# NO agregar habits/scripts ni wealth/scripts: ambos tienen un aggregate.py y se
# sombrearían entre sí. promo se carga por ruta explícita donde se usa.
if str(SKILL_DIR / "_shared") not in sys.path:
    sys.path.insert(0, str(SKILL_DIR / "_shared"))

NOW = datetime(2026, 9, 22, 0, 0, tzinfo=UTC)
NOW_ISO = "2026-09-22T00:00:00Z"


def load_module_by_path(name: str, path: Path):
    """Importa un módulo por archivo (evita colisiones de nombre entre sub-skills)."""
    import importlib.util
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclasses lo necesita para resolver __module__
    spec.loader.exec_module(module)
    return module

# Categorías sintéticas (árboles paralelos como en el bundle real)
CATS = {
    "ROOT-FEES": {"id": "ROOT-FEES", "name": "Fees & Charges", "parentId": None, "kind": "expense", "deletedAt": None},
    "BANK-FEES": {"id": "BANK-FEES", "name": "Bank Fees", "parentId": "ROOT-FEES", "kind": "expense", "deletedAt": None},
    "CC-PAY": {"id": "CC-PAY", "name": "Credit Card Payments", "parentId": None, "kind": "creditCardPayment", "deletedAt": None},
    "GM": {"id": "GM", "name": "General Merchandise", "parentId": None, "kind": "expense", "deletedAt": None},
    "SHOPPING": {"id": "SHOPPING", "name": "Shopping", "parentId": None, "kind": "expense", "deletedAt": None},
    "MSI": {"id": "MSI", "name": "MSI Installments", "parentId": None, "kind": "expense", "deletedAt": None},
    "INTERNAL-TR": {"id": "INTERNAL-TR", "name": "Internal Transfer", "parentId": None, "kind": "transfer", "deletedAt": None},
    "ELECTRONICS": {"id": "ELECTRONICS", "name": "Electronics", "parentId": None, "kind": "expense", "deletedAt": None},
}

AMEX = "AMEX-PLATINUM"


def _write_models(bundle: Path, models: dict[str, list[dict[str, Any]]], extra_model_files: dict[str, str] | None = None) -> None:
    """Escribe models/*.json y devuelve nada; el manifest se calcula sobre los bytes reales."""
    models_dir = bundle / "models"
    models_dir.mkdir(parents=True, exist_ok=True)
    for name, rows in models.items():
        (models_dir / f"{name}.json").write_text(
            json.dumps(rows, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8"
        )
    for name, text in (extra_model_files or {}).items():
        (models_dir / f"{name}.json").write_text(text, encoding="utf-8")


def _finalize_manifest(bundle: Path, schema: int = 7) -> None:
    """Replica BackupArchive.export: contentHashes = SHA-256 hex del archivo, modelCounts = len."""
    models_dir = bundle / "models"
    hashes: dict[str, str] = {}
    counts: dict[str, int] = {}
    for p in sorted(models_dir.glob("*.json")):
        data = p.read_bytes()
        hashes[p.stem] = hashlib.sha256(data).hexdigest()
        counts[p.stem] = len(json.loads(data))
    (bundle / "manifest.json").write_text(
        json.dumps(
            {"schemaVersion": schema, "appVersion": "test", "createdAt": NOW_ISO,
             "contentHashes": hashes, "modelCounts": counts},
            ensure_ascii=False, indent=2, sort_keys=True,
        ),
        encoding="utf-8",
    )


def tx(tx_id: str, amount: str, posted_at: str, description: str, category_id: str | None = "BANK-FEES",
       **extra: Any) -> dict[str, Any]:
    row = {
        "id": tx_id, "accountId": AMEX, "amount": float(amount), "postedAt": posted_at,
        "descriptionRaw": description, "categoryId": category_id, "deletedAt": None,
        "isDuplicate": False, "isTransfer": False, "lastModifiedAt": NOW_ISO,
    }
    row.update(extra)
    return row


@pytest.fixture
def bundle(tmp_path: Path) -> Path:
    """Bundle sintético con manifest estilo app (hashes/counts válidos) + reglas existentes."""
    models = {
        "Account": [{"id": AMEX, "type": "creditCard", "nickname": "The Platinum Credit Card",
                     "institution": "American Express Mexico", "currency": "MXN",
                     "includeInCashFlow": True, "includeInRegularIncome": True, "lastModifiedAt": NOW_ISO}],
        "Category": list(CATS.values()),
        "Transaction": [
            tx("TX-MSI-CREDIT", "30055.12", "2026-09-11T06:00:00Z", "MESES EN AUTOMÁTICO"),
            tx("TX-MSI-1", "-10018.38", "2026-09-11T06:00:00Z", "MSI 1/3"),
            tx("TX-NORMAL", "-31674.00", "2026-09-15T06:00:00Z", "AEROMEXICO", category_id="GM"),
            tx("TX-OLD", "-9999.20", "2026-08-24T06:00:00Z", "Breville The Barista Express", category_id="GM"),
        ],
        "CategoryRule": [
            {"id": "RULE-MONTO", "patternRegex": "(?i)MONTO", "merchantMatch": "", "categoryId": "CC-PAY",
             "priority": 100, "source": "user_correction", "matchCount": 0, "createdFrom": "app",
             "lastModifiedAt": NOW_ISO},
            {"id": "RULE-AMAZON", "patternRegex": "(?i)AMAZON|AMZN", "merchantMatch": "Amazon",
             "categoryId": "SHOPPING", "priority": 10, "source": "seed", "matchCount": 0,
             "createdFrom": None, "lastModifiedAt": NOW_ISO},
        ],
        # requeridos por isValidBundle (requiredModelNames)
        "Statement": [], "InstallmentPlan": [], "PendingImport": [], "SignRecoveryHint": [],
        "StockPosition": [], "HouseholdPartnerIncomeEstimate": [], "SettlementDueDateOverride": [],
        "AccountBalanceSnapshot": [],
    }
    b = tmp_path / "synthetic.ftbackup"
    _write_models(b, models)
    _finalize_manifest(b)
    return b
