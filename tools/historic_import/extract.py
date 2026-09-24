"""Extracción de texto de PDFs con validación de magic header y cache por sha256."""

import hashlib
import subprocess
from pathlib import Path

PDFTOTEXT = "/opt/homebrew/bin/pdftotext"


def is_pdf(path: Path) -> bool:
    with open(path, "rb") as fh:
        return fh.read(4) == b"%PDF"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def pdf_text(path: Path, cache_dir: Path, sha: str) -> str:
    """Extrae texto con `pdftotext -layout`, cacheando por sha del PDF."""
    cache_dir.mkdir(parents=True, exist_ok=True)
    cached = cache_dir / f"{sha}.txt"
    if cached.exists():
        return cached.read_text(encoding="utf-8")
    result = subprocess.run(
        [PDFTOTEXT, "-layout", str(path), "-"],
        capture_output=True, text=True, check=True,
    )
    cached.write_text(result.stdout, encoding="utf-8")
    return result.stdout
