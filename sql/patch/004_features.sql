-- ============================================================================
-- Signal Schema — indicator_panel + indicator_scratch  (IDEMPOTENT PATCH)
-- Safe to run repeatedly against the same database.
--
-- indicator_panel: canonical JSONB feature rows, one per (instrument, date,
--   sigset, version). JSONB avoids typed-column-per-sigset DDL; promote to
--   a typed table only when column-level indexes are needed for a specific
--   sigset. Hypertable — daily data accumulates indefinitely.
--   No FK to tc.instrument: follows tc.eod_price pattern for hypertables.
--
-- indicator_scratch: transient scratchpad for parameter sweeps and in-flux
--   sigset definitions not yet promoted to canonical. Regular table — rows are deleted
--   (not archived) when a sweep campaign ends.
-- ============================================================================

BEGIN;

-- --------------------------------------------------------------------------
-- Canonical indicator panels
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS signal.indicator_panel (
    instrument_id  INTEGER      NOT NULL,
    ts             DATE         NOT NULL,
    sigset_name    TEXT         NOT NULL,
    sigset_version TEXT         NOT NULL,
    features       JSONB        NOT NULL,
    input_hash     TEXT         NOT NULL,
    computed_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),

    PRIMARY KEY (instrument_id, ts, sigset_name, sigset_version)
);

SELECT create_hypertable('signal.indicator_panel', 'ts',
    chunk_time_interval => INTERVAL '1 year',
    if_not_exists       => TRUE
);

CREATE INDEX IF NOT EXISTS idx_panel_sigset
    ON signal.indicator_panel (sigset_name, sigset_version, ts DESC);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.hypertables
         WHERE hypertable_schema = 'signal'
           AND hypertable_name   = 'indicator_panel'
           AND compression_enabled
    ) THEN
        ALTER TABLE signal.indicator_panel SET (
            timescaledb.compress,
            timescaledb.compress_segmentby = 'instrument_id, sigset_name, sigset_version',
            timescaledb.compress_orderby   = 'ts DESC'
        );
    END IF;
END $$;

DO $$
BEGIN
    PERFORM add_compression_policy('signal.indicator_panel', INTERVAL '1 year');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- --------------------------------------------------------------------------
-- Exploratory scratchpad
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS signal.indicator_scratch (
    instrument_id  INTEGER      NOT NULL REFERENCES tc.instrument(instrument_id),
    ts             DATE         NOT NULL,
    sigset_name    TEXT         NOT NULL,
    sigset_version TEXT         NOT NULL,
    params_hash    TEXT         NOT NULL,
    params         JSONB        NOT NULL DEFAULT '{}',
    features       JSONB        NOT NULL,
    input_hash     TEXT         NOT NULL,
    computed_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),

    PRIMARY KEY (instrument_id, ts, sigset_name, sigset_version, params_hash)
);

CREATE INDEX IF NOT EXISTS idx_scratch_sigset
    ON signal.indicator_scratch (sigset_name, sigset_version, ts DESC);

CREATE INDEX IF NOT EXISTS idx_scratch_features
    ON signal.indicator_scratch USING gin (features jsonb_path_ops);

COMMIT;
