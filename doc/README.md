# tc-signal

PostgreSQL schemas for strategy signal generation and execution mirroring,
built on [tc-schema](../../tc-schema) for market data ground truth.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| tc-schema deployed | `tc.schema_version >= 1` must exist before applying any signal patches |
| TimescaleDB | Required for hypertable patches (`signal.indicator_panel`, `signal.trendadvisor`) |
| Python 3.11+ | For the `src/sigset/` package |
| TA-Lib | C library + Python bindings (`pip install TA-Lib`) |
| pandas | `pip install pandas` |
| psycopg2 or psycopg3 | DB driver used by calling code; `src/sigset/` uses `conn.execute()` then `conn.fetchall()`, compatible with both |

---

## Deployment

Patches are applied with the schema runner from tc-schema. tc-schema must
already be deployed before running any signal patches.

```bash
# Apply all pending signal patches
python ../tc-schema/src/opSchema.py --schema signal --patch ./sql/patch

# Verify without applying (dry-run)
python ../tc-schema/src/opSchema.py --schema signal --patch ./sql/patch --check

# Override DSN
python ../tc-schema/src/opSchema.py --schema signal --patch ./sql/patch \
    --dsn "postgresql://user:pw@host:5433/tcdata"
```

**DSN resolution order:** `--dsn` flag → `EOD_DSN` environment variable →
`cfg/dev.env.local` (gitignored, for local passwords) → `cfg/dev.env`
(tracked, no credentials).

### Patch sequence

| Patch | Creates |
|---|---|
| `002_signal.sql` | `signal` schema and patch tracking table |
| `003_strategy_signal.sql` | `signal.strategy_signal` |
| `004_features.sql` | `signal.indicator_panel`, `signal.indicator_scratch` |
| `005_state.sql` | `signal.trendadvisor` |
| `006_execution.sql` | `execution` schema, `exec_order`, `fill`, `position` |

All patches are idempotent — safe to re-run against the same database.

---

## Schema reference

Two schemas. The split is also a permission boundary: the NautilusTrader
process holds `SELECT` on `signal.*` and `INSERT/UPDATE` on `execution.*`.

### `signal` — strategy inputs and signals

**`signal.strategy_signal`**
The handoff point between strategy code and NautilusTrader. One row per
signal emitted. `run_id IS NULL` = live signal; `run_id IS SET` = backtest.
Live and backtest signals coexist without contamination.

**`signal.indicator_panel`**
Canonical computed features, stored as JSONB. One row per
`(instrument_id, ts, sigset_name, sigset_version)`. Written by
`computeSigsetForDate()`. TimescaleDB hypertable, compressed after one year.

**`signal.indicator_scratch`**
Transient JSONB scratchpad for parameter sweeps and in-flux sigset definitions
not yet promoted to canonical. The primary key includes `params_hash` so
different parameter combinations for the same sigset and date coexist safely.
Delete rows (not the table) when a sweep campaign ends. Regular Postgres table.

**`signal.trendadvisor`**
TRENDadvisor detector state. Bitemporal: `(code_version, params_hash)` in the
primary key so multiple algorithm variants coexist on the same instrument data.
TimescaleDB hypertable.

### `execution` — NautilusTrader mirror

**`execution.exec_order`**
Orders submitted to the venue, written by NT lifecycle hooks. `exec_order`
avoids the SQL reserved word `ORDER`; `order_type` avoids `TYPE`.

**`execution.fill`**
Individual fills against an order, with fee tracking.

**`execution.position`**
Current live position per instrument — a single upserted row, not a history.
Read this for current exposure; read `fill` for fill history.

---

## Sigset package

`src/sigset/` computes canonical indicator features and writes them to
`signal.indicator_panel`.

### Concepts

A **sigset** (signal set) is a versioned, named collection of TA-Lib indicator
specs. Each spec declares the function, parameters, optional output renames,
and an optional column prefix.

### Built-in sigsets

| Constant | `sigset_name` | Version | Indicators |
|---|---|---|---|
| `TrendFollowingV1` | `trend_following_v1` | 1.4.2 | SMA(50), SMA(200), ADX(14), ATR(14), MACD(12,26,9) |
| `MeanReversionV1` | `mean_reversion_v1` | 1.0.0 | RSI(7), RSI(21), BBANDS(20,2,2), STOCH(14,3,3) |

### Computing features

```python
PYTHONPATH=src python - <<'EOF'
import psycopg2
from sigset import TrendFollowingV1, computeSigsetForDate
from datetime import date

conn = psycopg2.connect("postgresql://user:pw@host:5433/tcdata")
cur = conn.cursor()

# Compute and upsert one canonical row
computeSigsetForDate(cur, 42, TrendFollowingV1, date(2024, 6, 3))
conn.commit()
EOF
```

### Applying a sigset to a DataFrame directly

```python
import pandas as pd
from sigset import TrendFollowingV1, applySigset

df = pd.DataFrame(...)  # OHLCV, DatetimeIndex
features = applySigset(df, TrendFollowingV1)
print(features.columns.tolist())
# ['open', 'high', 'low', 'close', 'volume',
#  'fast_sma', 'slow_sma', 'adx14', 'atr14', 'macd', 'macd_signal', 'macd_hist']
```

---

## Adding a new sigset

**1. Define it in `src/sigset/registry.py`**

```python
from sigset.model import IndicatorSpec, Sigset

MomentumV1 = Sigset(
    name="momentum_v1",
    version="1.0.0",
    description="ROC + Williams %R momentum screens",
    indicators=[
        IndicatorSpec("ROC",    {"timeperiod": 10}, rename={"real": "roc10"}),
        IndicatorSpec("WILLR",  {"timeperiod": 14}, rename={"real": "willr14"}),
    ],
)

Registry = {
    s.name: s for s in [TrendFollowingV1, MeanReversionV1, MomentumV1]
}
```

**2. Backfill `signal.indicator_panel`**

The JSONB design means no DDL is needed for a new sigset — just compute and
upsert rows using `computeSigsetForDate()` for each instrument and date.

**3. (Optional) Promote to a typed table**

If the sigset stabilises and you need column-level indexes, write a new
numbered patch that creates a typed table (e.g. `signal.indicator_panel_momentum_v1`)
and migrates the JSONB rows. This is a forward migration, not a change
to `signal.indicator_panel` itself.