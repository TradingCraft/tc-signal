-- ============================================================================
-- Execution Schema — exec_order, fill, position  (IDEMPOTENT PATCH)
-- Safe to run repeatedly against the same database.
--
-- Mirrors NautilusTrader execution state. NT lifecycle hooks write here;
-- strategy code reads for post-trade analysis.
--
-- All three tables are regular Postgres tables (not hypertables): fill
-- volume at strategy scale does not justify TimescaleDB partitioning, and
-- plain tables keep FKs and BIGSERIAL primary keys simple.
--
-- exec_order:  avoids the SQL reserved word ORDER.
-- order_type:  avoids the SQL reserved word TYPE.
--
-- Permission boundary: GRANT SELECT on signal.* + INSERT/UPDATE on
-- execution.* to the NT database role; no per-table grants needed.
-- ============================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS execution;

-- --------------------------------------------------------------------------
-- Orders submitted to the venue
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS execution.exec_order (
    order_id       BIGSERIAL         PRIMARY KEY,
    nt_order_id    TEXT              UNIQUE,
    signal_id      BIGINT            REFERENCES signal.strategy_signal(signal_id),
    instrument_id  INTEGER           NOT NULL REFERENCES tc.instrument(instrument_id),
    submitted_at   TIMESTAMPTZ       NOT NULL,
    side           TEXT              NOT NULL CHECK (side IN ('BUY','SELL')),
    qty            DOUBLE PRECISION  NOT NULL CHECK (qty > 0),
    order_type     TEXT              NOT NULL,
    limit_price    DOUBLE PRECISION  CHECK (limit_price > 0),
    stop_price     DOUBLE PRECISION  CHECK (stop_price > 0),
    state          TEXT              NOT NULL,
    venue          TEXT,
    raw            JSONB
);

CREATE INDEX IF NOT EXISTS idx_exec_order_signal
    ON execution.exec_order (signal_id);

CREATE INDEX IF NOT EXISTS idx_exec_order_instrument
    ON execution.exec_order (instrument_id, submitted_at DESC);

-- --------------------------------------------------------------------------
-- Individual fills against an order
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS execution.fill (
    fill_id    BIGSERIAL         PRIMARY KEY,
    order_id   BIGINT            NOT NULL REFERENCES execution.exec_order(order_id),
    ts         TIMESTAMPTZ       NOT NULL,
    qty        DOUBLE PRECISION  NOT NULL CHECK (qty > 0),
    price      DOUBLE PRECISION  NOT NULL CHECK (price > 0),
    fees       DOUBLE PRECISION  NOT NULL DEFAULT 0 CHECK (fees >= 0),
    venue      TEXT,
    raw        JSONB
);

CREATE INDEX IF NOT EXISTS idx_fill_order
    ON execution.fill (order_id);

CREATE INDEX IF NOT EXISTS idx_fill_ts
    ON execution.fill (ts DESC);

-- --------------------------------------------------------------------------
-- Current live position per instrument (single-row per instrument)
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS execution.position (
    instrument_id   INTEGER           PRIMARY KEY REFERENCES tc.instrument(instrument_id),
    qty             DOUBLE PRECISION  NOT NULL,
    avg_price       DOUBLE PRECISION  CHECK (avg_price > 0),
    opened_at       TIMESTAMPTZ       NOT NULL,
    last_signal_id  BIGINT            REFERENCES signal.strategy_signal(signal_id),
    last_updated_at TIMESTAMPTZ       NOT NULL DEFAULT now()
);

COMMIT;
