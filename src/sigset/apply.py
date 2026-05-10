from __future__ import annotations

import hashlib
import json
from datetime import date
from typing import Any

import pandas as pd
from talib import abstract

from sigset.model import IndicatorSpec, Sigset

# TA-Lib names that diverge from readable column names
_NORMALIZED: dict[str, str] = {
    "macdsignal": "macd_signal",
    "macdhist":   "macd_hist",
}


def _normalizeColumns(cols: pd.DataFrame) -> pd.DataFrame:
    return cols.rename(columns=_NORMALIZED)


def _lookbackBars(sigset: Sigset) -> int:
    """Minimum OHLCV rows needed to produce a non-NaN row for every indicator."""
    bars = 0
    for spec in sigset.indicators:
        f = abstract.Function(spec.name)
        if spec.params:
            f.set_parameters(spec.params)
        bars = max(bars, f.lookback)
    return bars + 50  # safety buffer for edge cases


def _inputHash(df: pd.DataFrame, sigset: Sigset) -> str:
    """Hash the full OHLCV lookback window and sigset definition.

    Covers both data corrections (changed historical rows) and param changes
    (new sigset version). A target-row-only hash misses both.
    """
    ohlcv = df.reset_index().to_json(orient="split", date_format="iso")
    spec_repr = json.dumps(
        {
            "name":    sigset.name,
            "version": sigset.version,
            "indicators": [
                {
                    "name":   s.name,
                    "params": s.params,
                    "prefix": s.prefix,
                    "rename": s.rename,
                }
                for s in sigset.indicators
            ],
        },
        sort_keys=True,
    )
    return hashlib.sha256((ohlcv + "|" + spec_repr).encode()).hexdigest()[:16]


def applySigset(df: pd.DataFrame, sigset: Sigset) -> pd.DataFrame:
    """OHLCV DataFrame in, wide feature DataFrame out.

    Raises ValueError on column name collisions — fix via prefix/rename in
    the sigset spec.
    """
    out = df.copy()
    for spec in sigset.indicators:
        f = abstract.Function(spec.name)
        if spec.params:
            f.set_parameters(spec.params)
        result = f(df)

        if isinstance(result, pd.Series):
            # Use TA-Lib's logical output name "real" so spec.rename={"real": "..."}
            # can match before the fallback renames it to spec.name.lower().
            cols = pd.DataFrame({"real": result})
        else:
            cols = result.copy()

        cols = _normalizeColumns(cols)

        if spec.rename:
            cols = cols.rename(columns=spec.rename)
        # Single-output fallback: "real" not consumed by an explicit rename.
        if "real" in cols.columns:
            cols = cols.rename(columns={"real": spec.name.lower()})
        if spec.prefix:
            cols = cols.add_prefix(spec.prefix + "_")

        for c in cols.columns:
            if c in out.columns:
                raise ValueError(
                    f"Column collision: '{c}' from {spec.name}. Use prefix/rename in sigset spec."
                )
        out = pd.concat([out, cols], axis=1)

    return out


def _readOhlcv(conn: Any, instrumentId: int, targetDate: date, nRows: int) -> pd.DataFrame:
    conn.execute(
        """
        SELECT date, open, high, low, close, volume FROM (
            SELECT
                trade_date AS date,
                open::float, high::float, low::float, close::float,
                volume
            FROM tc.eod_price
            WHERE instrument_id = %s
              AND trade_date    <= %s
            ORDER BY trade_date DESC
            LIMIT %s
        ) t
        ORDER BY date ASC
        """,
        (instrumentId, targetDate, nRows),
    )
    rows = conn.fetchall()
    if not rows:
        return pd.DataFrame()
    df = pd.DataFrame(rows, columns=["date", "open", "high", "low", "close", "volume"])
    return df.set_index("date")


def computeSigsetForDate(
    conn: Any,
    instrumentId: int,
    sigset: Sigset,
    targetDate: date,
) -> None:
    """Read OHLCV window, compute sigset features, upsert one canonical row.

    Writes to signal.indicator_panel as JSONB. Skips quietly if OHLCV data
    is unavailable for targetDate.
    """
    df = _readOhlcv(conn, instrumentId, targetDate, _lookbackBars(sigset))
    if df.empty or targetDate not in df.index:
        return

    features = applySigset(df, sigset)

    ohlcvCols = {"open", "high", "low", "close", "volume"}
    indicatorCols = [c for c in features.columns if c not in ohlcvCols]
    row = features.loc[targetDate]
    rowData = {
        c: (float(row[c]) if pd.notna(row[c]) else None)
        for c in indicatorCols
    }

    inputHash = _inputHash(df, sigset)

    conn.execute(
        """
        INSERT INTO signal.indicator_panel
            (instrument_id, ts, sigset_name, sigset_version, features, input_hash, computed_at)
        VALUES (%s, %s, %s, %s, %s, %s, now())
        ON CONFLICT (instrument_id, ts, sigset_name, sigset_version) DO UPDATE
            SET features    = EXCLUDED.features,
                input_hash  = EXCLUDED.input_hash,
                computed_at = now()
        """,
        (instrumentId, targetDate, sigset.name, sigset.version, json.dumps(rowData), inputHash),
    )
