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
    # Exports manuales del usuario (lo más fresco típicamente; la app escribe aquí
    # cuando el usuario hace Export). Se busca PRIMERO por mtime.
    Path.home() / "Documents/finanzas/FinanceTracker",
    # Backups automáticos del contenedor de producción.
    Path.home() / "Library/Containers/com.financeTracker.app/Data/Library/Application Support/FinanceTracker/Backups",
    # Dev / testing (suelen estar vacíos o con datos de prueba).
    Path.home() / "Library/Containers/com.financeTracker.app.dev/Data/Library/Application Support/FinanceTracker/Backups",
]

# Antigüedad (horas) a partir de la cual load_dataset avisa que el dato podría estar desfasado
# respecto a la app en vivo. Solo advisory; no bloquea.
STALE_AFTER_HOURS = 24


def _is_dev_or_testing(p: Path) -> bool:
    return ("com.financeTracker.app.dev" in str(p)) or ("com.financeTracker.app.testing" in str(p))


def _mtime(p: Path) -> datetime:
    """mtime del bundle como datetime tz-aware (UTC)."""
    return datetime.fromtimestamp(p.stat().st_mtime, tz=timezone.utc)


def latest_backup() -> Path:
    """El .ftbackup más reciente CON DATOS REALES, buscando en TODAS las ubicaciones
    conocidas y comparando mtime real (no el nombre del archivo).

    Orden de preferencia ante empate de mtime: prod > dev/testing.
    Antes se miraba solo el contenedor y se ordenaba por nombre — eso hacía que un
    export manual fresco en ~/Documents se ignorara. Ahora gana el genuinamente más fresco.
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

    # De-priorizar dev/testing: mismo mtime → prod gana. La clave de orden es
    # (mtime asc, es_dev asc); max() se queda con el mayor → mtime más alto, y entre
    # iguales, prod (False=0) pierde ante dev (True=1)... así que invertimos: queremos
    # que prod gane en empate → clave (mtime, NO es_dev) para que prod(1) > dev(0).
    def sort_key(p: Path):
        return (_mtime(p), 0 if _is_dev_or_testing(p) else 1)

    with_data = [p for p in candidates if tx_count(p) > 0]
    pool = with_data if with_data else candidates
    return max(pool, key=sort_key)


def _stale_note(bundle: Path) -> str:
    """Mensaje advisory si el bundle cargado pasa de STALE_AFTER_HOURS."""
    age_h = (datetime.now(timezone.utc) - _mtime(bundle)).total_seconds() / 3600
    if age_h > STALE_AFTER_HOURS:
        return (f"⚠️ Este bundle tiene {age_h:.0f}h de antigüedad (mtime {bundle.name}). "
                "Los backups automáticos de la app pueden estar estancados; para datos al "
                "día, exporta uno fresco (Settings → Backup & Data → Export backup).")
    return ""


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
    bundle = ds["bundle"]
    lines.append(f"📦 {bundle.name}")
    lines.append(f"   origen: {bundle.parent}  ·  mtime {_mtime(bundle).strftime('%Y-%m-%d %H:%M UTC')}")
    lines.append(f"   schemaVersion={m.get('schemaVersion')}  appVersion={m.get('appVersion')}  "
                 f"createdAt={m.get('createdAt')}")
    stale = _stale_note(bundle)
    if stale:
        lines.append(f"   {stale}")
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
