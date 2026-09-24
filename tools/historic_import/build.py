"""Merge Amex historical statements into a complete schema-7 reference backup."""

import argparse
import json
import sys
import tempfile
import uuid
from datetime import UTC, datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import amex
import categorize
import extract
import ftbackup
import models
import selfcheck

PILOTS = {
    "amex": {
        "subdir": "amex/gold-elite-cc/Estados de cuenta",
        "parse": amex.parse_pdf,
        "account_match": ("American Express Mexico", "creditCard"),
    },
}


def _iso_day(value: str | None) -> str:
    return value[:10] if value else ""


def _write_report(path: Path, report: list[dict]) -> None:
    payload = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    path.write_text(payload, encoding="utf-8")


def _ensure_separate_paths(out: Path, report: Path, source: Path, reference: Path) -> None:
    out_path = out.resolve()
    report_path = report.resolve()
    source_path = source.resolve()
    reference_path = reference.resolve()
    if out_path == reference_path or reference_path in out_path.parents or out_path in reference_path.parents:
        raise ValueError("--out cannot equal, contain, or be inside the reference backup")
    if out_path == source_path or source_path in out_path.parents or out_path in source_path.parents:
        raise ValueError("--out must be outside the PDF source tree")
    if report_path == reference_path or reference_path in report_path.parents:
        raise ValueError("report cannot be inside the reference backup")
    if report_path == source_path or source_path in report_path.parents:
        raise ValueError("report cannot be inside the PDF source tree")


def load_reference(backup_dir: Path, account_id: str, pilot: dict) -> dict:
    manifest = ftbackup.validate_reference(backup_dir)
    errors = selfcheck.check(backup_dir)
    if errors:
        raise ValueError("reference backup selfcheck failed: " + "; ".join(errors[:12]))
    models_dir = backup_dir / "models"
    model_bytes = {name: (models_dir / f"{name}.json").read_bytes() for name in ftbackup.REQUIRED_MODELS}
    data = {name: json.loads(payload) for name, payload in model_bytes.items()}
    try:
        requested = str(uuid.UUID(account_id)).casefold()
    except ValueError as exc:
        raise ValueError("--account-id must be a valid UUID") from exc
    matches = [row for row in data["Account"] if str(row.get("id", "")).casefold() == requested]
    if len(matches) != 1:
        raise ValueError("--account-id must identify exactly one account in the reference")
    account = matches[0]
    if (account.get("institution"), account.get("type")) != pilot["account_match"]:
        raise ValueError(f"account must match {pilot['account_match']} for this import pilot")

    cutoff: str | None = None
    for tx in data["Transaction"]:
        tx_account = tx.get("accountId")
        if (not isinstance(tx_account, str) or tx_account.casefold() != str(account["id"]).casefold()
                or tx.get("deletedAt")):
            continue
        posted = tx.get("postedAt", "")
        if posted and (cutoff is None or posted < cutoff):
            cutoff = posted

    statement_hashes: dict[str, set[str]] = {}
    statement_periods: list[tuple[str, str, str, str]] = []
    for statement in data["Statement"]:
        aid = statement.get("accountId")
        source_hash = statement.get("sourceFileHash")
        if source_hash:
            statement_hashes.setdefault(source_hash, set()).add(str(aid).casefold())
        start, end = _iso_day(statement.get("periodStart")), _iso_day(statement.get("periodEnd"))
        if aid and start and end:
            statement_periods.append((aid.casefold(), start, end, source_hash or ""))
    return {
        "model_bytes": model_bytes,
        "models": data,
        "account": account,
        "account_id": account["id"],
        "cutoff": cutoff,
        "app_version": manifest["appVersion"],
        "matcher": categorize.build(models_dir),
        "statement_hashes": statement_hashes,
        "statement_periods": statement_periods,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True, help="directory containing the Amex source tree")
    parser.add_argument("--out", type=Path, required=True, help="new .ftbackup path; must not already exist")
    parser.add_argument("--backup", type=Path, required=True, help="complete schema-7 reference .ftbackup")
    parser.add_argument("--account-id", required=True, help="UUID of the exact Amex credit-card account")
    parser.add_argument("--pilot", choices=sorted(PILOTS), default="amex")
    parser.add_argument("--run-ts", default=None)
    args = parser.parse_args()
    pilot = PILOTS[args.pilot]
    source_dir = args.source / pilot["subdir"]
    report_path = args.out.parent / f"{args.out.name}.report.json"
    if (args.out.exists() or args.out.is_symlink()
            or report_path.exists() or report_path.is_symlink()):
        print("ERROR: output or diagnostic report already exists; refusing to overwrite")
        return 1
    if not source_dir.is_dir():
        print(f"ERROR: source folder does not exist: {source_dir}")
        return 1

    try:
        reference = load_reference(args.backup, args.account_id, pilot)
        _ensure_separate_paths(args.out, report_path, args.source, args.backup)
    except (OSError, ValueError) as exc:
        print(f"ERROR: {exc}")
        return 1

    run_ts = args.run_ts or datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        datetime.strptime(run_ts, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        print("ERROR: --run-ts must be UTC ISO-8601 (YYYY-MM-DDTHH:MM:SSZ)")
        return 1
    account_id = reference["account_id"]
    report: list[dict] = []
    failed = False
    seen_hashes = set(reference["statement_hashes"])
    seen_periods = list(reference["statement_periods"])
    transaction_ids = {str(row.get("id", "")).casefold() for row in reference["models"]["Transaction"]}
    statement_ids = {str(row.get("id", "")).casefold() for row in reference["models"]["Statement"]}
    transactions: list[dict] = []
    statements: list[dict] = []

    with tempfile.TemporaryDirectory(prefix="ft-historic-import-") as cache:
        for pdf in sorted(source_dir.glob("*.pdf")):
            entry = {"file": pdf.name}
            report.append(entry)
            try:
                if not extract.is_pdf(pdf):
                    raise ValueError("PDF magic header is invalid")
                source_hash = extract.sha256_file(pdf)
                known_accounts = reference["statement_hashes"].get(source_hash, set())
                if source_hash in seen_hashes:
                    if known_accounts and account_id.casefold() not in known_accounts:
                        raise ValueError("exact PDF hash already belongs to a different account")
                    entry.update(status="duplicate-exact", sha256=source_hash)
                    continue
                text = extract.pdf_text(pdf, Path(cache), source_hash)
                parsed = pilot["parse"](text)
                overlaps = [item for item in seen_periods
                            if item[0] == account_id.casefold()
                            and parsed.period_start <= item[2] and item[1] <= parsed.period_end]
                if overlaps:
                    if any(item[1] == parsed.period_start and item[2] == parsed.period_end
                           and item[3] == source_hash for item in overlaps):
                        entry.update(status="duplicate-exact", sha256=source_hash)
                        continue
                    raise ValueError("statement period overlaps a different reference or batch PDF")
                if reference["cutoff"] and parsed.period_end >= reference["cutoff"][:10]:
                    entry.update(status="skipped-overlap-cutoff", sha256=source_hash,
                                 period=f"{parsed.period_start}…{parsed.period_end}")
                    seen_periods.append((account_id.casefold(), parsed.period_start,
                                         parsed.period_end, source_hash))
                    seen_hashes.add(source_hash)
                    continue

                statement_id = models.det_id(args.pilot, "stmt", source_hash)
                if statement_id.casefold() in statement_ids:
                    raise ValueError("generated Statement.id conflicts with the reference")
                statement = models.stmt_dict(statement_id, account_id, pdf.name, source_hash, parsed, run_ts)
                new_transactions = []
                for index, tx in enumerate(parsed.transactions):
                    tx_id = models.det_id(args.pilot, "tx", source_hash, str(index))
                    if tx_id.casefold() in transaction_ids:
                        raise ValueError(f"generated Transaction.id conflicts with the reference: {tx_id}")
                    category_id = (reference["matcher"].payment_category_id
                                   if tx.is_credit and "PAGO RECIBIDO" in tx.description.upper()
                                   else reference["matcher"].match(tx.description))
                    new_transactions.append(models.tx_dict(tx_id, account_id, statement_id, tx,
                                                           category_id, run_ts))
                statements.append(statement)
                transactions.extend(new_transactions)
                statement_ids.add(statement_id.casefold())
                transaction_ids.update(row["id"].casefold() for row in new_transactions)
                seen_hashes.add(source_hash)
                seen_periods.append((account_id.casefold(), parsed.period_start,
                                     parsed.period_end, source_hash))
                entry.update(status="parsed", sha256=source_hash, transactions=len(new_transactions),
                             period=f"{parsed.period_start}…{parsed.period_end}")
            except Exception as exc:  # each document gets a diagnostic; any error blocks publication
                failed = True
                entry.update(status="error", note=str(exc)[:300])

    args.out.parent.mkdir(parents=True, exist_ok=True)
    _write_report(report_path, report)
    if failed:
        print(f"ERROR: one or more PDFs failed; no backup was published. Report: {report_path}")
        return 1

    additions = models.dump_models({"Transaction": transactions, "Statement": statements})
    merged = dict(reference["model_bytes"])
    merged["Transaction"] = ftbackup.append_json_array(merged["Transaction"], additions["Transaction"])
    merged["Statement"] = ftbackup.append_json_array(merged["Statement"], additions["Statement"])
    def validate_staged(staged: Path) -> list[str]:
        return selfcheck.check(staged)

    try:
        ftbackup.write_bundle(args.out, merged, run_ts, reference["app_version"],
                              source_bundle=args.backup, validate=validate_staged)
    except (OSError, ValueError) as exc:
        report.append({"file": None, "status": "backup-validation-error", "note": str(exc)[:500]})
        _write_report(report_path, report)
        print(f"ERROR: no backup was published: {exc}. Report: {report_path}")
        return 1

    print(f"bundle: {args.out}")
    print(f"statements added: {len(statements)} | transactions added: {len(transactions)}")
    print(f"report: {report_path}")
    print("full-backup selfcheck OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
