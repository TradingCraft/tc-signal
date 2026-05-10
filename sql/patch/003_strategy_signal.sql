-- ============================================================================
-- Signal Schema — strategy_signal  (IDEMPOTENT PATCH)
-- Safe to run repeatedly against the same database.
--
-- Regular Postgres table (not a hypertable): signal volume is one row per
-- bar per strategy per instrument — TimescaleDB partitioning adds no benefit
-- and would force composite PKs through all referencing tables.
--
-- run_id IS NULL = live signal; run_id IS SET = backtest.
-- NULL != NULL in Postgres, so uniqueness for live signals uses a partial
-- index rather than a UNIQUE constraint on the nullable column.
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS signal.strategy_signal (
    signal_id          BIGSERIAL    PRIMARY KEY,
    strategy_name      TEXT         NOT NULL,
    strategy_version   TEXT         NOT NULL,
    instrument_id      INTEGER      NOT NULL REFERENCES tc.instrument(instrument_id),
    bar_ts             TIMESTAMPTZ  NOT NULL,
    emitted_at         TIMESTAMPTZ  NOT NULL DEFAULT now(),

    action             TEXT         NOT NULL
                                    CHECK (action IN ('ENTER_LONG','ENTER_SHORT','EXIT','REDUCE','HOLD')),
    confidence         REAL         CHECK (confidence BETWEEN 0 AND 1),
    size_hint          REAL,
    target_price       REAL,
    stop_price         REAL,
    valid_until        TIMESTAMPTZ,

    rationale          JSONB        NOT NULL DEFAULT '{}',
    run_id             TEXT,
    delivered_to_nt_at TIMESTAMPTZ,
    nt_order_id        TEXT
);

-- Separate partial indexes because NULL != NULL makes a single UNIQUE
-- constraint on (... run_id) ineffective for live signals.
-- action is excluded: one signal per (strategy, instrument, bar) is the
-- invariant; including action would permit contradictory live signals
-- (e.g. ENTER_LONG + EXIT on the same bar).
-- DROP first so a re-run repairs any prior deployment with the wrong definition.
DROP INDEX IF EXISTS uq_strsig_live;
DROP INDEX IF EXISTS uq_strsig_backtest;

CREATE UNIQUE INDEX IF NOT EXISTS uq_strsig_live
    ON signal.strategy_signal (strategy_name, strategy_version, instrument_id, bar_ts)
    WHERE run_id IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_strsig_backtest
    ON signal.strategy_signal (strategy_name, strategy_version, instrument_id, bar_ts, run_id)
    WHERE run_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_strsig_instrument
    ON signal.strategy_signal (instrument_id, strategy_name, bar_ts DESC);

-- Live signals awaiting delivery to NautilusTrader
CREATE INDEX IF NOT EXISTS idx_strsig_delivery
    ON signal.strategy_signal (delivered_to_nt_at)
    WHERE delivered_to_nt_at IS NULL AND run_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_strsig_run
    ON signal.strategy_signal (run_id, bar_ts DESC)
    WHERE run_id IS NOT NULL;

COMMIT;
