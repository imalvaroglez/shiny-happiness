"""Dominio del pipeline: ParsedStatement, builders de snapshots .ftbackup y codificación JSON."""

import json
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from decimal import Decimal
from zoneinfo import ZoneInfo

CDMX = ZoneInfo("America/Mexico_City")
# Namespace determinista: regeneraciones del mismo PDF producen los mismos UUIDs.
NS = uuid.uuid5(uuid.NAMESPACE_DNS, "financetracker.historic.import")


@dataclass
class TxLine:
    posted_date: str  # "YYYY-MM-DD" (fecha local CDMX)
    amount: Decimal  # positivo tal cual del PDF, sin signo
    description: str
    is_credit: bool  # CR / PAGO RECIBIDO


@dataclass
class ParsedStatement:
    period_start: str | None  # "YYYY-MM-DD"
    period_end: str | None
    opening_balance: Decimal | None  # positivo tal cual del PDF
    closing_balance: Decimal | None
    minimum_payment: Decimal | None
    payment_due_date: str | None  # "YYYY-MM-DD"
    interest: Decimal | None
    fees: Decimal | None
    iva: Decimal | None
    transactions: list[TxLine] = field(default_factory=list)


def local_date_to_iso_utc(date_str: str) -> str:
    """Medianoche America/Mexico_City → ISO8601 UTC sin fracciones (como la app)."""
    local = datetime.fromisoformat(date_str).replace(tzinfo=CDMX)
    return local.astimezone(ZoneInfo("UTC")).strftime("%Y-%m-%dT%H:%M:%SZ")


def det_id(*parts: str) -> str:
    return str(uuid5(NS, ":".join(parts)))


def uuid5(ns: uuid.UUID, name: str) -> uuid.UUID:
    return uuid.uuid5(ns, name)


def merchant_of(description: str) -> str:
    """Port de AmexMexicoParser.extractMerchant."""
    prefixes = ["Uber", "DiDi", "OXXO", "Amazon", "Mercado Pago", "Starbucks",
                "Netflix", "Spotify", "Apple", "Google", "Walmart", "SANBORNS",
                "GAP", "ZARA", "HEB", "VIPS", "TOKS"]
    lowered = description.lower()
    for prefix in prefixes:
        if prefix.lower() in lowered:
            return prefix
    for word in description.replace(",", " ").replace(";", " ").replace(":", " ").replace(".", " ").split():
        if len(word) > 2:
            return word
    return description


def tx_dict(tx_id: str, account_id: str, statement_id: str, tx: TxLine,
            category_id: str | None, run_ts: str) -> dict:
    """TransactionSnapshot según BackupModels.swift. Flow kinds verificados en
    Transaction.swift:101-129 / TransactionClassifier.swift (cargos=charge,
    PAGO RECIBIDO=payment→transfer, otros CR=cardCredit)."""
    desc = " ".join(tx.description.split())
    if tx.is_credit and "PAGO RECIBIDO" in desc.upper():
        flow, movement = "payment", "transfer"
        category = category_id  # build.py fuerza creditCardPayment
    elif tx.is_credit:
        flow, movement = "cardCredit", "adjustment"
        category = category_id
    else:
        flow, movement = "charge", "expense"
        category = category_id
    d = {
        "id": tx_id,
        "accountId": account_id,
        "statementId": statement_id,  # ligada: la excluye de los deltas del balance
        "postedAt": local_date_to_iso_utc(tx.posted_date),
        "amount": -tx.amount if not tx.is_credit else tx.amount,
        "currency": "MXN",
        "descriptionRaw": desc,
        "merchantNormalized": merchant_of(desc),
        "fxRateToBase": Decimal(1),
        "isTransfer": False,
        "isDuplicate": False,
        "source": "imported",
        "flowKindRaw": flow,
        "movementKindRaw": movement,
        "treatmentKindRaw": "regular",
        "householdScopeRaw": "excluded",
        "settlementPaidByRaw": "excluded",
        "lastModifiedAt": run_ts,
    }
    if category:
        d["categoryId"] = category
    return d


def stmt_dict(stmt_id: str, account_id: str, source_name: str, source_hash: str,
              parsed: ParsedStatement, run_ts: str) -> dict:
    """StatementSnapshot; balances TDC negados (AD-010: liability signed-negative)."""
    d = {
        "id": stmt_id,
        "accountId": account_id,
        "periodStart": local_date_to_iso_utc(parsed.period_start),
        "periodEnd": local_date_to_iso_utc(parsed.period_end),
        "sourceFileHash": source_hash,
        "sourceFileName": source_name,
        "importedAt": run_ts,
        "ocrUsed": False,
        "lastModifiedAt": run_ts,
    }
    if parsed.opening_balance is not None:
        d["openingBalance"] = -parsed.opening_balance
    if parsed.closing_balance is not None:
        d["closingBalance"] = -parsed.closing_balance
    if parsed.minimum_payment is not None:
        d["minimumPayment"] = parsed.minimum_payment
    if parsed.payment_due_date:
        d["paymentDueDate"] = local_date_to_iso_utc(parsed.payment_due_date)
    if parsed.interest is not None:
        d["interestCharged"] = parsed.interest
    if parsed.fees is not None:
        d["feesCharged"] = parsed.fees
    if parsed.iva is not None:
        d["ivaCharged"] = parsed.iva
    return d


def dump_models(models: dict[str, list]) -> dict[str, bytes]:
    """Codifica cada models/Name.json. Decimal→float (repr shortest-roundtrip:
    exacto a 2 decimales MXN; ponytail: techo ~16 dígitos significativos)."""
    return {
        name: json.dumps(rows, indent=2, sort_keys=True, ensure_ascii=False,
                         default=_decimal_default).encode("utf-8")
        for name, rows in models.items()
    }


def _decimal_default(obj):
    if isinstance(obj, Decimal):
        return float(obj)
    raise TypeError(f"not JSON serializable: {type(obj)}")
