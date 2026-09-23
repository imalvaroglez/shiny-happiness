"""Validate a complete schema-7 backup using only references inside that bundle."""

import hashlib
import json
import math
import plistlib
import re
import sys
from datetime import datetime
from pathlib import Path

from ftbackup import REQUIRED_MODELS

DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
DATE_KEYS = {"periodStart", "periodEnd", "monthStart", "firstChargeDate", "date"}
MONEY_KEYS = {
    "creditLimit", "amount", "shares", "averageCost", "lastPrice", "userIncomeManualOverride",
    "customUserPercent", "customPartnerPercent", "customFerAmount", "fxRateToBase", "openingBalance",
    "closingBalance", "minimumPayment", "paymentForNoInterest", "interestCharged", "feesCharged",
    "ivaCharged", "originalAmount", "monthlyAmount", "ratePercent", "parsedAmount",
}
FLOW_KINDS = {"income", "expense", "transfer", "charge", "cardCredit", "payment"}


def check(bundle_dir: Path) -> list[str]:
    errors: list[str] = []
    def err(message: str) -> None:
        errors.append(message)

    try:
        manifest = json.loads((bundle_dir / "manifest.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"manifest is invalid: {exc}"]
    if not isinstance(manifest, dict):
        return ["manifest must be a JSON object"]
    if manifest.get("schemaVersion") != 7:
        err(f"schemaVersion != 7: {manifest.get('schemaVersion')}")
    if not isinstance(manifest.get("appVersion"), str) or not manifest["appVersion"]:
        err("manifest.appVersion is missing or invalid")
    created_at = manifest.get("createdAt")
    if not isinstance(created_at, str):
        err("manifest.createdAt is missing or invalid")
    else:
        try:
            datetime.strptime(created_at, "%Y-%m-%dT%H:%M:%SZ")
        except ValueError:
            err("manifest.createdAt is not UTC ISO-8601")
    try:
        info = plistlib.loads((bundle_dir / "Info.plist").read_bytes())
        if not isinstance(info, dict) or info.get("CFBundlePackageType") != "BNDL":
            err("Info.plist has an invalid bundle structure")
    except (OSError, ValueError, plistlib.InvalidFileException) as exc:
        err(f"Info.plist is missing or invalid: {exc}")
    counts, hashes = manifest.get("modelCounts"), manifest.get("contentHashes")
    if not isinstance(counts, dict):
        err("manifest.modelCounts must be an object")
        counts = {}
    if not isinstance(hashes, dict):
        err("manifest.contentHashes must be an object")
        hashes = {}

    data: dict[str, list] = {}
    for name in REQUIRED_MODELS:
        path = bundle_dir / "models" / f"{name}.json"
        try:
            payload = path.read_bytes()
            rows = json.loads(payload)
        except (OSError, json.JSONDecodeError) as exc:
            err(f"{name}.json invalid or missing: {exc}")
            continue
        if not isinstance(rows, list):
            err(f"{name}.json is not a top-level array")
            continue
        data[name] = rows
        if counts.get(name) != len(rows):
            err(f"modelCounts[{name}] does not match array length")
        if hashes.get(name) != hashlib.sha256(payload).hexdigest():
            err(f"contentHashes[{name}] does not match sha256")

    def walk_dates(obj, where: str) -> None:
        if isinstance(obj, dict):
            for key, value in obj.items():
                if key.endswith(("At", "Date", "date")) or key in DATE_KEYS:
                    if value is not None and not isinstance(value, str):
                        err(f"{where}: invalid date type {key}={value!r}")
                    elif isinstance(value, str) and not DATE_RE.fullmatch(value):
                        err(f"{where}: invalid date {key}={value!r}")
                    elif isinstance(value, str):
                        try:
                            datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
                        except ValueError:
                            err(f"{where}: impossible date {key}={value!r}")
                walk_dates(value, where)
        elif isinstance(obj, list):
            for index, item in enumerate(obj):
                walk_dates(item, f"{where}[{index}]")
    walk_dates(data, "bundle")

    def walk_money(obj, where: str) -> None:
        if isinstance(obj, dict):
            for key, value in obj.items():
                if key in MONEY_KEYS and value is not None:
                    if (not isinstance(value, (int, float)) or isinstance(value, bool)
                            or isinstance(value, float) and not math.isfinite(value)):
                        err(f"{where}: {key} is not a finite JSON number")
                walk_money(value, where)
        elif isinstance(obj, list):
            for index, item in enumerate(obj):
                walk_money(item, f"{where}[{index}]")
    walk_money(data, "bundle")

    ids: dict[str, set[str]] = {}
    for name in REQUIRED_MODELS:
        for index, row in enumerate(data.get(name, [])):
            if not isinstance(row, dict):
                err(f"{name}[{index}] is not an object")
                continue
            identifier = row.get("id")
            if not isinstance(identifier, str) or not identifier:
                err(f"{name}[{index}].id is missing or not a nonempty string")
                continue
            bucket = ids.setdefault(name, set())
            normalized_id = identifier.casefold()
            if normalized_id in bucket:
                err(f"duplicate id in {name}: {identifier}")
            bucket.add(normalized_id)

    account_by_id = {row["id"]: row for row in data.get("Account", [])
                     if isinstance(row, dict) and isinstance(row.get("id"), str)}
    account_ids = set(account_by_id)
    def ids_for(name: str) -> set[str]:
        return {row["id"] for row in data.get(name, [])
                if isinstance(row, dict) and isinstance(row.get("id"), str)}
    statement_ids = ids_for("Statement")
    category_ids = ids_for("Category")
    transaction_ids = ids_for("Transaction")
    plan_ids = ids_for("InstallmentPlan")

    def require_fk(rows: list, field: str, valid: set, model: str) -> None:
        for index, row in enumerate(rows):
            if not isinstance(row, dict):
                continue
            value = row.get(field)
            if value is not None and (not isinstance(value, str) or value not in valid):
                err(f"{model}[{index}].{field} points outside the full backup: {value}")

    for name, field in (("Statement", "accountId"), ("Transaction", "accountId"),
                        ("AccountBalanceSnapshot", "accountId"), ("StockPosition", "accountId"),
                        ("InstallmentPlan", "accountId"), ("PendingImport", "accountId")):
        require_fk(data.get(name, []), field, account_ids, name)
    require_fk(data.get("Transaction", []), "statementId", statement_ids, "Transaction")
    require_fk(data.get("Transaction", []), "categoryId", category_ids, "Transaction")
    require_fk(data.get("Transaction", []), "installmentPlanId", plan_ids, "Transaction")
    require_fk(data.get("Category", []), "parentId", category_ids, "Category")
    require_fk(data.get("CategoryRule", []), "categoryId", category_ids, "CategoryRule")
    require_fk(data.get("InstallmentPlan", []), "originalPurchaseId", transaction_ids, "InstallmentPlan")
    require_fk(data.get("PendingImport", []), "statementId", statement_ids, "PendingImport")
    require_fk(data.get("PendingImport", []), "resolvedTransactionId", transaction_ids, "PendingImport")
    require_fk(data.get("PendingImport", []), "matchedDeletedTransactionId", transaction_ids, "PendingImport")
    require_fk(data.get("SettlementDueDateOverride", []), "transactionID", transaction_ids,
               "SettlementDueDateOverride")
    for index, plan in enumerate(data.get("InstallmentPlan", [])):
        if not isinstance(plan, dict):
            continue
        installment_ids = plan.get("installmentsIds", [])
        if not isinstance(installment_ids, list):
            err(f"InstallmentPlan[{index}].installmentsIds is not an array")
            continue
        for tx_id in installment_ids:
            if not isinstance(tx_id, str) or tx_id not in transaction_ids:
                err(f"InstallmentPlan[{index}].installmentsIds references absent transaction {tx_id}")

    for index, tx in enumerate(data.get("Transaction", [])):
        if not isinstance(tx, dict):
            continue
        if tx.get("source") not in (None, "imported"):
            err(f"Transaction[{index}].source invalid: {tx.get('source')}")
        if tx.get("flowKindRaw") is not None and tx.get("flowKindRaw") not in FLOW_KINDS:
            err(f"Transaction[{index}].flowKindRaw invalid: {tx.get('flowKindRaw')}")
        if tx.get("householdScopeRaw") is not None and tx.get("householdScopeRaw") not in {"included", "excluded"}:
            err(f"Transaction[{index}].householdScopeRaw invalid: {tx.get('householdScopeRaw')}")
        amount = tx.get("amount")
        if (not isinstance(amount, (int, float)) or isinstance(amount, bool)
                or not math.isfinite(amount)):
            err(f"Transaction[{index}].amount is not a JSON number")

    for index, statement in enumerate(data.get("Statement", [])):
        if not isinstance(statement, dict):
            continue
        start, end = statement.get("periodStart"), statement.get("periodEnd")
        if not isinstance(start, str) or not isinstance(end, str):
            err(f"Statement[{index}] is missing periodStart or periodEnd")
        if not isinstance(statement.get("sourceFileHash"), str):
            err(f"Statement[{index}].sourceFileHash is missing or invalid")
        if isinstance(start, str) and isinstance(end, str):
            try:
                if datetime.strptime(start, "%Y-%m-%dT%H:%M:%SZ") > datetime.strptime(end, "%Y-%m-%dT%H:%M:%SZ"):
                    err(f"Statement[{index}].periodStart is after periodEnd")
            except ValueError:
                pass  # walk_dates already reports the malformed value.
        account_id = statement.get("accountId")
        account = account_by_id.get(account_id, {}) if isinstance(account_id, str) else {}
        closing_balance = statement.get("closingBalance")
        if closing_balance is not None and (
                not isinstance(closing_balance, (int, float)) or isinstance(closing_balance, bool)
                or not math.isfinite(closing_balance)):
            err(f"Statement[{index}].closingBalance is not a finite JSON number")
        elif account.get("type") == "creditCard" and closing_balance is not None:
            if closing_balance > 0:
                err(f"Statement[{index}].closingBalance must be signed-negative for a credit card")
        archived_path = statement.get("sourceArchivedPath")
        if archived_path:
            if not isinstance(archived_path, str):
                err(f"Statement[{index}].sourceArchivedPath is not a string")
                continue
            relative = archived_path.removeprefix("FinanceTracker/Statements/")
            resource = (bundle_dir / "statements" / relative).resolve()
            if (Path(relative).is_absolute() or ".." in Path(relative).parts
                    or not resource.is_relative_to((bundle_dir / "statements").resolve())
                    or not resource.is_file()):
                err(f"Statement[{index}] archived source is missing: {relative}")

    return errors


def main() -> int:
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle", type=Path)
    args = parser.parse_args()
    errors = check(args.bundle)
    if errors:
        print(f"SELFCHECK FAILED ({len(errors)} errors):")
        for error in errors[:30]:
            print(" -", error)
        return 1
    print("selfcheck OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
