"""Validador independiente del bundle generado. Sale no-cero al primer fallo.
Espejo de las reglas que BackupArchive.restore exige + invariantes del piloto."""

import hashlib
import json
import re
import sys
from datetime import datetime
from pathlib import Path

from ftbackup import REQUIRED_MODELS

DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
TX_REQUIRED = ["id", "accountId", "postedAt", "amount", "currency",
               "descriptionRaw", "merchantNormalized", "fxRateToBase",
               "isTransfer", "isDuplicate", "lastModifiedAt"]
FLOW_KINDS = {"income", "expense", "transfer", "charge", "cardCredit", "payment"}


def check(bundle_dir: Path, ref_models_dir: Path | None = None) -> list[str]:
    errors: list[str] = []

    def err(msg: str):
        errors.append(msg)

    # 1. Estructura, counts y hashes
    manifest = json.loads((bundle_dir / "manifest.json").read_text())
    if manifest.get("schemaVersion") != 7:
        err(f"schemaVersion != 7: {manifest.get('schemaVersion')}")
    data: dict[str, list] = {}
    for name in REQUIRED_MODELS:
        path = bundle_dir / "models" / f"{name}.json"
        if not path.exists():
            err(f"falta models/{name}.json")
            continue
        try:
            data[name] = json.loads(path.read_bytes())
        except json.JSONDecodeError as e:
            err(f"{name}.json no es JSON válido: {e}")
            continue
        if not isinstance(data[name], list):
            err(f"{name}.json no es array top-level")
            continue
        if manifest["modelCounts"].get(name) != len(data[name]):
            err(f"modelCounts[{name}] = {manifest['modelCounts'].get(name)} != {len(data[name])}")
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if manifest["contentHashes"].get(name) != digest:
            err(f"contentHashes[{name}] no coincide con sha256 del archivo")

    txs = data.get("Transaction", [])
    stmts = data.get("Statement", [])

    # 2. Fechas ISO8601 sin fracciones, en todos los modelos con fechas
    def walk_dates(obj, where: str):
        if isinstance(obj, dict):
            for key, value in obj.items():
                if key.endswith(("At", "Date", "date")) and isinstance(value, str):
                    if not DATE_RE.match(value):
                        err(f"{where}: fecha inválida '{key}': {value}")
                walk_dates(value, where)
        elif isinstance(obj, list):
            for i, item in enumerate(obj):
                walk_dates(item, f"{where}[{i}]")
    walk_dates({"Transaction": txs, "Statement": stmts}, "bundle")

    # 3. Campos requeridos y dominio de Transaction
    stmt_ids = {s["id"] for s in stmts}
    for i, tx in enumerate(txs):
        for field in TX_REQUIRED:
            if field not in tx:
                err(f"Transaction[{i}] sin campo requerido '{field}'")
        if tx.get("source") != "imported":
            err(f"Transaction[{i}].source != 'imported'")
        if not isinstance(tx.get("amount"), (int, float)):
            err(f"Transaction[{i}].amount no es número JSON")
        if tx.get("flowKindRaw") not in FLOW_KINDS:
            err(f"Transaction[{i}].flowKindRaw inválido: {tx.get('flowKindRaw')}")
        if tx.get("householdScopeRaw") != "excluded":
            err(f"Transaction[{i}].householdScopeRaw != 'excluded'")
        if tx.get("statementId") not in stmt_ids:
            err(f"Transaction[{i}].statementId no existe en el bundle")

    # 4. FKs contra bundle ∪ backup de referencia
    if ref_models_dir is not None and ref_models_dir.exists():
        ref_accounts = json.loads((ref_models_dir / "Account.json").read_text())
        ref_categories = json.loads((ref_models_dir / "Category.json").read_text())
        account_ids = {a["id"] for a in data.get("Account", [])} | {a["id"] for a in ref_accounts}
        category_ids = {c["id"] for c in ref_categories}
        for i, tx in enumerate(txs):
            if tx.get("accountId") not in account_ids:
                err(f"Transaction[{i}].accountId no existe en bundle ∪ referencia")
            if tx.get("categoryId") and tx["categoryId"] not in category_ids:
                err(f"Transaction[{i}].categoryId no existe en referencia")
        for i, stmt in enumerate(stmts):
            if stmt.get("accountId") not in account_ids:
                err(f"Statement[{i}].accountId no existe en bundle ∪ referencia")

    # 5. Cutoff: nada >= cutoff de la cuenta (min postedAt en la referencia)
    if ref_models_dir is not None and ref_models_dir.exists():
        ref_txs = json.loads((ref_models_dir / "Transaction.json").read_text())
        cutoff: dict[str, datetime] = {}
        for tx in ref_txs:
            if tx.get("deletedAt"):
                continue
            dt = datetime.fromisoformat(tx["postedAt"].replace("Z", "+00:00"))
            aid = tx["accountId"]
            if aid and (aid not in cutoff or dt < cutoff[aid]):
                cutoff[aid] = dt
        for i, tx in enumerate(txs):
            cut = cutoff.get(tx["accountId"])
            if cut and datetime.fromisoformat(tx["postedAt"].replace("Z", "+00:00")) >= cut:
                err(f"Transaction[{i}] postedAt {tx['postedAt']} >= cutoff {cut} de su cuenta")
        for i, stmt in enumerate(stmts):
            cut = cutoff.get(stmt["accountId"])
            if cut and datetime.fromisoformat(stmt["periodEnd"].replace("Z", "+00:00")) >= cut:
                err(f"Statement[{i}] periodEnd {stmt['periodEnd']} >= cutoff {cut} de su cuenta")

    # 6. Invariantes de TDC: closing negativo
    for i, stmt in enumerate(stmts):
        if stmt.get("closingBalance") is not None and stmt["closingBalance"] > 0:
            err(f"Statement[{i}].closingBalance positivo en tarjeta de crédito (AD-010)")

    # 7. Sin ids duplicados en el bundle
    seen: dict[str, set[str]] = {}
    for name in REQUIRED_MODELS:
        for row in data.get(name, []):
            if "id" in row:
                seen.setdefault(name, set())
                if row["id"] in seen[name]:
                    err(f"id duplicado en {name}: {row['id']}")
                seen[name].add(row["id"])

    return errors


def main() -> int:
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--backup", type=Path, default=None,
                        help="models/ del .ftbackup de referencia")
    args = parser.parse_args()
    ref = args.backup / "models" if args.backup else None
    errors = check(args.bundle, ref)
    if errors:
        print(f"SELFCHECK FALLÓ ({len(errors)} errores):")
        for e in errors[:30]:
            print(" -", e)
        return 1
    print("selfcheck OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
