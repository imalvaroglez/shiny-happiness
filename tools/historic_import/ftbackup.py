"""Build a complete schema-7 backup atomically, preserving every reference resource."""

import hashlib
import json
import os
import plistlib
import shutil
import tempfile
from collections.abc import Callable
from datetime import datetime
from pathlib import Path

REQUIRED_MODELS = [
    "Account", "Statement", "Category", "CategoryRule", "InstallmentPlan",
    "PendingImport", "SignRecoveryHint", "StockPosition",
    "HouseholdPartnerIncomeEstimate", "SettlementDueDateOverride",
    "Transaction", "AccountBalanceSnapshot",
]

INFO_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleIdentifier</key><string>com.financeTracker.app.backup</string>
</dict></plist>
"""


def _manifest(bundle: Path) -> dict:
    try:
        manifest = json.loads((bundle / "manifest.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"reference has no readable manifest: {exc}") from exc
    if not isinstance(manifest, dict):
        raise ValueError("reference manifest must be a JSON object")
    if manifest.get("schemaVersion") != 7:
        raise ValueError(f"only schema 7 is supported (got {manifest.get('schemaVersion')})")
    if not isinstance(manifest.get("appVersion"), str) or not manifest["appVersion"]:
        raise ValueError("reference manifest appVersion is missing or invalid")
    created_at = manifest.get("createdAt")
    if not isinstance(created_at, str):
        raise ValueError("reference manifest createdAt is missing or invalid")
    try:
        datetime.strptime(created_at, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as exc:
        raise ValueError("reference manifest createdAt must be UTC ISO-8601") from exc
    counts = manifest.get("modelCounts")
    hashes = manifest.get("contentHashes")
    if not isinstance(counts, dict) or not isinstance(hashes, dict):
        raise ValueError("reference manifest must contain modelCounts and contentHashes objects")
    for name in REQUIRED_MODELS:
        path = bundle / "models" / f"{name}.json"
        try:
            payload = path.read_bytes()
            rows = json.loads(payload)
        except (OSError, json.JSONDecodeError) as exc:
            raise ValueError(f"invalid reference model {name}: {exc}") from exc
        if not isinstance(rows, list):
            raise ValueError(f"reference models/{name}.json is not an array")
        if (not isinstance(counts.get(name), int) or isinstance(counts.get(name), bool)
                or counts[name] != len(rows)):
            raise ValueError(f"reference count mismatch for {name}")
        if hashes.get(name) != hashlib.sha256(payload).hexdigest():
            raise ValueError(f"reference hash mismatch for {name}")
    try:
        info = plistlib.loads((bundle / "Info.plist").read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException) as exc:
        raise ValueError(f"reference Info.plist is missing or invalid: {exc}") from exc
    if not isinstance(info, dict) or info.get("CFBundlePackageType") != "BNDL":
        raise ValueError("reference Info.plist has an invalid bundle structure")
    return manifest


def validate_reference(bundle: Path) -> dict:
    if bundle.suffix != ".ftbackup" or not bundle.is_dir() or bundle.is_symlink():
        raise ValueError("--backup must be an existing .ftbackup directory")
    for path in bundle.rglob("*"):
        if path.is_symlink():
            raise ValueError(f"reference contains a symlink: {path.relative_to(bundle)}")
    return _manifest(bundle)


def json_array_items(payload: bytes) -> list[str]:
    """Return raw object slices so old transaction/statement bytes survive a merge."""
    text = payload.decode("utf-8")
    decoder = json.JSONDecoder(parse_float=lambda value: value)
    index = 0
    while index < len(text) and text[index].isspace():
        index += 1
    if index >= len(text) or text[index] != "[":
        raise ValueError("model payload is not a JSON array")
    index += 1
    items: list[str] = []
    while True:
        while index < len(text) and (text[index].isspace() or text[index] == ","):
            index += 1
        if index >= len(text):
            raise ValueError("unterminated JSON array")
        if text[index] == "]":
            return items
        start = index
        _, index = decoder.raw_decode(text, index)
        items.append(text[start:index])


def append_json_array(existing: bytes, additions: bytes) -> bytes:
    before = json_array_items(existing)
    after = json_array_items(additions)
    if not after:
        return existing
    return ("[\n  " + ",\n  ".join([*before, *after]) + "\n]\n").encode("utf-8")


def write_bundle(out_dir: Path, models_bytes: dict[str, bytes], created_at: str,
                 app_version: str, *, source_bundle: Path | None = None,
                 validate: Callable[[Path], list[str]] | None = None) -> Path:
    """Validate in a sibling staging directory, then publish with one rename."""
    if out_dir.suffix != ".ftbackup":
        raise ValueError("output must have a .ftbackup extension")
    out_dir = out_dir.absolute()
    if out_dir.exists() or out_dir.is_symlink():
        raise FileExistsError(f"refusing to overwrite existing output: {out_dir}")
    if set(models_bytes) != set(REQUIRED_MODELS):
        missing = sorted(set(REQUIRED_MODELS) - set(models_bytes))
        extra = sorted(set(models_bytes) - set(REQUIRED_MODELS))
        raise ValueError(f"all schema-7 models are required (missing={missing}, extra={extra})")
    if source_bundle is not None:
        source = source_bundle.resolve()
        dest = out_dir.resolve()
        if dest == source or source in dest.parents:
            raise ValueError("output cannot be the reference backup or a child of it")

    out_dir.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{out_dir.name}.", dir=out_dir.parent))
    try:
        if source_bundle is not None:
            shutil.copytree(source_bundle, staging, dirs_exist_ok=True)
        else:
            (staging / "Info.plist").write_text(INFO_PLIST, encoding="utf-8")
        models_dir = staging / "models"
        models_dir.mkdir(parents=True, exist_ok=True)
        counts: dict[str, int] = {}
        hashes: dict[str, str] = {}
        for name in REQUIRED_MODELS:
            payload = models_bytes[name]
            rows = json.loads(payload)
            if not isinstance(rows, list):
                raise ValueError(f"{name}.json must be an array")
            (models_dir / f"{name}.json").write_bytes(payload)
            counts[name] = len(rows)
            hashes[name] = hashlib.sha256(payload).hexdigest()
        manifest = {"schemaVersion": 7, "createdAt": created_at, "appVersion": app_version,
                    "modelCounts": counts, "contentHashes": hashes}
        (staging / "manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        _manifest(staging)
        if validate is not None:
            errors = validate(staging)
            if errors:
                raise ValueError("backup selfcheck failed: " + "; ".join(errors[:12]))
        os.rename(staging, out_dir)
        return out_dir
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise
