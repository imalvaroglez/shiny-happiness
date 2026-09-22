"""Escritor del bundle .ftbackup (directorio con extensión). Estructura y
validación espejo de BackupArchive.swift: 11 modelos requeridos + el opcional
AccountBalanceSnapshot, manifest schemaVersion 7 con counts y sha256 reales."""

import hashlib
import json
from pathlib import Path

REQUIRED_MODELS = [
    "Account", "Statement", "Category", "CategoryRule", "InstallmentPlan",
    "PendingImport", "SignRecoveryHint", "StockPosition",
    "HouseholdPartnerIncomeEstimate", "SettlementDueDateOverride",
    "Transaction", "AccountBalanceSnapshot",
]

INFO_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>CFBundleIdentifier</key>
	<string>com.financeTracker.app.backup</string>
</dict>
</plist>
"""


def write_bundle(out_dir: Path, models_bytes: dict[str, bytes],
                 created_at: str, app_version: str) -> Path:
    """Escribe <out_dir>/ como bundle .ftbackup. out_dir ya debe llevar la
    extensión. Los modelos ausentes se escriben como []."""
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "Info.plist").write_text(INFO_PLIST, encoding="utf-8")
    models_dir = out_dir / "models"
    models_dir.mkdir(exist_ok=True)

    manifest_models = {}
    for name in REQUIRED_MODELS:
        payload = models_bytes.get(name, b"[]")
        (models_dir / f"{name}.json").write_bytes(payload)
        count = len(json.loads(payload))
        manifest_models[name] = {
            "count": count,
            "sha256": hashlib.sha256(payload).hexdigest(),
        }

    manifest = {
        "schemaVersion": 7,
        "createdAt": created_at,
        "appVersion": app_version,
        "modelCounts": {name: data["count"] for name, data in manifest_models.items()},
        "contentHashes": {name: data["sha256"] for name, data in manifest_models.items()},
    }
    (out_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8")
    return out_dir
