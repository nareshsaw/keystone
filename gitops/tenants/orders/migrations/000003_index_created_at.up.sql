-- CONCURRENTLY builds the index without blocking writes (must run outside a transaction).
SET lock_timeout = '5s';
SET statement_timeout = '30min';

CREATE INDEX CONCURRENTLY IF NOT EXISTS orders_created_at_idx ON orders (created_at);
