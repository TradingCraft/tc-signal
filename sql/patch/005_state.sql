-- ============================================================================
-- Signal Schema — trendadvisor detector state  (IDEMPOTENT PATCH)
-- Safe to run repeatedly against the same database.
--
-- Bitemporal: PRIMARY KEY includes (code_version, params_hash) so multiple
-- algorithm variants coexist on the same instrument data without collision.
-- No FK to tc.instrument: follows tc.eod_price pattern for hypertables.
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS signal.trendadvisor (
    instrument_id   INTEGER      NOT NULL,
    ts              DATE         NOT NULL,

    phase           SMALLINT     NOT NULL CHECK (phase BETWEEN 1 AND 6),
    confidence      REAL         NOT NULL CHECK (confidence BETWEEN 0 AND 1),
    phase_started   DATE         NOT NULL,
    bars_in_phase   INTEGER      NOT NULL,

    detector_state  JSONB        NOT NULL,

    code_version    TEXT         NOT NULL,
    params_hash     TEXT         NOT NULL,
    input_hash      TEXT         NOT NULL,
    computed_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),

    PRIMARY KEY (instrument_id, ts, code_version, params_hash)
);

SELECT create_hypertable('signal.trendadvisor', 'ts',
    chunk_time_interval => INTERVAL '1 year',
    if_not_exists       => TRUE
);

CREATE INDEX IF NOT EXISTS idx_trendadvisor_lookup
    ON signal.trendadvisor (instrument_id, code_version, params_hash, ts DESC);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.hypertables
         WHERE hypertable_schema = 'signal'
           AND hypertable_name   = 'trendadvisor'
           AND compression_enabled
    ) THEN
        ALTER TABLE signal.trendadvisor SET (
            timescaledb.compress,
            timescaledb.compress_segmentby = 'instrument_id, code_version, params_hash',
            timescaledb.compress_orderby   = 'ts DESC'
        );
    END IF;
END $$;

DO $$
BEGIN
    PERFORM add_compression_policy('signal.trendadvisor', INTERVAL '1 year');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

COMMIT;
