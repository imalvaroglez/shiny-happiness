"""Carga el .ftbackup más reciente (o uno indicado) en memoria.

Uso:
    python3 load.py                      # último backup automático de la app de producción
    python3 load.py /path/to/X.ftbackup  # un bundle específico

Devuelve (a stdout, para que Claude lo lea) un resumen: conteos, cuentas con saldos,
rango temporal. Las sub-skills importan load_dataset() para obtener los dicts.
"""
from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from typing import Any, Dict, List, Optional

SUPPORTED_SCHEMA = {4, 5, 6}

# Mismas ubicaciones que StoreFileResetService / BackupScheduler.
DEFAULT_BACKUP_DIRS = [
    Path.home() / "Library/Containers/com.financeTracker.app/Data/Library/Application Support/FinanceTracker/Backups",
    Path.home() / "Library/Containers/com.financeTracker.app.dev/Data/Library/Application Support/FinanceTracker/Backups",
]


def latest_backup() -> Path:
    """El .ftbackup más reciente CON DATOS REALES.

    Hay varios containers (app=producción, app.dev, app.testing). Los de dev/testing
    suelen estar vacíos. Entre todos los bundles, tomamos el más reciente cuyo
    Transaction.json tenga filas, prefiriendo producción si hay empate de timestamp.
    """
    candidates: List[Path] = []
    for d in DEFAULT_BACKUP_DIRS:
        if d.is_dir():
            candidates.extend(p for p in d.iterdir() if p.suffix == ".ftbackup")
    if not candidates:
        raise FileNotFoundError(
            "No se encontró ningún .ftbackup. Exporta uno desde la app "
            "(Settings → Backup & Data → Export backup) o indica la ruta."
        )

    def tx_count(p: Path) -> int:
        f = p / "models" / "Transaction.json"
        if not f.exists():
            return 0
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
            return len(data) if isinstance(data, list) else 0
        except (json.JSONDecodeError, ValueError):
            return 0

    # ordenar: producción primero, luego por timestamp descendente
    prod_first = sorted(
        candidates,
        key=lambda p: ("com.financeTracker.app.dev" in str(p) or "com.financeTracker.app.testing" in str(p), p.name),
        reverse=False,  # prod (False) antes que dev/testing (True)
    )
    # entre los que tienen datos, el más reciente
    with_data = [p for p in candidates if tx_count(p) > 0]
    if with_data:
        return max(with_data, key=lambda p: p.name)
    # sin datos en ningún bundle → el más reciente de producción, o el último absoluto
    prod = [p for p in candidates if "com.financeTracker.app" in str(p)
            and "dev" not in str(p) and "testing" not in str(p)]
    if prod:
        return max(prod, key=lambda p: p.name)
    return max(candidates, key=lambda p: p.name)


def _parse_iso(s: str) -> Optional[datetime]:
    if not s:
        return None
    try:
        # ISO8601 con o sin Z
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def _load_model(bundle: Path, name: str) -> List[Dict[str, Any]]:
    p = bundle / "models" / f"{name}.json"
    if not p.exists():
        return []
    with open(p, encoding="utf-8") as f:
        data = json.load(f)
    return data if isinstance(data, list) else []


def load_dataset(bundle: Optional[Path] = None) -> Dict[str, Any]:
    """Carga todo el bundle en dicts planos + índices por UUID."""
    bundle = bundle or latest_backup()
    manifest_path = bundle / "manifest.json"
    if not manifest_path.exists():
        raise FileNotFoundError(f"{bundle} no tiene manifest.json — ¿es un .ftbackup válido?")

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    schema = manifest.get("schemaVersion")
    if schema not in SUPPORTED_SCHEMA:
        raise ValueError(
            f"schemaVersion={schema} no soportado. El skill acepta {sorted(SUPPORTED_SCHEMA)}. "
            "Exporta un backup nuevo desde la app actual."
        )

    models = {name: _load_model(bundle, name) for name in (
        "Account", "AccountBalanceSnapshot", "Category", "CategoryRule",
        "HouseholdPartnerIncomeEstimate", "InstallmentPlan", "PendingImport",
        "SignRecoveryHint", "Statement", "StockPosition", "Transaction",
    )}

    accounts = {a["id"]: a for a in models["Account"]}
    categories = {c["id"]: c for c in models["Category"]}
    plans = {p["id"]: p for p in models["InstallmentPlan"]}

    return {
        "bundle": bundle,
        "manifest": manifest,
        "models": models,
        "accounts": accounts,
        "categories": categories,
        "plans": plans,
        "transactions": models["Transaction"],
        "statements": models["Statement"],
        "snapshots": models["AccountBalanceSnapshot"],
        "positions": models["StockPosition"],
        "rules": models["CategoryRule"],
    }


def live_transactions(ds: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Transacciones no soft-deleted (la app filtra deletedAt == nil)."""
    return [t for t in ds["transactions"] if t.get("deletedAt") is None]


def date_span(txs: List[Dict[str, Any]]) -> Optional[tuple]:
    dates = sorted(t["postedAt"] for t in txs if t.get("postedAt"))
    if not dates:
        return None
    return (dates[0], dates[-1])


def summarize(ds: Dict[str, Any]) -> str:
    m = ds["manifest"]
    live = live_transactions(ds)
    span = date_span(live)

    lines = []
    lines.append(f"📦 {ds['bundle'].name}")
    lines.append(f"   schemaVersion={m.get('schemaVersion')}  appVersion={m.get('appVersion')}  "
                 f"createdAt={m.get('createdAt')}")
    lines.append(f"   transacciones vivas: {len(live)} / {len(ds['transactions'])} "
                 f"(soft-deleted: {len(ds['transactions']) - len(live)})")
    if span:
        lines.append(f"   rango temporal: {span[0]} → {span[1]}")
    lines.append(f"   cuentas: {len(ds['accounts'])}  categorías: {len(ds['categories'])}  "
                 f"estados: {len(ds['statements'])}  posiciones: {len(ds['positions'])}  "
                 f"snapshots: {len(ds['snapshots'])}  planes MSI: {len(ds['plans'])}")

    lines.append("")
    lines.append("   Cuentas:")
    for a in sorted(ds["models"]["Account"], key=lambda x: (x.get("type", ""), x.get("institution", ""))):
        nick = a.get("nickname") or a.get("institution")
        lines.append(f"     • {a.get('type','?'):11s} {a.get('institution',''):24s} "
                     f"({a.get('currency','?')})  {nick}")
    return "\n".join(lines)


def main(argv: List[str]) -> int:
    bundle = Path(argv[1]) if len(argv) > 1 else None
    ds = load_dataset(bundle)
    print(summarize(ds))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
