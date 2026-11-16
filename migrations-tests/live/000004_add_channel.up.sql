-- Applied by CI while synthetic traffic is writing orders, to prove the change causes zero errors.
SET lock_timeout = '5s';
SET statement_timeout = '30min';

-- Postgres 11+: a constant default is stored in the catalog, so this does not rewrite the table.
ALTER TABLE orders ADD COLUMN IF NOT EXISTS channel TEXT NOT NULL DEFAULT 'web';
CREATE INDEX CONCURRENTLY IF NOT EXISTS orders_channel_idx ON orders (channel);
