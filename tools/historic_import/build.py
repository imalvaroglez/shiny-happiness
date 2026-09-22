"""Orquestador: banca/*.pdf → historico.ftbackup + reporte + selfcheck.

Uso:
  python3 tools/historic_import/build.py \
    --source ~/Documents/finanzas/banca --out historico.ftbackup --pilot amex
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import amex
import categorize
import extract
import ftbackup
import models
import selfcheck

DEFAULT_RUN_TS = "2026-09-09T00:00:00Z"  # fijo: regeneraciones byte-idénticas
DEFAULT_BACKUPS = Path.home() / ("Library/Containers/com.financeTracker.app/Data/"
                                 "Library/Application Support/FinanceTracker/Backups")

# Registro de pilotos. Añadir institución = 1 parser + 1 entrada aquí.
PILOTS = {
    "amex": {
        "subdir": "amex/gold-elite-cc/Estados de cuenta",
        "parse": amex.parse_pdf,
        "account_match": ("American Express Mexico", "creditCard"),
    },
}


def load_reference(backup_dir: Path) -> dict:
    models_dir = backup_dir / "models"
    accounts = json.loads((models_dir / "Account.json").read_text())
    txs = json.loads((models_dir / "Transaction.json").read_text())
    manifest = json.loads((backup_dir / "manifest.json").read_text())
    cutoff: dict[str, str] = {}
    for tx in txs:
        if tx.get("deletedAt"):
            continue
        aid = tx.get("accountId")
        posted = tx["postedAt"]
        if aid and (aid not in cutoff or posted < cutoff[aid]):
            cutoff[aid] = posted
    return {
        "models_dir": models_dir,
        "accounts": accounts,
        "cutoff": cutoff,
        "app_version": manifest.get("appVersion", "0.14.0"),
        "matcher": categorize.build(models_dir),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path,
                        default=Path.home() / "Documents/finanzas/banca")
    parser.add_argument("--out", type=Path, default=Path("historico.ftbackup"))
    parser.add_argument("--pilot", choices=sorted(PILOTS), default="amex")
    parser.add_argument("--backup", type=Path, default=None,
                        help=".ftbackup de referencia (default: el más reciente)")
    parser.add_argument("--run-ts", default=DEFAULT_RUN_TS)
    args = parser.parse_args()

    backup_dir = args.backup or max(DEFAULT_BACKUPS.glob("*.ftbackup"))
    ref = load_reference(backup_dir)
    pilot = PILOTS[args.pilot]
    account = next((a for a in ref["accounts"]
                    if a["institution"] == pilot["account_match"][0]
                    and a["type"] == pilot["account_match"][1]), None)
    if account is None:
        print(f"ERROR: no existe cuenta {pilot['account_match']} en {backup_dir}")
        return 1
    account_id = account["id"]
    cutoff = ref["cutoff"].get(account_id)

    source_dir = args.source / pilot["subdir"]
    cache_dir = args.out.parent / ".cache"
    report: list[dict] = []
    seen_hashes: set[str] = set()
    seen_periods: set[tuple[str, str]] = set()
    transactions: list[dict] = []
    statements: list[dict] = []

    for pdf in sorted(source_dir.glob("*.pdf")):
        entry = {"file": str(pdf)}
        report.append(entry)
        if not extract.is_pdf(pdf):
            entry.update(status="corrupt-magic-header",
                         note="re-descargar del banco")
            continue
        sha = extract.sha256_file(pdf)
        if sha in seen_hashes:
            entry.update(status="duplicate-hash")
            continue
        seen_hashes.add(sha)
        try:
            text = extract.pdf_text(pdf, cache_dir, sha)
            parsed = pilot["parse"](text)
        except Exception as e:  # noqa: BLE001 — cada fallo se reporta, no aborta
            entry.update(status="parse-error", note=str(e)[:200])
            continue
        if cutoff and parsed.period_end >= cutoff[:10]:
            entry.update(status="skipped-overlap-cutoff",
                         note=f"periodEnd {parsed.period_end} >= {cutoff}")
            continue
        period_key = (account_id, parsed.period_start, parsed.period_end)
        if period_key in seen_periods:
            entry.update(status="duplicate-period")
            continue
        seen_periods.add(period_key)

        stmt_id = models.det_id(args.pilot, "stmt", sha)
        statements.append(models.stmt_dict(stmt_id, account_id, pdf.name, sha,
                                           parsed, args.run_ts))
        n_tx = 0
        for idx, tx in enumerate(parsed.transactions):
            tx_id = models.det_id(args.pilot, "tx", sha, str(idx))
            if tx.is_credit and "PAGO RECIBIDO" in tx.description.upper():
                category = ref["matcher"].payment_category_id
            else:
                category = ref["matcher"].match(tx.description)
            transactions.append(models.tx_dict(tx_id, account_id, stmt_id, tx,
                                               category, args.run_ts))
            n_tx += 1
        entry.update(status="parsed", transactions=n_tx,
                     period=f"{parsed.period_start}…{parsed.period_end}")

    bundle_models = {"Transaction": transactions, "Statement": statements}
    ftbackup.write_bundle(args.out, models.dump_models(bundle_models),
                          created_at=args.run_ts, app_version=ref["app_version"])
    report_path = args.out.parent / (args.out.name + ".report.json")
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False))

    errors = selfcheck.check(args.out, ref["models_dir"])

    print(f"bundle: {args.out}")
    print(f"statements: {len(statements)} | transacciones: {len(transactions)}")
    for status in ("parsed", "skipped-overlap-cutoff", "duplicate-hash",
                   "duplicate-period", "corrupt-magic-header", "parse-error"):
        n = sum(1 for r in report if r["status"] == status)
        if n:
            print(f"  {status}: {n}")
    print(f"reporte: {report_path}")
    if errors:
        print(f"SELFCHECK FALLÓ ({len(errors)}):")
        for e in errors[:10]:
            print(" -", e)
        return 1
    print("selfcheck OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
