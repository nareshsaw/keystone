-- Expand step: a nullable column is a metadata-only change. The app starts writing it in this release;
-- a later release may backfill it and add a constraint (contract step) once every writer sets it.
SET lock_timeout = '5s';
SET statement_timeout = '5min';

ALTER TABLE orders ADD COLUMN IF NOT EXISTS customer_email TEXT;
