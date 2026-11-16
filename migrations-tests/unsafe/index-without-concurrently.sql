SET lock_timeout = '5s';
SET statement_timeout = '5min';
-- Blocks every write to the table for the whole index build.
CREATE INDEX orders_item_idx ON orders (item);
