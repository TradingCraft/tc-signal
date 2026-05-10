# tc-signal — Claude guidance

PostgreSQL schemas for strategy signal generation and execution mirroring.
Depends on **tc-schema** (`tc.schema_version >= 1`) being deployed first.
See `../tc-schema/` for market data ground truth (`tc.*`).

## Schemas

Two schemas. The boundary is also a permission boundary: the NautilusTrader
process is granted SELECT on `signal.*` and INSERT/UPDATE on `execution.*` only.

**`signal`** — everything that feeds into trading decisions:

| Table | Purpose |
|---|---|
| `signal.strategy_signal` | API boundary between strategy code and NautilusTrader |
| `signal.indicator_panel` | Canonical JSONB feature rows, one per (instrument, date, sigset, version) |
| `signal.indicator_scratch` | Transient JSONB scratchpad for in-flux sigset definitions and parameter sweeps |
| `signal.trendadvisor` | TRENDadvisor detector state, bitemporal by (code_version, params_hash) |

**`execution`** — NautilusTrader execution mirror:

| Table | Purpose |
|---|---|
| `execution.exec_order` | Orders submitted to the venue |
| `execution.fill` | Individual fills against an order |
| `execution.position` | Current live position per instrument (single row, upserted) |

## Project structure

```
sql/patch/          — numbered patch files starting at 002_signal.sql
src/sigset/         — signal-specific Python package (sigset runtime + tooling)
cfg/dev.env         — default DSN for local development (tracked, no creds)
```

`src/sigset/` owns sigset definitions, indicator computation, and DB upserts.
Schema patch application uses `../tc-schema/src/opSchema.py` — do not copy or
fork that runner into this repo.

## Sigset terminology

Use `sigset` (short for "signal set") for versioned indicator/feature definitions.
Not `pack`, `signal_set`, or `sigsets`. Module, function, and variable names
follow the conventions in `src/sigset/`.

## Python layout

```
src/sigset/
  __init__.py    — re-exports public API
  model.py       — IndicatorSpec, Sigset dataclasses
  registry.py    — TrendFollowingV1, MeanReversionV1, Registry
  apply.py       — applySigset(), computeSigsetForDate()
```

Usage:

```bash
PYTHONPATH=src python -c "from sigset import TrendFollowingV1, computeSigsetForDate; ..."
```

## Naming conventions

- Python classes / constants: PascalCase (`IndicatorSpec`, `TrendFollowingV1`, `Registry`)
- Python functions / variables / parameters: camelCase (`applySigset`, `instrumentId`)
- SQL: snake_case throughout

## Running the schema runner

```bash
# Apply pending signal patches (tc-schema must already be deployed)
python ../tc-schema/src/opSchema.py --schema signal --patch ./sql/patch

# Verify signal schema without changing anything
python ../tc-schema/src/opSchema.py --schema signal --patch ./sql/patch --check

# Override DSN (or set EOD_DSN env var)
python ../tc-schema/src/opSchema.py --schema signal --patch ./sql/patch \
    --dsn "postgresql://user:pw@host:5433/tcdata"
```

## Non-obvious invariants — do not break these

### Patch numbering starts at 002
Patch 001 is reserved; signal patches begin at 002. The numbering coordinates
with tc-schema's version history — don't renumber existing patches.

### Patches must be idempotent
Every statement in `sql/patch/*.sql` must be safe to re-run. Use
`IF NOT EXISTS`, `CREATE OR REPLACE`, `ON CONFLICT DO NOTHING`, and
`DO $$ … EXCEPTION … $$` blocks.

### Foreign keys go one way: signal.* / execution.* → tc.*
Never create FKs from `tc.*` into `signal.*` or `execution.*`. tc-schema is
unaware of tc-signal's existence.

### No FKs from hypertables to tc.instrument
`signal.indicator_panel` and `signal.trendadvisor` are hypertables and omit
the FK to `tc.instrument`, following the `tc.eod_price` pattern. Enforce
referential integrity in application code for these tables.

### 002_signal.sql asserts tc-schema version
The first patch guards against deploying signal tables before tc-schema is
present. Do not remove this assertion.

### strategy_signal uses partial unique indexes, not a UNIQUE constraint
`run_id IS NULL` marks live signals; `run_id IS SET` marks backtest signals.
PostgreSQL treats NULL as distinct, so a single UNIQUE constraint on
`(…, run_id)` would allow duplicate live signals. Two partial unique indexes
enforce the correct semantics — one for live, one for backtest. Do not replace
them with a single constraint.

`action` is intentionally excluded from both indexes. One signal per
(strategy, version, instrument, bar) is the invariant. Including `action`
would permit contradictory live signals — e.g. `ENTER_LONG` and `EXIT` on
the same bar — which are a logic error, not two valid signals.

### indicator_panel stores features as JSONB, not typed columns
Canonical indicator values live in `signal.indicator_panel.features` as JSONB.
This avoids per-sigset DDL and column-name drift between runtime and SQL.
When a sigset matures and column-level indexes become necessary, promote it to
a typed table via a new numbered patch and migrate the JSONB rows — do not add
typed columns directly to `indicator_panel`.

### execution tables use DOUBLE PRECISION, not REAL
`execution.exec_order`, `execution.fill`, and `execution.position` use
`DOUBLE PRECISION` for all trading values (qty, price, fees, avg_price).
Single-precision `REAL` (~7 significant digits) is lossy for P&L calculations.
`fill` also enforces `CHECK (qty > 0)`, `CHECK (price > 0)`, and
`CHECK (fees >= 0)` — do not relax these to allow zero or negative fills.

### input_hash covers the full OHLCV lookback window
`computeSigsetForDate()` hashes the entire OHLCV window used for computation
plus the sigset name, version, and params — not just the target date's row.
This ensures the hash changes when historical data is corrected or when sigset
parameters change. Do not narrow it back to a single-row hash.

### DSN resolution
The runner resolves DSN from `cfg/dev.env` in tc-schema's project root (since
`opSchema.py` lives there). The `cfg/dev.env` in this repo is documentation
and used when passing `--dsn` explicitly or via `EOD_DSN`. Real passwords go
in `cfg/dev.env.local` (gitignored) or the `EOD_DSN` environment variable.
