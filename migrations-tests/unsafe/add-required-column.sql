SET lock_timeout = '5s';
SET statement_timeout = '5min';
-- Fails on a non-empty table, and old app versions can't insert rows without it.
ALTER TABLE orders ADD COLUMN region TEXT NOT NULL;
