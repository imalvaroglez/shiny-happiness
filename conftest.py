"""Root conftest — makes skill modules importable in tests without a package.

The skill is intentionally NOT a Python package (no __init__.py): each script
bootstraps `_shared` onto sys.path at runtime via `parents[2]/_shared`. Tests
mirror that by inserting the two needed roots here, once, for every test.

Tests then import exactly as the skill's own scripts do at runtime:
    import products, balance, aggregate   (from wealth/scripts)
    import load, accounting_gates, trace  (from _shared)
"""
from __future__ import annotations

import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parent
_SKILL = _ROOT / ".claude" / "skills" / "finanzas"

for _p in (_SKILL / "wealth" / "scripts", _SKILL / "_shared"):
    _str = str(_p)
    if _str not in sys.path:
        sys.path.insert(0, _str)
