from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class IndicatorSpec:
    name: str                                              # TA-Lib function name
    params: dict[str, Any] = field(default_factory=dict)
    prefix: str | None = None                              # prepended to every output column
    rename: dict[str, str] = field(default_factory=dict)  # per-output renames applied before prefix


@dataclass(frozen=True)
class Sigset:
    name: str
    version: str
    indicators: list[IndicatorSpec]
    description: str = ""
