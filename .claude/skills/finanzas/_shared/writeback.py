"""Write-back — genera un .ftbackup modificado con reclasificaciones aprobadas.

REGLAS VERIFICADAS contra BackupArchive.restore (ver plan + exploración):
  - restore NO verifica contentHashes → podemos editar Transaction.json sin tocar manifest.
  - restore resuelve categoryId por UUID contra el Category.json del propio bundle → validar.
  - mergeKeepingNewer solo aplica escalares si snap.lastModifiedAt > existing.lastModifiedAt
    → BUMPAR lastModifiedAt SIEMPRE en filas editadas (la relación category se repunta
    igual, pero los *Raw no sin el bump).
  - Los campos movementKindRaw/treatmentKindRaw/householdScopeRaw se RE-DERIVAN si son nil
    al restaurar → dejarlos explícitos no-nil para que respeten la intención.
  - schemaVersion: dejarlo como está (4-6 aceptados). No inventar 7+.

ALCANCE LIMITADO A RECLASIFICAR: solo categoryId / flowKindRaw / treatmentKindRaw.
No crea CategoryRule, no soft-deleta, no toca isDuplicate/amount/postedAt.

USO:
    from writeback import apply_recategorizations
    changes = [{'id': '<uuid>', 'categoryId': '<new-cat-uuid>'}, ...]
    out = apply_recategorizations(ds, changes, output_dir)
    # out = ruta al nuevo .ftbackup que el usuario restaura manualmente
"""
from __future__ import annotations

import json
import shutil
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from typing import Any, Dict, List, Optional

ALLOWED_FIELDS = {"categoryId", "flowKindRaw", "treatmentKindRaw", "movementKindRaw"}
VALID_FLOW = {"income", "expense", "transfer", "charge", "cardCredit", "payment"}
VALID_TREATMENT = {
    "regular", "retirementContributionUserFunded", "retirementContributionEmployerFunded",
    "statutoryRetirementContribution", "investmentReturn", "fee", "valuationAdjustment",
}
VALID_MOVEMENT = {"income", "expense", "transfer", "adjustment"}


class WritebackError(Exception):
    pass


def _validate_change(change: Dict[str, Any], valid_cat_ids: set, valid_tx_ids: set) -> None:
    if "id" not in change:
        raise WritebackError(f"Cambio sin 'id': {change}")
    if change["id"] not in valid_tx_ids:
        raise WritebackError(f"Transaction id no encontrado: {change['id']}")
    for k, v in change.items():
        if k == "id":
            continue
        if k not in ALLOWED_FIELDS:
            raise WritebackError(f"Campo no permitido para reclasificar: '{k}'. "
                                 f"Permitidos: {ALLOWED_FIELDS}. "
                                 f"Esto incluye solo categoryId/flowKindRaw/treatmentKindRaw/movementKindRaw.")
        if k == "categoryId":
            if v is not None and v not in valid_cat_ids:
                raise WritebackError(f"categoryId destino no existe en Category.json: {v}")
        elif k == "flowKindRaw":
            if v is not None and v not in VALID_FLOW:
                raise WritebackError(f"flowKindRaw inválido: {v}. Válidos: {VALID_FLOW}")
        elif k == "treatmentKindRaw":
            if v is not None and v not in VALID_TREATMENT:
                raise WritebackError(f"treatmentKindRaw inválido: {v}. Válidos: {VALID_TREATMENT}")
        elif k == "movementKindRaw":
            if v is not None and v not in VALID_MOVEMENT:
                raise WritebackError(f"movementKindRaw inválido: {v}. Válidos: {VALID_MOVEMENT}")


def apply_recategorizations(
    ds: Dict[str, Any],
    changes: List[Dict[str, Any]],
    output_dir: Optional[Path] = None,
    now: Optional[datetime] = None,
) -> Path:
    """Genera un nuevo .ftbackup con las reclasificaciones aplicadas.

    Args:
      ds: dataset cargado por load.load_dataset()
      changes: [{'id': tx_uuid, 'categoryId': new_cat_uuid, ...opt flowKindRaw/treatmentKindRaw/movementKindRaw}]
      output_dir: dónde escribir el bundle (default: cwd)
      now: timestamp para lastModifiedAt (default: utcnow). Para tests inyectables.

    Devuelve la ruta al .ftbackup generado. NO restaura nada — el usuario lo hace manual.
    """
    if not changes:
        raise WritebackError("Sin cambios que aplicar.")

    now = now or datetime.now(timezone.utc)
    source_bundle: Path = ds["bundle"]
    valid_cat_ids = {c["id"] for c in ds["models"]["Category"]}
    valid_tx_ids = {t["id"] for t in ds["models"]["Transaction"]}

    for ch in changes:
        _validate_change(ch, valid_cat_ids, valid_tx_ids)

    # copiar el bundle íntegro (statements, otros modelos, Info.plist) — solo tocaremos Transaction.json
    stamp = now.strftime("%Y-%m-%dT%H-%M-%SZ")
    name = f"FinanceTracker-reclasificacion-{stamp}.ftbackup"
    out_dir = Path(output_dir) / name if output_dir else Path.cwd() / name
    if out_dir.exists():
        raise WritebackError(f"Ya existe {out_dir}")
    shutil.copytree(source_bundle, out_dir)

    # cargar Transaction.json del copia, aplicar cambios, escribir
    tx_path = out_dir / "models" / "Transaction.json"
    txs = json.loads(tx_path.read_text(encoding="utf-8"))
    change_map = {c["id"]: c for c in changes}
    applied = 0
    for t in txs:
        if t["id"] in change_map:
            ch = change_map[t["id"]]
            for field in ("categoryId", "flowKindRaw", "treatmentKindRaw", "movementKindRaw"):
                if field in ch:
                    t[field] = ch[field]
            # REGLA CRÍTICA: bump lastModifiedAt para que mergeKeepingNewer aplique los escalares
            t["lastModifiedAt"] = now.isoformat().replace("+00:00", "Z")
            applied += 1

    if applied != len(changes):
        raise WritebackError(f"Solo se aplicaron {applied} de {len(changes)} cambios (ids no encontrados en el bundle).")

    # preservar el formato de la app: sortedKeys + prettyPrinted
    tx_path.write_text(json.dumps(txs, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")
    return out_dir
