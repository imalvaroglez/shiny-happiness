"""Complete-backup merge tests with synthetic accounts and transaction rows."""

import hashlib
import json
import sys
from decimal import Decimal
from pathlib import Path

import build
import ftbackup
import models
import pytest
import selfcheck

ACCOUNT_ID = "98635015-070A-4EB5-9050-3268FB4B49FA"
SECOND_ACCOUNT_ID = "3072A1DC-0BCF-4863-B2E5-2F8F7F63A2EA"
CATEGORY_ID = "CAT-0001"
PAYMENT_CATEGORY_ID = "CAT-PAYMENT"
RUN_TS = "2026-09-22T12:00:00Z"


def _blank_models(accounts=None):
    values = {name: [] for name in ftbackup.REQUIRED_MODELS}
    values["Account"] = accounts or [{
        "id": ACCOUNT_ID, "institution": "American Express Mexico", "type": "creditCard",
        "currency": "MXN", "nickname": "synthetic primary", "openedAt": RUN_TS,
        "lastModifiedAt": RUN_TS,
    }]
    values["Category"] = [
        {"id": CATEGORY_ID, "name": "General", "kind": "expense", "lastModifiedAt": RUN_TS},
        {"id": PAYMENT_CATEGORY_ID, "name": "Card Payment Received", "kind": "creditCardPayment",
         "lastModifiedAt": RUN_TS},
    ]
    values["CategoryRule"] = [{
        "id": "RULE-1", "patternRegex": "LOCAL", "merchantMatch": "", "categoryId": CATEGORY_ID,
        "priority": 1, "source": "manual", "matchCount": 0, "lastModifiedAt": RUN_TS,
    }]
    return values


def _write_reference(path: Path, accounts=None) -> Path:
    values = _blank_models(accounts)
    # Deliberately stable whitespace makes exact byte preservation observable.
    payloads = {name: json.dumps(rows, indent=2, ensure_ascii=False).encode()
                for name, rows in values.items()}
    return ftbackup.write_bundle(path, payloads, RUN_TS, "0.14.0")


def _parsed():
    return models.ParsedStatement(
        period_start="2021-01-01", period_end="2021-01-31",
        opening_balance=Decimal("1000.00"), closing_balance=Decimal("1200.00"),
        minimum_payment=Decimal("50.00"), payment_due_date="2021-02-15",
        interest=Decimal("20.00"), fees=Decimal("50.00"), iva=Decimal("30.00"),
        transactions=[
            models.TxLine("2021-01-05", Decimal("300.00"), "MERCADO LOCAL", False),
            models.TxLine("2021-01-08", Decimal("100.00"), "RESTAURANTE LOCAL", False),
            models.TxLine("2021-01-14", Decimal("300.00"), "PAGO RECIBIDO, GRACIAS", True),
            models.TxLine("2021-01-31", Decimal("20.00"), "INTERÉS FINANCIERO", False),
            models.TxLine("2021-01-31", Decimal("50.00"), "COMISIÓN DE SERVICIO", False),
            models.TxLine("2021-01-31", Decimal("30.00"), "IVA DE COMISIÓN", False),
        ],
    )


def _new_rows(account_id=ACCOUNT_ID):
    statement_id = models.det_id("amex", "stmt", "synthetic-hash")
    parsed = _parsed()
    statements = [models.stmt_dict(statement_id, account_id, "synthetic.pdf", "synthetic-hash",
                                  parsed, RUN_TS)]
    transactions = [models.tx_dict(models.det_id("amex", "tx", "synthetic-hash", str(i)),
                                   account_id, statement_id, tx, CATEGORY_ID, RUN_TS)
                    for i, tx in enumerate(parsed.transactions)]
    return statements, transactions


def _full_bundle(tmp_path: Path) -> Path:
    statements, transactions = _new_rows()
    values = _blank_models()
    values["Statement"] = statements
    values["Transaction"] = transactions
    bundle = tmp_path / "mini.ftbackup"
    return ftbackup.write_bundle(bundle, models.dump_models(values), RUN_TS, "0.14.0",
                                 validate=selfcheck.check)


def _source_root(tmp_path: Path) -> Path:
    root = tmp_path / "source"
    folder = root / build.PILOTS["amex"]["subdir"]
    folder.mkdir(parents=True)
    (folder / "synthetic.pdf").write_bytes(b"%PDF synthetic")
    return root


def test_new_bundle_is_complete_and_selfcheck_uses_internal_references(tmp_path):
    bundle = _full_bundle(tmp_path)
    assert selfcheck.check(bundle) == []
    assert set(json.loads((bundle / "manifest.json").read_text())["modelCounts"]) == set(ftbackup.REQUIRED_MODELS)
    assert selfcheck.check(bundle / "missing")


def test_imported_money_and_credit_flow_keep_exact_json_values(tmp_path):
    bundle = _full_bundle(tmp_path)
    transactions = json.loads((bundle / "models" / "Transaction.json").read_bytes(), parse_float=Decimal)
    payment = next(tx for tx in transactions if tx["flowKindRaw"] == "payment")
    charge = next(tx for tx in transactions if tx["descriptionRaw"] == "MERCADO LOCAL")
    assert payment["movementKindRaw"] == "transfer" and payment["amount"] == Decimal("300.0")
    assert charge["flowKindRaw"] == "charge" and charge["amount"] == Decimal("-300.0")


def test_manifest_counts_and_hashes_cover_every_model(tmp_path):
    bundle = _full_bundle(tmp_path)
    manifest = json.loads((bundle / "manifest.json").read_text())
    for name in ftbackup.REQUIRED_MODELS:
        payload = (bundle / "models" / f"{name}.json").read_bytes()
        assert manifest["modelCounts"][name] == len(json.loads(payload))
        assert manifest["contentHashes"][name] == hashlib.sha256(payload).hexdigest()


def test_publish_clones_reference_and_preserves_unchanged_model_and_resource_bytes(tmp_path):
    reference = _write_reference(tmp_path / "reference.ftbackup")
    resource = reference / "statements" / "nested" / "source.pdf"
    resource.parent.mkdir(parents=True)
    resource.write_bytes(b"synthetic reference resource bytes")
    original = {name: (reference / "models" / f"{name}.json").read_bytes()
                for name in ftbackup.REQUIRED_MODELS}
    base = dict(original)
    base["Transaction"] = b'[ { "id" : "old-tx", "descriptionRaw" : "preserved exact row", "amount" : 1.20 } ]\n'
    base["Statement"] = b"[]\n"
    (reference / "models" / "Transaction.json").write_bytes(base["Transaction"])
    # Re-sign the reference after adding the synthetic legacy row.
    manifest = json.loads((reference / "manifest.json").read_text())
    manifest["modelCounts"]["Transaction"] = 1
    manifest["contentHashes"]["Transaction"] = hashlib.sha256(base["Transaction"]).hexdigest()
    (reference / "manifest.json").write_text(json.dumps(manifest))
    (reference / "models" / "Statement.json").write_bytes(base["Statement"])

    added = {"id": "new-tx", "amount": -Decimal("987.65"), "postedAt": RUN_TS,
             "accountId": ACCOUNT_ID, "statementId": None}
    # Give the addition a valid statement target.
    stmt = {"id": "new-stmt", "accountId": ACCOUNT_ID, "periodStart": RUN_TS, "periodEnd": RUN_TS,
            "sourceFileHash": "synthetic-statement-hash"}
    added["statementId"] = stmt["id"]
    payloads = dict(base)
    payloads["Transaction"] = ftbackup.append_json_array(base["Transaction"], models.dump_models({"Transaction": [added]})["Transaction"])
    payloads["Statement"] = ftbackup.append_json_array(base["Statement"], models.dump_models({"Statement": [stmt]})["Statement"])
    out = tmp_path / "merged.ftbackup"
    ftbackup.write_bundle(out, payloads, RUN_TS, "0.14.0", source_bundle=reference,
                          validate=lambda path: [])

    assert selfcheck.check(out) == []
    for name in set(ftbackup.REQUIRED_MODELS) - {"Transaction", "Statement"}:
        assert (out / "models" / f"{name}.json").read_bytes() == original[name]
    assert b'"id" : "old-tx"' in (out / "models" / "Transaction.json").read_bytes()
    assert (out / "statements" / "nested" / "source.pdf").read_bytes() == resource.read_bytes()
    txs = json.loads((out / "models" / "Transaction.json").read_bytes(), parse_float=Decimal)
    assert next(row for row in txs if row["id"] == "new-tx")["amount"] == Decimal("-987.65")


def test_writer_rejects_partial_overwrite_and_precision_loss(tmp_path):
    target = tmp_path / "out.ftbackup"
    with pytest.raises(ValueError, match="all schema-7 models"):
        ftbackup.write_bundle(target, {"Transaction": b"[]"}, RUN_TS, "0.14.0")
    values = {name: b"[]" for name in ftbackup.REQUIRED_MODELS}
    ftbackup.write_bundle(target, values, RUN_TS, "0.14.0")
    with pytest.raises(FileExistsError):
        ftbackup.write_bundle(target, values, RUN_TS, "0.14.0")
    with pytest.raises(ValueError, match="lose precision"):
        models.dump_models({"Transaction": [{"amount": Decimal("0.1234567890123456789")}]})


def test_manifest_and_selfcheck_reject_non_object_manifest(tmp_path):
    bundle = _write_reference(tmp_path / "malformed.ftbackup")
    (bundle / "manifest.json").write_text("[]")
    with pytest.raises(ValueError, match="manifest must be a JSON object"):
        ftbackup.validate_reference(bundle)
    assert selfcheck.check(bundle) == ["manifest must be a JSON object"]


def test_selfcheck_rejects_nonfinite_money_and_reversed_statement_period(tmp_path):
    bundle = _write_reference(tmp_path / "invalid-rows.ftbackup")
    payload = json.dumps([{
        "id": "bad-statement", "periodStart": "2026-09-22T06:00:00Z",
        "periodEnd": "2026-09-21T06:00:00Z", "closingBalance": float("nan"),
    }]).encode()
    model_path = bundle / "models" / "Statement.json"
    model_path.write_bytes(payload)
    manifest_path = bundle / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    manifest["modelCounts"]["Statement"] = 1
    manifest["contentHashes"]["Statement"] = hashlib.sha256(payload).hexdigest()
    manifest_path.write_text(json.dumps(manifest))

    errors = selfcheck.check(bundle)
    assert any("periodStart is after periodEnd" in error for error in errors)
    assert any("closingBalance is not a finite" in error for error in errors)


def test_writer_rejects_dangling_output_symlink(tmp_path):
    target = tmp_path / "missing.ftbackup"
    link = tmp_path / "link.ftbackup"
    link.symlink_to(target)
    values = {name: b"[]" for name in ftbackup.REQUIRED_MODELS}
    with pytest.raises(FileExistsError):
        ftbackup.write_bundle(link, values, RUN_TS, "0.14.0")


def test_import_outputs_must_stay_outside_the_entire_source_tree(tmp_path):
    source = tmp_path / "source"
    source.mkdir()
    out = source / "outside-pilot-folder.ftbackup"
    with pytest.raises(ValueError, match="outside the PDF source tree"):
        build._ensure_separate_paths(out, out.with_suffix(".report.json"), source,
                                     tmp_path / "reference.ftbackup")


def test_exact_account_id_selects_one_of_two_amex_cards(tmp_path):
    accounts = _blank_models()["Account"] + [{
        "id": SECOND_ACCOUNT_ID, "institution": "American Express Mexico", "type": "creditCard",
        "currency": "MXN", "nickname": "synthetic second", "openedAt": RUN_TS,
        "lastModifiedAt": RUN_TS,
    }]
    reference_path = _write_reference(tmp_path / "two-cards.ftbackup", accounts)
    selected = build.load_reference(reference_path, SECOND_ACCOUNT_ID, build.PILOTS["amex"])
    assert selected["account_id"] == SECOND_ACCOUNT_ID
    with pytest.raises(ValueError, match="exactly one account"):
        build.load_reference(reference_path, "11111111-1111-1111-1111-111111111111", build.PILOTS["amex"])


def test_builder_outputs_complete_merged_backup_without_mutating_reference(tmp_path, monkeypatch):
    reference = _write_reference(tmp_path / "reference.ftbackup")
    original_models = {path.name: path.read_bytes() for path in (reference / "models").glob("*.json")}
    (reference / "statements").mkdir()
    (reference / "statements" / "preserved.bin").write_bytes(b"reference resource")
    source = _source_root(tmp_path)
    monkeypatch.setattr(build.extract, "pdf_text", lambda *_: __import__("tests.historic_import.test_amex", fromlist=["HEADER_2021", "DETAIL_2021"]).HEADER_2021
                        + __import__("tests.historic_import.test_amex", fromlist=["DETAIL_2021"]).DETAIL_2021)
    out = tmp_path / "output.ftbackup"
    monkeypatch.setattr(sys, "argv", ["build.py", "--source", str(source), "--backup", str(reference),
                                      "--account-id", ACCOUNT_ID, "--out", str(out), "--run-ts", RUN_TS])
    assert build.main() == 0
    assert selfcheck.check(out) == []
    assert (out / "statements" / "preserved.bin").read_bytes() == b"reference resource"
    assert {path.name: path.read_bytes() for path in (reference / "models").glob("*.json")} == original_models
    assert set(json.loads((out / "manifest.json").read_text())["modelCounts"]) == set(ftbackup.REQUIRED_MODELS)


def test_parser_error_keeps_report_and_never_publishes_backup(tmp_path, monkeypatch):
    reference = _write_reference(tmp_path / "reference.ftbackup")
    source = _source_root(tmp_path)
    monkeypatch.setattr(build.extract, "pdf_text", lambda *_: "unrecognized synthetic document")
    out = tmp_path / "bad.ftbackup"
    monkeypatch.setattr(sys, "argv", ["build.py", "--source", str(source), "--backup", str(reference),
                                      "--account-id", ACCOUNT_ID, "--out", str(out), "--run-ts", RUN_TS])
    assert build.main() == 1
    assert not out.exists()
    report = json.loads((tmp_path / "bad.ftbackup.report.json").read_text())
    assert report[0]["status"] == "error"


def test_overlapping_statement_period_blocks_the_entire_batch(tmp_path, monkeypatch):
    reference = _write_reference(tmp_path / "reference.ftbackup")
    source = _source_root(tmp_path)
    folder = source / build.PILOTS["amex"]["subdir"]
    (folder / "second.pdf").write_bytes(b"%PDF different content, same statement period")
    fixture = __import__("tests.historic_import.test_amex", fromlist=["HEADER_2021", "DETAIL_2021"])
    normal = fixture.HEADER_2021 + fixture.DETAIL_2021
    overlapping = fixture.HEADER_2021.replace("Del 1 de Enero", "Del 2 de Enero") + fixture.DETAIL_2021
    monkeypatch.setattr(build.extract, "pdf_text",
                        lambda pdf, *_: overlapping if pdf.name == "second.pdf" else normal)
    out = tmp_path / "conflict.ftbackup"
    monkeypatch.setattr(sys, "argv", ["build.py", "--source", str(source), "--backup", str(reference),
                                      "--account-id", ACCOUNT_ID, "--out", str(out), "--run-ts", RUN_TS])

    assert build.main() == 1
    assert not out.exists()
    report = json.loads((tmp_path / "conflict.ftbackup.report.json").read_text())
    assert sorted(entry["status"] for entry in report) == ["error", "parsed"]


def test_cli_requires_reference_source_account_and_destination(monkeypatch):
    monkeypatch.setattr(sys, "argv", ["build.py"])
    with pytest.raises(SystemExit) as error:
        build.main()
    assert error.value.code == 2


def test_deterministic_ids_are_stable():
    assert models.det_id("amex", "tx", "sha", "0") == models.det_id("amex", "tx", "sha", "0")
    assert models.det_id("amex", "tx", "sha", "0") != models.det_id("amex", "tx", "sha", "1")
