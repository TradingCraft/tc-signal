-- ============================================================================
-- Signal Schema — IDEMPOTENT PATCH
-- Safe to run repeatedly against the same database.
--
-- Depends on tc-schema (tc.schema_version >= 1) being deployed first.
-- Apply via: python ../tc-schema/src/opSchema.py --schema signal --patch ./sql/patch
-- ============================================================================

BEGIN;

-- --------------------------------------------------------------------------
-- 0. Prerequisite: tc-schema must be deployed
-- --------------------------------------------------------------------------
DO $$
BEGIN
    IF (SELECT COALESCE(MAX(version), 0) FROM tc.schema_version) < 1 THEN
        RAISE EXCEPTION 'tc-schema >= v1 required; run tc-schema/src/opSchema.py first';
    END IF;
END $$;

-- --------------------------------------------------------------------------
-- 1. Signal namespace
-- --------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS signal;

-- --------------------------------------------------------------------------
-- 2. Patch tracking for signal migrations
--    opSchema.py inserts the version record after this SQL executes.
-- --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS signal.schema_version (
    version     INT          PRIMARY KEY,
    description TEXT         NOT NULL,
    applied_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMIT;
