"""Write-back — genera un .ftbackup modificado con reclasificaciones aprobadas.

REGLAS VERIFICADAS contra BackupArchive (ver plan + exploración):
  - La UI real de restore pasa por summary(at:) → isValidBundle, que compara
    contentHashes (SHA-256 hex por modelo) y modelCounts → tras reescribir cualquier
    models/*.json hay que refrescar esas entradas del manifest (_recompute_manifest_entries).
  - restore resuelve categoryId por UUID contra el Category.json del propio bundle → validar.
  - mergeKeepingNewer solo aplica escalares si snap.lastModifiedAt > existing.lastModifiedAt
    → BUMPAR lastModifiedAt SIEMPRE en filas editadas (la relación category se repunta
    igual, pero los *Raw no sin el bump).
  - Los campos movementKindRaw/treatmentKindRaw/householdScopeRaw se RE-DERIVAN si son nil
    al restaurar → dejarlos explícitos no-nil para que respeten la intención.
  - CategoryRule con id NUEVO se inserta sin colisión (BackupArchive.swift:349-360);
    por eso apply_writeback también puede appendear reglas nuevas.
  - schemaVersion: dejarlo como está (4-7 aceptados). No inventar uno nuevo.

ALCANCE: reclasificar transacciones (categoryId / flowKindRaw / treatmentKindRaw /
movementKindRaw) y crear CategoryRule nuevas (con aprobación explícita del usuario).
No soft-deleta, no toca isDuplicate/amount/postedAt/descriptions.

USO:
    from writeback import apply_recategorizations, apply_category_rules, apply_writeback
    out = apply_recategorizations(ds, [{'id': '<uuid>', 'categoryId': '<cat-uuid>'}])
    out = apply_category_rules(ds, [{'patternRegex': '(?i)…', 'categoryId': '<cat-uuid>',
                                     'priority': 106}])
    out = apply_writeback(ds, changes=[...], rules=[...])  # ambos en un mismo bundle
"""
from __future__ import annotations

import hashlib
import json
import re
import shutil
import uuid as uuid_lib
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from load import SUPPORTED_SCHEMA

ALLOWED_FIELDS = {"categoryId", "flowKindRaw", "treatmentKindRaw", "movementKindRaw"}
VALID_FLOW = {"income", "expense", "transfer", "charge", "cardCredit", "payment"}
VALID_TREATMENT = {
    "regular", "retirementContributionUserFunded", "retirementContributionEmployerFunded",
    "statutoryRetirementContribution", "investmentReturn", "fee", "valuationAdjustment",
}
VALID_MOVEMENT = {"income", "expense", "transfer", "adjustment"}

# CategoryRuleSnapshot (BackupModels.swift:151-161): id, patternRegex, merchantMatch,
# categoryId?, priority, source, matchCount, createdFrom?, lastModifiedAt.
ALLOWED_RULE_FIELDS = {"patternRegex", "categoryId", "priority", "merchantMatch", "source", "createdFrom"}
RULE_DEFAULT_SOURCE = "user_correction"
RULE_DEFAULT_CREATED_FROM = "skill:msi-convention"

# CategorySnapshot (BackupModels.swift:142-149): id, name, parentId?, kind, deletedAt?, lastModifiedAt.
ALLOWED_CATEGORY_FIELDS = {"id", "name", "parentId", "kind"}
VALID_CATEGORY_KINDS = {"income", "expense", "transfer", "investment", "creditCardPayment"}


class WritebackError(Exception):
    pass


def _iso(now: datetime) -> str:
    return now.isoformat().replace("+00:00", "Z")


def _validate_dataset_schema(ds: dict[str, Any]) -> None:
    schema = ds.get("manifest", {}).get("schemaVersion")
    if schema not in SUPPORTED_SCHEMA:
        raise WritebackError(
            f"schemaVersion={schema} no soportado para write-back. "
            f"El skill acepta {sorted(SUPPORTED_SCHEMA)} y preserva el manifest original."
        )


def _validate_change(change: dict[str, Any], valid_cat_ids: set, valid_tx_ids: set) -> None:
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


def _validate_rules(
    rules: list[dict[str, Any]],
    valid_cat_ids: set,
    deleted_cat_ids: set,
    existing_rules: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Valida specs de reglas y devuelve solo las NUEVAS (dedup por patternRegex+categoryId,
    igual que LearningHooks). Re-aplicar las mismas reglas es no-op, no error."""
    existing_pairs = {(r.get("patternRegex"), r.get("categoryId")) for r in existing_rules}
    fresh: list[dict[str, Any]] = []
    seen: set = set()
    for rule in rules:
        pattern = rule.get("patternRegex")
        if not pattern or not isinstance(pattern, str):
            raise WritebackError(f"Regla sin 'patternRegex' (string no vacío): {rule}")
        try:
            re.compile(pattern)
        except re.error as exc:
            raise WritebackError(f"patternRegex no compila: {pattern!r} ({exc})") from exc
        cat = rule.get("categoryId")
        if not cat or cat not in valid_cat_ids:
            raise WritebackError(f"categoryId destino no existe en Category.json: {cat}")
        if cat in deleted_cat_ids:
            raise WritebackError(f"categoryId destino está soft-deleted: {cat}")
        if not isinstance(rule.get("priority"), int):
            raise WritebackError(f"priority debe ser Int: {rule}")
        unknown = set(rule.keys()) - ALLOWED_RULE_FIELDS
        if unknown:
            raise WritebackError(f"Campos no permitidos en regla: {sorted(unknown)}. "
                                 f"Permitidos: {sorted(ALLOWED_RULE_FIELDS)}.")
        pair = (pattern, cat)
        if pair in existing_pairs or pair in seen:
            continue  # dedup silencioso (no-op), misma semántica que LearningHooks
        seen.add(pair)
        fresh.append(rule)
    return fresh


def _validate_new_categories(
    new_categories: list[dict[str, Any]],
    existing_categories: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Valida specs de categorías nuevas y devuelve solo las NUEVAS (dedup por name+parentId)."""
    existing_by_pair = {(c.get("name"), c.get("parentId")): c["id"] for c in existing_categories}
    fresh: list[dict[str, Any]] = []
    seen: set = set()
    for spec in new_categories:
        name = spec.get("name")
        if not name or not isinstance(name, str):
            raise WritebackError(f"Categoría nueva sin 'name' (string no vacío): {spec}")
        kind = spec.get("kind", "expense")
        if kind not in VALID_CATEGORY_KINDS:
            raise WritebackError(f"kind inválido para categoría nueva: {kind}. Válidos: {VALID_CATEGORY_KINDS}")
        unknown = set(spec.keys()) - ALLOWED_CATEGORY_FIELDS
        if unknown:
            raise WritebackError(f"Campos no permitidos en categoría nueva: {sorted(unknown)}. "
                                 f"Permitidos: {sorted(ALLOWED_CATEGORY_FIELDS)}.")
        parent = spec.get("parentId")
        if parent is not None and parent not in {c["id"] for c in existing_categories}:
            raise WritebackError(f"parentId no existe en Category.json: {parent} — la categoría "
                                 f"aterrizaría en raíz sin aviso al restaurar.")
        pair = (name, spec.get("parentId"))
        if pair in seen:
            continue
        existing_id = existing_by_pair.get(pair)
        if existing_id is not None:
            if spec.get("id") and spec["id"] != existing_id:
                raise WritebackError(
                    f"Ya existe '{name}' bajo ese padre (id {existing_id}) con otro id "
                    f"que el que pides crear ({spec['id']}) — referencia ambigua."
                )
            continue  # ya existe con ese nombre bajo ese padre → no-op
        seen.add(pair)
        fresh.append(spec)
    return fresh


def _recompute_manifest_entries(out_dir: Path, touched_models: list[str]) -> None:
    """Refresca contentHashes/modelCounts del manifest para los modelos reescritos.

    Réplica de lo que isValidBundle verifica (BackupArchive.swift:53-70): SHA-256 hex
    de los bytes finales de cada models/<name>.json y conteo de filas. Sin esto, la
    UI de restore rechaza el bundle aunque BackupArchive.restore() en sí no valide.
    """
    manifest_path = out_dir / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    hashes = manifest.setdefault("contentHashes", {})
    counts = manifest.setdefault("modelCounts", {})
    for name in touched_models:
        data = (out_dir / "models" / f"{name}.json").read_bytes()
        hashes[name] = hashlib.sha256(data).hexdigest()
        counts[name] = len(json.loads(data))
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8"
    )


def apply_writeback(
    ds: dict[str, Any],
    changes: list[dict[str, Any]] | None = None,
    rules: list[dict[str, Any]] | None = None,
    new_categories: list[dict[str, Any]] | None = None,
    output_dir: Path | None = None,
    now: datetime | None = None,
    label: str = "reclasificacion",
) -> Path:
    """Genera un nuevo .ftbackup con reclasificaciones, CategoryRule y/o categorías nuevas.

    Args:
      ds: dataset cargado por load.load_dataset()
      changes: [{'id': tx_uuid, 'categoryId': new_cat_uuid, ...opt *Raw}]
      rules: [{'patternRegex': regex, 'categoryId': cat_uuid, 'priority': int, ...opt}]
      new_categories: [{'name': str, 'kind': kind, 'parentId'?: uuid, 'id'?: uuid}] —
        el id explícito permite que changes/rules ya lo referencien.
      output_dir: dónde escribir el bundle (default: cwd)
      now: timestamp para lastModifiedAt (default: utcnow). Para tests inyectables.
      label: sufijo del nombre del bundle (default conserva el histórico).

    Devuelve la ruta al .ftbackup generado. NO restaura nada — el usuario lo hace manual.
    """
    changes = list(changes or [])
    rules = list(rules or [])
    new_categories = list(new_categories or [])
    if not (changes or rules or new_categories):
        raise WritebackError("Sin cambios que aplicar.")

    now = now or datetime.now(UTC)
    _validate_dataset_schema(ds)
    source_bundle: Path = ds["bundle"]
    categories = ds["models"]["Category"]
    fresh_categories = _validate_new_categories(new_categories, categories)
    # las categorías nuevas cuentan como ids válidos para changes y rules del MISMO bundle
    valid_cat_ids = {c["id"] for c in categories} | {c["id"] for c in fresh_categories if c.get("id")}
    deleted_cat_ids = {c["id"] for c in categories if c.get("deletedAt")}
    valid_tx_ids = {t["id"] for t in ds["models"]["Transaction"]}
    existing_rules = ds["models"].get("CategoryRule", [])

    for ch in changes:
        _validate_change(ch, valid_cat_ids, valid_tx_ids)
    fresh_rules = _validate_rules(rules, valid_cat_ids, deleted_cat_ids, existing_rules)

    # copiar el bundle íntegro (statements, otros modelos, Info.plist)
    stamp = now.strftime("%Y-%m-%dT%H-%M-%SZ")
    name = f"FinanceTracker-{label}-{stamp}.ftbackup"
    out_dir = Path(output_dir) / name if output_dir else Path.cwd() / name
    if out_dir.exists():
        raise WritebackError(f"Ya existe {out_dir}")
    shutil.copytree(source_bundle, out_dir)

    touched: list[str] = []

    # 1) reclasificaciones sobre Transaction.json
    if changes:
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
                t["lastModifiedAt"] = _iso(now)
                applied += 1
        if applied != len(changes):
            raise WritebackError(
                f"Solo se aplicaron {applied} de {len(changes)} cambios (ids no encontrados en el bundle)."
            )
        # preservar el formato de la app: sortedKeys + prettyPrinted
        tx_path.write_text(json.dumps(txs, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")
        touched.append("Transaction")

    # 1b) categorías nuevas (shape CategorySnapshot: id, name, parentId?, kind, deletedAt?, lastModifiedAt)
    if fresh_categories:
        cat_path = out_dir / "models" / "Category.json"
        cat_rows = json.loads(cat_path.read_text(encoding="utf-8"))
        for spec in fresh_categories:
            cat_rows.append({
                "id": spec.get("id") or str(uuid_lib.uuid4()).upper(),
                "name": spec["name"],
                "parentId": spec.get("parentId"),
                "kind": spec.get("kind", "expense"),
                "deletedAt": None,
                "lastModifiedAt": _iso(now),
            })
        cat_path.write_text(json.dumps(cat_rows, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")
        touched.append("Category")

    # 2) CategoryRule nuevas (shape CategoryRuleSnapshot)
    if fresh_rules:
        rules_path = out_dir / "models" / "CategoryRule.json"
        rows = json.loads(rules_path.read_text(encoding="utf-8"))
        for spec in fresh_rules:
            rows.append({
                "id": str(uuid_lib.uuid4()).upper(),
                "patternRegex": spec["patternRegex"],
                "merchantMatch": spec.get("merchantMatch", ""),
                "categoryId": spec["categoryId"],
                "priority": spec["priority"],
                "source": spec.get("source", RULE_DEFAULT_SOURCE),
                "matchCount": 0,
                "createdFrom": spec.get("createdFrom", RULE_DEFAULT_CREATED_FROM),
                "lastModifiedAt": _iso(now),
            })
        rules_path.write_text(json.dumps(rows, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")
        touched.append("CategoryRule")

    # 3) manifest: hashes/counts de los modelos tocados (isValidBundle los verifica)
    if touched:
        _recompute_manifest_entries(out_dir, touched)
    return out_dir


def apply_recategorizations(
    ds: dict[str, Any],
    changes: list[dict[str, Any]],
    output_dir: Path | None = None,
    now: datetime | None = None,
) -> Path:
    """Back-compat: solo reclasificaciones de Transaction."""
    return apply_writeback(ds, changes=changes, output_dir=output_dir, now=now)


def apply_category_rules(
    ds: dict[str, Any],
    rules: list[dict[str, Any]],
    output_dir: Path | None = None,
    now: datetime | None = None,
) -> Path:
    """Solo CategoryRule nuevas (dedup incluido)."""
    return apply_writeback(ds, rules=rules, output_dir=output_dir, now=now)
