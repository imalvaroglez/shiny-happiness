"""Round-trip mínimo: builders → bundle → selfcheck, con una referencia
sintética (cuenta + categoría) y verificación de codificación."""

import json
from decimal import Decimal
from pathlib import Path

import ftbackup
import models
import selfcheck

ACCOUNT_ID = "98635015-070A-4EB5-9050-3268FB4B49FA"
CATEGORY_ID = "CAT-0001"
RUN_TS = "2026-09-09T00:00:00Z"


def _parsed():
    return models.ParsedStatement(
        period_start="2019-01-12", period_end="2019-02-11",
        opening_balance=Decimal("6264.76"), closing_balance=Decimal("5227.41"),
        minimum_payment=Decimal("362.50"), payment_due_date="2019-03-04",
        interest=Decimal("0.00"), fees=Decimal("0.00"), iva=None,
        transactions=[
            models.TxLine("2019-01-23", Decimal("6264.76"),
                          "PAGO RECIBIDO, GRACIAS", True),
            models.TxLine("2019-01-11", Decimal("44.00"),
                          "CINEPOLIS0485 000000000 DF", False),
        ])


def _bundle(tmp_path: Path) -> Path:
    stmt_id = models.det_id("amex", "stmt", "deadbeef")
    parsed = _parsed()
    stmts = [models.stmt_dict(stmt_id, ACCOUNT_ID, "201902.pdf", "deadbeef",
                              parsed, RUN_TS)]
    txs = [models.tx_dict(models.det_id("amex", "tx", "deadbeef", str(i)),
                          ACCOUNT_ID, stmt_id, tx, CATEGORY_ID, RUN_TS)
           for i, tx in enumerate(parsed.transactions)]
    bundle = tmp_path / "mini.ftbackup"
    ftbackup.write_bundle(bundle, models.dump_models(
        {"Transaction": txs, "Statement": stmts}), RUN_TS, "0.14.0")
    return bundle


def _ref(tmp_path: Path) -> Path:
    ref = tmp_path / "ref" / "models"
    ref.mkdir(parents=True)
    (ref / "Account.json").write_text(json.dumps(
        [{"id": ACCOUNT_ID, "institution": "American Express Mexico",
          "type": "creditCard", "currency": "MXN", "nickname": "x",
          "openedAt": RUN_TS, "lastModifiedAt": RUN_TS}]))
    (ref / "Category.json").write_text(json.dumps(
        [{"id": CATEGORY_ID, "name": "Cine", "kind": "expense",
          "lastModifiedAt": RUN_TS}]))
    (ref / "Transaction.json").write_text("[]")
    return ref.parent


def test_bundle_pasa_selfcheck(tmp_path):
    errors = selfcheck.check(_bundle(tmp_path), _ref(tmp_path) / "models")
    assert errors == []


def test_closing_balance_negativo_ad010(tmp_path):
    bundle = _bundle(tmp_path)
    stmt = json.loads((bundle / "models" / "Statement.json").read_bytes())[0]
    assert stmt["closingBalance"] == -5227.41
    assert stmt["openingBalance"] == -6264.76


def test_pago_recibido_es_payment_transfer(tmp_path):
    bundle = _bundle(tmp_path)
    txs = json.loads((bundle / "models" / "Transaction.json").read_bytes())
    pago = next(t for t in txs if "PAGO RECIBIDO" in t["descriptionRaw"])
    assert pago["flowKindRaw"] == "payment"
    assert pago["movementKindRaw"] == "transfer"
    assert pago["amount"] == 6264.76  # Decimal como número JSON, no string
    cargo = next(t for t in txs if "CINEPOLIS" in t["descriptionRaw"])
    assert cargo["flowKindRaw"] == "charge"
    assert cargo["movementKindRaw"] == "expense"
    assert cargo["amount"] == -44.00


def test_fecha_cdmx_a_utc(tmp_path):
    bundle = _bundle(tmp_path)
    txs = json.loads((bundle / "models" / "Transaction.json").read_bytes())
    # medianoche CDMX (UTC-6 en enero, sin horario de verano desde 2022)
    assert txs[0]["postedAt"] == "2019-01-23T06:00:00Z"


def test_manifest_counts_y_hashes(tmp_path):
    bundle = _bundle(tmp_path)
    manifest = json.loads((bundle / "manifest.json").read_text())
    import hashlib
    for name in ("Transaction", "Statement", "Account"):
        payload = (bundle / "models" / f"{name}.json").read_bytes()
        assert manifest["modelCounts"][name] == len(json.loads(payload))
        assert manifest["contentHashes"][name] == hashlib.sha256(payload).hexdigest()
    assert manifest["schemaVersion"] == 7
    assert set(manifest["modelCounts"]) == set(ftbackup.REQUIRED_MODELS)


def test_ids_deterministas():
    a = models.det_id("amex", "tx", "sha", "0")
    b = models.det_id("amex", "tx", "sha", "0")
    c = models.det_id("amex", "tx", "sha", "1")
    assert a == b and a != c
