# tc-signal — Claude guidance

PostgreSQL `signal` schema for strategy execution state: strategies, parameter
sets, signal events, positions, fills, backtest runs, equity curves.

Depends on **tc-schema** (`tc.schema_version >= 1`) being deployed first.
See `../tc-schema/` for market data ground truth (`tc.*`).

## Project structure

```
sql/patch/          — numbered patch files starting at 002_signal.sql
cfg/dev.env         — default DSN for local development (tracked, no creds)
```

No `src/` — this project reuses `../tc-schema/src/opSchema.py` directly.

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

### Foreign keys go one way: signal.* → tc.*
Never create FKs from `tc.*` into `signal.*`. tc-schema is unaware of
tc-signal's existence.

### 002_signal.sql asserts tc-schema version
The first patch guards against deploying signal tables before tc-schema is
present. Do not remove this assertion.

### DSN resolution
The runner resolves DSN from `cfg/dev.env` in tc-schema's project root (since
`opSchema.py` lives there). The `cfg/dev.env` in this repo is documentation
and used when passing `--dsn` explicitly or via `EOD_DSN`. Real passwords go
in `cfg/dev.env.local` (gitignored) or the `EOD_DSN` environment variable.
