SET lock_timeout = '5s';
SET statement_timeout = '5min';
-- Rewrites the whole table under an ACCESS EXCLUSIVE lock.
ALTER TABLE orders ALTER COLUMN item TYPE VARCHAR(200);
