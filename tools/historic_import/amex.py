"""Parser Amex Mexico (Gold Elite) — layout pdftotext -layout verificado 2018-10→2026.

Port de FinanceTracker/Ingest/Parsers/CSV/AmexMexicoParser.swift corregido al
layout real: fila resumen sin '$', "Período de Facturación Del… al… de YYYY",
transacciones "d de Mes DESCRIPCION MONTO [CR]" con CR posible en línea de
continuación, y secciones MSI/financieras como líneas fechadas normales.
"""

import re
from datetime import date
from decimal import Decimal

from models import ParsedStatement, TxLine

MONTHS = {"ene": 1, "feb": 2, "mar": 3, "abr": 4, "may": 5, "jun": 6,
          "jul": 7, "ago": 8, "sep": 9, "oct": 10, "nov": 11, "dic": 12}

PERIOD_RE = re.compile(
    r"Per[íi]odo de Facturaci[óo]n Del (\d{1,2}) de ([A-Za-zÁÉÍÓÚÑáéíóúñ]+)"
    r" al (\d{1,2}) de ([A-Za-zÁÉÍÓÚÑáéíóúñ]+) de (\d{4})", re.IGNORECASE)
SUMMARY_RE = re.compile(
    r"^[ \t]*([\d,]+\.\d{2})\s*-\s*([\d,]+\.\d{2})\s*\+\s*([\d,]+\.\d{2})"
    r"\s*=\s*([\d,]+\.\d{2})\s+([\d,]+\.\d{2})", re.MULTILINE)
MIN_PAY_RE = re.compile(r"Pago M[íi]nimo: \$\s*([\d,]+\.\d{2})")
DUE_RE_YEAR = re.compile(r"Fecha l[íi]mite de pago:\s*(\d{1,2}) de ([A-Za-zÁÉÍÓÚÑáéíóúñ]+) de (\d{4})")
DUE_RE = re.compile(r"Fecha l[íi]mite de pago:\s*(\d{1,2}) de ([A-Za-zÁÉÍÓÚÑáéíóúñ]+)")
TX_RE = re.compile(
    r"^\s{0,8}(\d{1,2}) de ([A-Za-zÁÉÍÓÚÑáéíóúñ]+)\s+(.+?)\s+([\d,]+\.\d{2})\s*(CR)?\s*$")
DATED_ROW_RE = re.compile(r"^\s{0,8}(\d{1,2})\s+de\s+([A-Za-zÁÉÍÓÚÑáéíóúñ]+)\b", re.IGNORECASE)
CR_TAIL_RE = re.compile(r"(?:^|\s)CR\s*$")
DETAIL_HEADER = "Fecha y Detalle de las operaciones"


def _month(name: str) -> int:
    return MONTHS[name.lower()[:3]]


def _dec(text: str) -> Decimal:
    return Decimal(text.replace(",", ""))


def _period(text: str) -> tuple[str, str, int, int] | None:
    """(period_start, period_end, end_month, end_year)."""
    m = PERIOD_RE.search(text)
    if not m:
        return None
    sd, sm, ed, em, ey = m.groups()
    start_month, end_month = _month(sm), _month(em)
    end_year = int(ey)
    start_year = end_year - 1 if start_month > end_month else end_year
    start = f"{start_year:04d}-{start_month:02d}-{int(sd):02d}"
    end = f"{end_year:04d}-{end_month:02d}-{int(ed):02d}"
    try:
        if date.fromisoformat(start) > date.fromisoformat(end):
            raise ValueError("period start is after period end")
    except ValueError as exc:
        raise ValueError(f"invalid billing period: {exc}") from exc
    return start, end, end_month, end_year


def _due_date(text: str, end_month: int, end_year: int) -> str | None:
    m = DUE_RE_YEAR.search(text)
    if m:
        d, mo, y = m.groups()
        return f"{int(y):04d}-{_month(mo):02d}-{int(d):02d}"
    m = DUE_RE.search(text)
    if not m:
        return None
    d, mo = m.groups()
    month = _month(mo)
    year = end_year + 1 if month < end_month else end_year
    return f"{year:04d}-{month:02d}-{int(d):02d}"


def _charges_meta(text: str) -> tuple[Decimal | None, Decimal | None, Decimal | None]:
    """(interés, comisiones, iva) del bloque 'Nuevos Cargos incluyen'."""
    anchor = text.find("Nuevos Cargos incluyen")
    if anchor < 0:
        return None, None, None
    block = text[anchor:anchor + 400]
    def grab(label):
        m = re.search(rf"{label}:\s+([\d,]+\.\d{{2}})", block)
        return _dec(m.group(1)) if m else None
    return grab("Inter[ée]s Financiero"), grab("Comisiones"), grab("IVA")


def _transactions(text: str, end_month: int, end_year: int) -> list[TxLine]:
    anchor = text.find(DETAIL_HEADER)
    if anchor < 0:
        return []
    txs: list[TxLine] = []
    pending: TxLine | None = None
    for line_number, line in enumerate(text[anchor:].splitlines(), start=1):
        m = TX_RE.match(line)
        if m:
            day, month_name, desc, amount, cr = m.groups()
            try:
                month = _month(month_name)
            except KeyError as exc:
                raise ValueError(f"unrecognized transaction month on detail line {line_number}: {month_name}") from exc
            year = end_year - 1 if month > end_month else end_year
            posted_date = f"{year:04d}-{month:02d}-{int(day):02d}"
            try:
                date.fromisoformat(posted_date)
            except ValueError as exc:
                raise ValueError(f"invalid transaction date on detail line {line_number}: {posted_date}") from exc
            value = _dec(amount)
            if value <= 0:
                raise ValueError(f"non-positive transaction amount on detail line {line_number}")
            tx = TxLine(
                posted_date=posted_date,
                amount=value,
                description=desc.strip(),
                is_credit=bool(cr) or desc.upper().startswith("PAGO RECIBIDO"),
            )
            txs.append(tx)
            pending = tx
        elif DATED_ROW_RE.match(line):
            raise ValueError(f"unrecognized dated transaction row on detail line {line_number}: {line.strip()[:120]}")
        elif pending is not None and line.strip():
            if CR_TAIL_RE.search(line):
                pending.is_credit = True
            pending = None
    return txs


def parse_pdf(text: str) -> ParsedStatement:
    period = _period(text)
    if not period:
        raise ValueError("no se encontró 'Período de Facturación'")
    txs = _transactions(text, period[2], period[3])
    if not txs:
        raise ValueError("no transaction detail rows were recognized")
    if any(tx.posted_date < period[0] or tx.posted_date > period[1] for tx in txs):
        raise ValueError("transaction date falls outside the billing period")
    interest, fees, iva = _charges_meta(text)
    opening = closing = min_pay = None
    m = SUMMARY_RE.search(text)
    credit_total = charge_total = None
    if m:
        opening, credit_total, charge_total, closing, min_pay = (_dec(g) for g in m.groups())
        if opening - credit_total + charge_total != closing:
            raise ValueError("statement summary does not reconcile: opening − credits + charges ≠ closing")
        actual_credits = sum((tx.amount for tx in txs if tx.is_credit), Decimal(0))
        actual_charges = sum((tx.amount for tx in txs if not tx.is_credit), Decimal(0))
        if actual_credits != credit_total or actual_charges != charge_total:
            raise ValueError("recognized transactions do not reconcile with statement credit/charge totals")
    else:
        m2 = MIN_PAY_RE.search(text)
        if m2:
            min_pay = _dec(m2.group(1))
    due_date = _due_date(text, period[2], period[3])
    if due_date:
        try:
            date.fromisoformat(due_date)
        except ValueError as exc:
            raise ValueError(f"invalid payment due date: {due_date}") from exc
    return ParsedStatement(
        period_start=period[0],
        period_end=period[1],
        opening_balance=opening,
        closing_balance=closing,
        minimum_payment=min_pay,
        payment_due_date=due_date,
        interest=interest,
        fees=fees,
        iva=iva,
        transactions=txs,
        summary_credit_total=credit_total,
        summary_charge_total=charge_total,
    )
